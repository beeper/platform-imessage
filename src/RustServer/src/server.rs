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
}

struct PollResultRow {
    msg_row_id: u64,
    date_read: u64,
    thread_guid: Option<String>,
    // max_msg_date: u64,
}

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
        }
    }

    pub fn start(&mut self, last_row_id: u64, last_date_read: u64) {
        self.last_row_id = last_row_id;
        self.last_date_read = last_date_read;

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
                self.poll_updates();
            }

            std::thread::sleep(Duration::from_millis(1000));
        }
    }

    fn poll_updates(&mut self) {
        // eprintln!("Polling for updates");

        // Scoped block drops immutable borrow of conn.
        let rows: Vec<PollResultRow> = {
            let mut stmt = self
                .conn
                .prepare_cached(
                    r#"
                    SELECT m.ROWID, m.date_read, t.guid, MAX(m.date)
                    FROM message AS m
                    LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
                    LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
                    WHERE m.ROWID > ?
                    OR m.date_read > ?
                    GROUP BY t.guid
                    ORDER BY date DESC
                "#,
                )
                .expect("Unable to prepare poll query");

            stmt.query_map([self.last_row_id, self.last_date_read], |row| {
                Ok(PollResultRow {
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

        if !rows.is_empty() {
            let thread_ids: Vec<Option<&String>> =
                rows.iter().map(|r| r.thread_guid.as_ref()).collect();

            println!("{}", json!({ "threads": thread_ids }));

            std::io::stdout().flush().ok();
        }

        self.update_cursors(rows);
    }

    fn update_cursors(&mut self, rows: Vec<PollResultRow>) {
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
