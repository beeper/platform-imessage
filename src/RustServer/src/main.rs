use rusqlite::{Connection, OpenFlags, Result, Statement};
use serde_json::{json, Value};
use std::io;
use std::io::prelude::*;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::mpsc::{self, TryRecvError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

#[derive(Debug)]
struct PollResultRow {
  msg_row_id: i64,
  date_read: i64,
  thread_guid: Option<String>,
  max_msg_date: i64,
}

static POLL_MESSAGE_CREATE_UPDATE_QUERY: &str = "SELECT m.ROWID, m.date_read, t.guid, MAX(m.date)
FROM message AS m
LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat AS t ON cmj.chat_id = t.ROWID
WHERE m.ROWID > ?
OR m.date_read > ?
GROUP BY t.guid
ORDER BY date DESC";

fn poll_message_create_update(
  stmt: &mut Statement,
  bindings: &[&String; 2],
) -> Result<Vec<PollResultRow>> {
  let results = stmt.query_map(bindings, |row| {
    Ok(PollResultRow {
      msg_row_id: row.get(0)?,
      date_read: row.get(1)?,
      thread_guid: row.get(2)?,
      max_msg_date: row.get(3)?,
    })
  })?;

  let mut poll_res = Vec::new();
  for result in results {
    poll_res.push(result.unwrap());
  }
  Ok(poll_res)
}

fn set_last_cursor_from_rows(
  rows: &Vec<PollResultRow>,
  last_row_id: &Arc<AtomicI64>,
  last_date_read: &Arc<AtomicI64>,
) {
  let mut max_date_local = -1;
  let mut max_row_id_local = -1;
  for row in rows {
    if max_date_local < row.date_read {
      max_date_local = row.date_read;
    }
    if max_row_id_local < row.msg_row_id {
      max_row_id_local = row.msg_row_id;
    }
  }
  if max_row_id_local > last_row_id.load(Ordering::Acquire) {
    last_row_id.store(max_row_id_local, Ordering::Release);
  }
  if max_date_local > last_date_read.load(Ordering::Acquire) {
    last_date_read.store(max_date_local, Ordering::Release);
  }
}

fn get_chat_db_path() -> String {
  dirs::home_dir().unwrap().as_path().display().to_string() + "/Library/Messages/chat.db"
}

fn get_db_conn() -> Connection {
  let chat_db_path = get_chat_db_path();
  Connection::open_with_flags(&chat_db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
    .expect("Unable to open db")
}

fn start_polling(
  last_row_id: &Arc<AtomicI64>,
  last_date_read: &Arc<AtomicI64>,
  args: &Vec<Value>,
  rx: &Arc<Mutex<std::sync::mpsc::Receiver<()>>>,
) {
  last_row_id.store(args[0].as_i64().unwrap(), Ordering::Release);
  last_date_read.store(args[1].as_i64().unwrap(), Ordering::Release);
  let thread_rx = Arc::clone(rx);
  let thread_last_row_id = last_row_id.clone();
  let thread_last_date_read = last_date_read.clone();
  thread::spawn(move || {
    let db = get_db_conn();
    let mut poll_stmt = db.prepare(POLL_MESSAGE_CREATE_UPDATE_QUERY).unwrap();
    let poll_duration = Duration::from_secs(1);
    loop {
      match thread_rx.lock().unwrap().try_recv() {
        Ok(_) | Err(TryRecvError::Disconnected) => {
          break;
        }
        Err(TryRecvError::Empty) => {}
      }
      let rows = poll_message_create_update(
        &mut poll_stmt,
        &[
          &thread_last_row_id.load(Ordering::Acquire).to_string(),
          &thread_last_date_read.load(Ordering::Acquire).to_string(),
        ],
      )
      .expect("`poll_message_create_update` failed");
      if rows.len() > 0 {
        let mut updated_thread_ids = Vec::new();
        for row in &rows {
          updated_thread_ids.push(row.thread_guid.as_ref());
        }
        println!("{}", json!({ "threads": updated_thread_ids }));
      }
      // dbg!(
      //   thread_last_row_id.load(Ordering::Acquire).to_string(),
      //   thread_last_date_read.load(Ordering::Acquire).to_string()
      // );
      set_last_cursor_from_rows(&rows, &thread_last_row_id, &thread_last_date_read);
      thread::sleep(poll_duration);
    }
  });
}

fn main() -> Result<()> {
  let last_row_id = Arc::new(AtomicI64::new(0));
  let last_date_read = Arc::new(AtomicI64::new(0));
  let (tx, rx) = mpsc::channel::<()>();
  let rx = Arc::new(Mutex::new(rx));
  let mut is_running = false;

  for line in io::stdin().lock().lines() {
    let json = line.unwrap();
    let val: Value = serde_json::from_str(&json).expect("Error converting JSON");
    match val["method"].as_str().expect("Malformed JSON: `method`") {
      "start_polling" => {
        // { method: 'set', args: [ last_row_id, last_date_read ] }
        if is_running {
          continue;
        }
        is_running = true;
        let args = val["args"].as_array().unwrap();
        start_polling(&last_row_id, &last_date_read, &args, &rx);
      }
      "stop_polling" => {
        let _ = tx.send(());
        is_running = false;
      }
      method => println!("Unimplemented method: {}", method),
    }
  }
  return Ok(());
}
