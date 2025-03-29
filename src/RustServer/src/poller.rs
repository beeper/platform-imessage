use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use napi::threadsafe_function::ThreadsafeFunctionCallMode;

use dirs::home_dir;

use rusqlite::{Connection, OpenFlags};
use rustc_hash::FxHashMap;
use sha2::digest::Update;

use crate::error::{ServerError, ServerResult};
use crate::hashing::THREAD_ID_HASHER;
use crate::sdk::{ServerEvent, ThreadMessagesRefreshEvent, ToastEvent, UpdateStateSyncEvent};
use crate::server::EventCallback;
use crate::unreads::{UnreadState, Unreads};
use crate::ChatGuid;

pub struct Poller {
    inner: Arc<Mutex<PollerInner>>,

    should_stop: Arc<AtomicBool>,
}

struct PollerInner {
    last_row_id: u64,

    last_date_read: u64,

    last_failed_message_rowid: Option<u64>,

    conn: Connection,

    database_paths: [(PathBuf, SystemTime); 2],

    unreads: Unreads,

    callback: EventCallback,
}

#[derive(Debug)]
struct PollMessageResultRow {
    msg_row_id: u64,
    date_read: u64,
    thread_guid: Option<ChatGuid>,
    // max_msg_date: u64,
}

static POLL_MESSAGE_CREATE_UPDATE_QUERY: &str = r#"
SELECT
	m.ROWID,
	m.date_read,
	t.guid,
	MAX(m.date)
FROM
	message AS m
	LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
	LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
WHERE
	m.ROWID > ?
	OR m.date_read > ?
GROUP BY
	t.guid
ORDER BY
	date DESC
"#;

static GET_LAST_FAILED_MESSAGE_QUERY: &str = r#"
SELECT
	CAST(value AS INTEGER)
FROM
	kvtable
WHERE
	KEY = 'lastFailedMessageRowID'
"#;

static POLL_UNREAD_CHATS_QUERY: &str = r#"
SELECT
	cm.chat_id AS chat_id,
    COUNT(cm.chat_id) AS unread_count,
    c.last_read_message_timestamp
FROM
	message m
INDEXED BY
    message_idx_isRead_isFromMe_itemType
INNER JOIN
    chat_message_join cm ON m.ROWID = cm.message_id
INNER JOIN
    chat c ON c.ROWID = cm.chat_id
WHERE
	m.item_type == 0
	AND m.is_read == 0
	AND m.is_from_me == 0
GROUP BY
	cm.chat_id
"#;

static GET_CHAT_GUID_QUERY: &str = r#"SELECT guid FROM chat WHERE ROWID = ?"#;

static GET_CHAT_GUID_FROM_MESSAGE_ROWID_QUERY: &str = r#"
SELECT
	guid
FROM
	chat
WHERE
	rowid = (
		SELECT
			chat_id
		FROM
			chat_message_join
		WHERE
			message_id = ?
    )
"#;

impl Poller {
    pub fn new(callback: EventCallback) -> ServerResult<Self> {
        Ok(Self {
            inner: Arc::new(Mutex::new(PollerInner::new(callback)?)),
            should_stop: Arc::new(AtomicBool::new(false)),
        })
    }

    pub fn start(&self, last_row_id: u64, last_date_read: u64) {
        let inner = self.inner.clone();
        let should_stop = self.should_stop.clone();

        tracing::info!(?last_row_id, ?last_date_read, "starting poller");

        std::thread::spawn(move || {
            let mut lock = inner.lock().unwrap();

            if let Err(e) = lock.init(last_row_id, last_date_read) {
                tracing::error!(
                    ?last_row_id,
                    ?last_date_read,
                    "couldn't initialize inner: {e}"
                );
                lock.emit_error(&e);
            }

            loop {
                tracing::trace!("beginning run");

                if let Err(e) = lock.run() {
                    tracing::error!("run failed: {e}, resetting timestamp");

                    lock.emit_error(&e);

                    // Run has failed, reset timestamp so it can pick it up next time.
                    lock.reset_timestamp();
                }

                if should_stop.load(Ordering::Relaxed) {
                    break;
                }

                std::thread::sleep(Duration::from_millis(1000));
            }
        });
    }

    pub fn stop(&self) {
        tracing::info!("stopping");
        let should_stop = self.should_stop.clone();

        should_stop.store(true, Ordering::Relaxed);
    }

    pub fn is_chat_rowid_unread(&self, chat_rowid: u64) -> bool {
        self.inner.lock().unwrap().unreads.is_unread(chat_rowid)
    }
}

impl PollerInner {
    pub fn new(callback: EventCallback) -> ServerResult<Self> {
        Ok(Self {
            last_row_id: 0,
            last_date_read: 0,
            last_failed_message_rowid: None,
            conn: Connection::open_with_flags(
                Self::format_path(&"chat.db")?,
                OpenFlags::SQLITE_OPEN_READ_ONLY,
            )?,
            database_paths: [
                (Self::format_path(&"chat.db")?, SystemTime::now()),
                (Self::format_path(&"chat.db-wal")?, SystemTime::now()),
            ],
            unreads: Unreads::default(),
            callback,
        })
    }

    pub fn init(&mut self, last_row_id: u64, last_date_read: u64) -> ServerResult<()> {
        self.last_row_id = last_row_id;
        self.last_date_read = last_date_read;

        self.init_unread_counts()?;
        self.init_last_failed_message_rowid();

        Ok(())
    }

    pub fn emit_error<E>(&self, error: &E)
    where
        E: std::error::Error + ?Sized,
    {
        let error = error.to_string();
        tracing::error!(message = %error, "emitting error server event");
        self.callback.call(
            vec![ServerEvent::A(ToastEvent::new(error))],
            ThreadsafeFunctionCallMode::NonBlocking,
        );
    }

    pub fn run(&mut self) -> ServerResult<()> {
        let mut is_modified = false;

        'inner: for (path, last_modified) in &mut self.database_paths {
            // eprintln!("Checking {:?} for modified", &path);

            let metadata = std::fs::metadata(&path).map_err(ServerError::IoError)?;

            let modified = metadata.modified().map_err(ServerError::IoError)?;

            // eprintln!(
            //     "{:?} modified on {:?} (last modified: {:?})",
            //     &path, &modified, &last_modified
            // );

            if modified != *last_modified {
                // eprintln!("{:?} was modified, breaking", &path);

                tracing::trace!(current = ?modified, last = ?last_modified, ?path, "detected modification");
                *last_modified = modified;
                is_modified = true;
                break 'inner;
            }
        }

        if is_modified {
            self.run_subtasks();
        }

        Ok(())
    }

    fn run_subtasks(&mut self) {
        tracing::trace!("running subtasks");

        match self.poll_chat_updates() {
            Ok(_) => tracing::debug!("finished polling chat updates"),
            Err(err) => tracing::error!("failed to poll chat updates: {err}"),
        }

        match self.poll_message_updates() {
            Ok(guids) => {
                tracing::debug!(chat_guids_with_new_messages = ?guids, "finished polling message updates")
            }
            Err(err) => tracing::error!("failed to poll message updates: {err}"),
        }

        self.poll_last_failed_message();
    }

    fn reset_timestamp(&mut self) {
        for (_, last_modified) in &mut self.database_paths {
            *last_modified = SystemTime::now();
        }
    }

    fn send_thread_messages_refresh_event(&mut self, chat_guids: &[ChatGuid]) {
        if chat_guids.is_empty() {
            return;
        }

        let events: Vec<ServerEvent> = chat_guids
            .into_iter()
            .map(|chat_guids| ServerEvent::B(ThreadMessagesRefreshEvent::new(chat_guids.token())))
            .collect();

        self.callback
            .call(events, ThreadsafeFunctionCallMode::NonBlocking);
    }

    // Discovers all new messages according to the last known message `ROWID` and `date_read`,
    // returning a `Vec` of thread GUIDs that changed.
    //
    // The cursors (last known message `ROWID` and `date_read`) are updated.
    fn poll_message_updates(&mut self) -> ServerResult<Vec<ChatGuid>> {
        // Scoped block drops immutable borrow of conn.
        let rows: Vec<PollMessageResultRow> = {
            let mut stmt = self.conn.prepare_cached(POLL_MESSAGE_CREATE_UPDATE_QUERY)?;

            let stmt = stmt.query_map([self.last_row_id, self.last_date_read], |row| {
                Ok(PollMessageResultRow {
                    msg_row_id: row.get(0)?,
                    date_read: row.get(1)?,
                    thread_guid: row.get(2)?,
                    // max_msg_date: row.get(3)?,
                })
            })?;

            let mut res = Vec::new();
            for row in stmt {
                res.push(row?);
            }
            res
        };

        let thread_ids: Vec<ChatGuid> = rows
            .iter()
            .filter_map(|row| row.thread_guid.clone())
            .collect();

        self.send_thread_messages_refresh_event(&thread_ids);

        self.update_cursors(rows);

        Ok(thread_ids)
    }

    fn get_unreads(&self) -> ServerResult<Unreads> {
        let mut stmt = self.conn.prepare_cached(POLL_UNREAD_CHATS_QUERY)?;

        let unreads: Unreads = stmt
            .query_map([], |row| -> rusqlite::Result<(u64, UnreadState)> {
                let (chat_id, unread_count, last_read_message_timestamp) = row.try_into()?;
                Ok((
                    chat_id,
                    UnreadState {
                        unread_count,
                        last_read_message_timestamp,
                    },
                ))
            })?
            .into_iter()
            .flatten()
            .collect::<Unreads>();

        Ok(unreads)
    }

    fn init_unread_counts(&mut self) -> ServerResult<()> {
        self.unreads = self.get_unreads()?;
        Ok(())
    }

    fn init_last_failed_message_rowid(&mut self) {
        self.last_failed_message_rowid = self.get_last_failed_message();
    }

    fn get_chat_guid_from_chat_rowid(&self, chat_rowid: &u64) -> Option<ChatGuid> {
        let mut stmt = self.conn.prepare_cached(GET_CHAT_GUID_QUERY).ok()?;
        let mut rows = stmt.query_map([chat_rowid], |row| row.get(0)).ok()?;
        rows.next()?.ok()?
    }

    fn get_chat_guid_from_msg_rowid(&self, msg_rowid: &u64) -> Option<ChatGuid> {
        let mut stmt = self
            .conn
            .prepare_cached(GET_CHAT_GUID_FROM_MESSAGE_ROWID_QUERY)
            .ok()?;
        let mut rows = stmt.query_map([msg_rowid], |row| row.get(0)).ok()?;
        rows.next()?.ok()?
    }

    // Queries for all unread chats, compares them to the currently known set of unread chats, and
    // sends `STATE_SYNC` events to the renderer accordingly.
    fn poll_chat_updates(&mut self) -> ServerResult<()> {
        let new_unreads = self.get_unreads()?;
        let mut events: Vec<ServerEvent> = Vec::new();

        let changed_chat_rowids = self.unreads.diff_with_newer(&new_unreads);
        tracing::debug!(new_len = ?changed_chat_rowids.len(), cur_len = ?self.unreads.len(), "grabbed fresh unread state");

        for &changed_chat_rowid in &changed_chat_rowids {
            let Some(chat_guid) = self.get_chat_guid_from_chat_rowid(&changed_chat_rowid) else {
                tracing::error!(chat_rowid = ?changed_chat_rowid, "couldn't get chat guid from chat rowid");
                continue;
            };

            let Some(new_state) = self.unreads.get(changed_chat_rowid) else {
                // if the changed chat is in the old object but not in the new one, then it became read
                tracing::debug!(
                    ?chat_guid,
                    "didn't find chat in new unreads object, enqueueing state sync as read"
                );

                events.push(ServerEvent::C(UpdateStateSyncEvent::new(
                    chat_guid.token(),
                    0,
                    // TODO(skip): This needs to be updated even if the chat didn't turn unread so
                    // the renderer knows to not increment the unread count, even if it got a new
                    // message.
                    None,
                )));

                continue;
            };

            tracing::debug!(new_unread_count = ?new_state.unread_count, new_last_read_message_timestamp = ?new_state.last_read_message_timestamp, "enqueueing state sync as unread");

            events.push(ServerEvent::C(UpdateStateSyncEvent::new(
                chat_guid.token(),
                new_state.unread_count,
                Some(new_state.last_read_message_timestamp),
            )));
        }

        self.unreads = new_unreads;

        if events.is_empty() {
            tracing::trace!("no chat update state sync events (unread chat set didn't change)");
        } else {
            tracing::debug!(len = %events.len(), "sending state sync events for unread states");
            self.callback
                .call(events, ThreadsafeFunctionCallMode::NonBlocking);
        }

        Ok(())
    }

    fn poll_last_failed_message(&mut self) {
        let last_failed_message_rowid = self.get_last_failed_message();
        if self.last_failed_message_rowid != last_failed_message_rowid {
            self.last_failed_message_rowid = last_failed_message_rowid;
            if let Some(rowid) = last_failed_message_rowid {
                if let Some(chat_guid) = self.get_chat_guid_from_msg_rowid(&rowid) {
                    self.send_thread_messages_refresh_event(&[chat_guid]);
                }
            }
        }
    }

    fn get_last_failed_message(&mut self) -> Option<u64> {
        let mut stmt = self
            .conn
            .prepare_cached(GET_LAST_FAILED_MESSAGE_QUERY)
            .ok()?;

        let mut rows = stmt.query_map([], |row| row.get(0)).ok()?;
        rows.next()?.ok()?
    }

    fn update_cursors(&mut self, rows: Vec<PollMessageResultRow>) {
        for r in rows {
            self.last_row_id = std::cmp::max(self.last_row_id, r.msg_row_id);
            self.last_date_read = std::cmp::max(self.last_date_read, r.date_read);
        }
    }

    fn format_path<P: AsRef<Path>>(sub: &P) -> ServerResult<PathBuf> {
        let mut p = home_dir()
            .ok_or(ServerError::CannotFindHomeDirectory)?
            .join(["Library", "Messages"].iter().collect::<PathBuf>());

        p.push(sub);

        Ok(p)
    }
}
