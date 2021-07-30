use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use dirs::home_dir;

use serde_json::json;

use rusqlite::{Connection, OpenFlags};

pub struct Server {
    last_row_id: u64,

    last_date_read: u64,

    conn: Connection,

    database_paths: [(PathBuf, SystemTime); 2],

    chat_read_map: HashMap<String, bool>,
}

struct PollMessageResultRow {
    msg_row_id: u64,
    date_read: u64,
    thread_guid: Option<String>,
    // max_msg_date: u64,
}
struct PollThreadResultRow {
    thread_guid: Option<String>,
    is_read: bool,
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

// limit of 400 is arbitrary, if the user scrolls down 400 chats and reads something, it'll be ignored
static POLL_THREAD_READ_QUERY: &str = r#"
SELECT
	chat.guid,
	(m.is_from_me = 1 OR m.is_read = 1) AS isRead,
	max(m.date) AS msgDate
FROM
	chat
	LEFT JOIN chat_message_join AS cmj ON cmj.chat_id = chat.ROWID
	LEFT JOIN message AS m ON cmj.message_id = m.ROWID
WHERE
	m.item_type = 0
GROUP BY
	chat.guid
ORDER BY
	msgDate desc
LIMIT 400
"#;

impl Server {
    pub fn new() -> Self {
        Self {
            last_row_id: 0,
            last_date_read: 0,
            conn: Connection::open_with_flags(
                Self::format_path(&"chat.db"),
                OpenFlags::SQLITE_OPEN_READ_ONLY,
            )
            .expect("Unable to open database connection"),
            database_paths: [
                (Self::format_path(&"chat.db"), SystemTime::now()),
                (Self::format_path(&"chat.db-wal"), SystemTime::now()),
            ],
            chat_read_map: HashMap::new(),
        }
    }

    pub fn start(&mut self, last_row_id: u64, last_date_read: u64) {
        self.last_row_id = last_row_id;
        self.last_date_read = last_date_read;
        self.init_chat_read_map();

        loop {
            let mut is_modified = false;

            'inner: for (path, last_modified) in &mut self.database_paths {
                // eprintln!("Checking {:?} for modified", &path);

                let metadata = std::fs::metadata(&path).expect("Unable to pull file metadata");

                let modified = metadata
                    .modified()
                    .expect("Date modified not supported on this platform");

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
                self.poll_message_updates();
                self.poll_thread_updates();
            }

            std::thread::sleep(Duration::from_millis(1000));
        }
    }

    fn poll_message_updates(&mut self) {
        // Scoped block drops immutable borrow of conn.
        let rows: Vec<PollMessageResultRow> = {
            let mut stmt = self
                .conn
                .prepare_cached(POLL_MESSAGE_CREATE_UPDATE_QUERY)
                .expect("Unable to prepare poll query");

            stmt.query_map([self.last_row_id, self.last_date_read], |row| {
                Ok(PollMessageResultRow {
                    msg_row_id: row.get(0)?,
                    date_read: row.get(1)?,
                    thread_guid: row.get(2)?,
                    // max_msg_date: row.get(3)?,
                })
            })
            .expect("Unable to poll database")
            .map(|r| r.unwrap())
            .collect()
        };

        let thread_ids: Vec<&String> = rows
            .iter()
            .filter(|r| r.thread_guid.is_some())
            .map(|r| r.thread_guid.as_ref().unwrap())
            .collect();

        if !thread_ids.is_empty() {
            println!("{}", json!({ "thread_messages_refresh": thread_ids }));
            std::io::stdout().flush().ok();
        }

        self.update_cursors(rows);
    }

    fn query_thread_reads(&mut self) -> Vec<PollThreadResultRow> {
        let rows: Vec<PollThreadResultRow> = {
            // kb: todo optimize
            // this sql query takes ~150ms for me with 1,033 chat rows and 190,179 message rows
            let mut stmt = self
                .conn
                .prepare_cached(POLL_THREAD_READ_QUERY)
                .expect("Unable to prepare poll query");

            stmt.query_map([], |row| {
                Ok(PollThreadResultRow {
                    thread_guid: row.get(0)?,
                    is_read: row.get(1)?,
                    // max_msg_date: row.get(2)?,
                })
            })
            .expect("Unable to poll database")
            .map(|r| r.unwrap())
            .collect()
        };

        rows
    }

    fn init_chat_read_map(&mut self) {
        let rows = self.query_thread_reads();
        for row in rows {
            if let Some(guid) = row.thread_guid {
                self.chat_read_map.insert(guid, row.is_read);
            }
        }
    }

    fn poll_thread_updates(&mut self) {
        let rows = self.query_thread_reads();
        let mut thread_ids: Vec<&str> = Vec::new();
        for row in &rows {
            if let Some(guid) = &row.thread_guid {
                let was_read = self
                    .chat_read_map
                    .insert(guid.clone(), row.is_read)
                    .unwrap_or(true);

                if !was_read && row.is_read {
                    thread_ids.push(&guid);
                }
            }
        }

        if !thread_ids.is_empty() {
            println!("{}", json!({ "threads_read": thread_ids }));
            std::io::stdout().flush().ok();
        }
    }

    fn update_cursors(&mut self, rows: Vec<PollMessageResultRow>) {
        for r in rows {
            self.last_row_id = std::cmp::max(self.last_row_id, r.msg_row_id);
            self.last_date_read = std::cmp::max(self.last_date_read, r.date_read);
        }
    }

    fn format_path<P: AsRef<Path>>(sub: &P) -> PathBuf {
        let mut p = home_dir()
            .expect("Cannot find home directory")
            .join(["Library", "Messages"].iter().collect::<PathBuf>());

        p.push(sub);

        p
    }
}
