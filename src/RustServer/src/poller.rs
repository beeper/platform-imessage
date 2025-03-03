use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use napi::threadsafe_function::ThreadsafeFunctionCallMode;

use dirs::home_dir;

use rusqlite::{Connection, OpenFlags};

use crate::error::{ServerError, ServerResult};
use crate::hashing::THREAD_HASHER;
use crate::sdk::{ServerEvent, ThreadMessagesRefreshEvent, ToastEvent, UpdateStateSyncEvent};
use crate::server::EventCallback;

pub struct Poller {
    pub inner: Arc<Mutex<PollerInner>>,

    should_stop: Arc<AtomicBool>,
}

struct PollerInner {
    last_row_id: u64,

    last_date_read: u64,

    last_failed_message_rowid: Option<u64>,

    conn: Connection,

    database_paths: [(PathBuf, SystemTime); 2],

    unread_chat_set: HashSet<u64>,

    callback: EventCallback,
}

#[derive(Debug)]
struct PollMessageResultRow {
    msg_row_id: u64,
    date_read: u64,
    thread_guid: Option<String>,
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
	cm.chat_id
FROM
	message m
	INNER JOIN chat_message_join cm ON m.ROWiD = cm.message_id
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

        std::thread::spawn(move || {
            let mut lock = inner.lock().unwrap();

            if let Err(e) = lock.init(last_row_id, last_date_read) {
                lock.emit_error(&e);
            }

            loop {
                if let Err(e) = lock.run() {
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
        let should_stop = self.should_stop.clone();

        should_stop.store(true, Ordering::Relaxed);
    }

    pub fn is_chat_rowid_unread(&self, chat_rowid: u64) -> bool {
        self.inner
            .lock()
            .unwrap()
            .unread_chat_set
            .contains(&chat_rowid)
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
            unread_chat_set: HashSet::new(),
            callback,
        })
    }

    pub fn init(&mut self, last_row_id: u64, last_date_read: u64) -> ServerResult<()> {
        self.last_row_id = last_row_id;
        self.last_date_read = last_date_read;

        self.init_unread_chat_set()?;
        self.init_last_failed_message_rowid();

        Ok(())
    }

    pub fn emit_error<E>(&self, error: &E)
    where
        E: std::error::Error + ?Sized,
    {
        self.callback.call(
            vec![ServerEvent::A(ToastEvent::new(error.to_string()))],
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
        self.poll_message_updates().ok();
        self.poll_chat_updates().ok();
        self.poll_last_failed_message();
    }

    fn reset_timestamp(&mut self) {
        for (_, last_modified) in &mut self.database_paths {
            *last_modified = SystemTime::now();
        }
    }

    fn send_thread_messages_refresh_event(&mut self, thread_ids: Vec<String>) {
        if thread_ids.is_empty() {
            return;
        }

        let events: Vec<ServerEvent> = thread_ids
            .into_iter()
            .map(|thread_id| {
                let hashed_thread_id = &*THREAD_HASHER.hash_and_remember(thread_id);
                ServerEvent::B(ThreadMessagesRefreshEvent::new(hashed_thread_id.to_owned()))
            })
            .collect();

        self.callback
            .call(events, ThreadsafeFunctionCallMode::NonBlocking);
    }

    fn poll_message_updates(&mut self) -> ServerResult<()> {
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

        let thread_ids: Vec<String> = rows
            .iter()
            .filter(|r| r.thread_guid.is_some())
            .map(|r| r.thread_guid.clone().unwrap())
            .collect();

        self.send_thread_messages_refresh_event(thread_ids);

        self.update_cursors(rows);

        Ok(())
    }

    fn query_unread_chats(&mut self) -> ServerResult<HashSet<u64>> {
        let mut stmt = self.conn.prepare_cached(POLL_UNREAD_CHATS_QUERY)?;
        let rows = stmt.query_map([], |row| row.get(0))?;

        let set = rows.into_iter().flatten().collect();

        Ok(set)
    }

    fn init_unread_chat_set(&mut self) -> ServerResult<()> {
        self.unread_chat_set = self.query_unread_chats()?;
        Ok(())
    }

    fn init_last_failed_message_rowid(&mut self) {
        self.last_failed_message_rowid = self.get_last_failed_message();
    }

    fn get_chat_guid_from_chat_rowid(&self, chat_rowid: &u64) -> Option<String> {
        let mut stmt = self.conn.prepare_cached(GET_CHAT_GUID_QUERY).ok()?;
        let mut rows = stmt.query_map([chat_rowid], |row| row.get(0)).ok()?;
        rows.next()?.ok()?
    }

    fn get_chat_guid_from_msg_rowid(&self, msg_rowid: &u64) -> Option<String> {
        let mut stmt = self
            .conn
            .prepare_cached(GET_CHAT_GUID_FROM_MESSAGE_ROWID_QUERY)
            .ok()?;
        let mut rows = stmt.query_map([msg_rowid], |row| row.get(0)).ok()?;
        rows.next()?.ok()?
    }

    fn poll_chat_updates(&mut self) -> ServerResult<()> {
        let unread_chat_ids = self.query_unread_chats()?;
        let mut updates: Vec<(String, bool)> = Vec::new();

        for chat_id in self.unread_chat_set.difference(&unread_chat_ids) {
            if let Some(chat_guid) = self.get_chat_guid_from_chat_rowid(chat_id) {
                updates.push((chat_guid, false));
            }
        }
        for chat_id in unread_chat_ids.difference(&self.unread_chat_set) {
            if let Some(chat_guid) = self.get_chat_guid_from_chat_rowid(chat_id) {
                updates.push((chat_guid, true));
            }
        }

        self.unread_chat_set = unread_chat_ids;

        let events: Vec<ServerEvent> = updates
            .into_iter()
            .map(|(thread_id, is_unread)| {
                let hashed_thread_id = &*THREAD_HASHER.hash_and_remember(thread_id);
                ServerEvent::C(UpdateStateSyncEvent::new(
                    hashed_thread_id.to_owned(),
                    is_unread,
                ))
            })
            .collect();

        if !events.is_empty() {
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
                    self.send_thread_messages_refresh_event(vec![chat_guid]);
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
