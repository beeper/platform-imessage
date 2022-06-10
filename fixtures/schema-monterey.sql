CREATE TABLE _SqliteDatabaseProperties (key TEXT, value TEXT, UNIQUE(key));

CREATE TABLE deleted_messages (
  ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE,
  guid TEXT NOT NULL
);

CREATE TABLE sqlite_sequence(name, seq);

CREATE TABLE chat_handle_join (
  chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE,
  handle_id INTEGER REFERENCES handle (ROWID) ON DELETE CASCADE,
  UNIQUE(chat_id, handle_id)
);

CREATE TABLE sync_deleted_messages (
  ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE,
  guid TEXT NOT NULL,
  recordID TEXT
);

CREATE TABLE message_processing_task (
  ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE,
  guid TEXT NOT NULL,
  task_flags INTEGER NOT NULL
);

CREATE TABLE handle (
  ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE,
  id TEXT NOT NULL,
  country TEXT,
  service TEXT NOT NULL,
  uncanonicalized_id TEXT,
  person_centric_id TEXT,
  UNIQUE (id, service)
);

CREATE TABLE sync_deleted_chats (
  ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE,
  guid TEXT NOT NULL,
  recordID TEXT,
  timestamp INTEGER
);

CREATE TABLE message_attachment_join (
  message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE,
  attachment_id INTEGER REFERENCES attachment (ROWID) ON DELETE CASCADE,
  UNIQUE(message_id, attachment_id)
);

CREATE TABLE sync_deleted_attachments (
  ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE,
  guid TEXT NOT NULL,
  recordID TEXT
);

CREATE TABLE kvtable (
  ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE,
  key TEXT UNIQUE NOT NULL,
  value BLOB NOT NULL
);

CREATE TABLE chat_message_join (
  chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE,
  message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE,
  message_date INTEGER DEFAULT 0,
  PRIMARY KEY (chat_id, message_id)
);

CREATE TABLE message (
  ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
  guid TEXT UNIQUE NOT NULL,
  text TEXT,
  replace INTEGER DEFAULT 0,
  service_center TEXT,
  handle_id INTEGER DEFAULT 0,
  subject TEXT,
  country TEXT,
  attributedBody BLOB,
  version INTEGER DEFAULT 0,
  type INTEGER DEFAULT 0,
  service TEXT,
  account TEXT,
  account_guid TEXT,
  error INTEGER DEFAULT 0,
  date INTEGER,
  date_read INTEGER,
  date_delivered INTEGER,
  is_delivered INTEGER DEFAULT 0,
  is_finished INTEGER DEFAULT 0,
  is_emote INTEGER DEFAULT 0,
  is_from_me INTEGER DEFAULT 0,
  is_empty INTEGER DEFAULT 0,
  is_delayed INTEGER DEFAULT 0,
  is_auto_reply INTEGER DEFAULT 0,
  is_prepared INTEGER DEFAULT 0,
  is_read INTEGER DEFAULT 0,
  is_system_message INTEGER DEFAULT 0,
  is_sent INTEGER DEFAULT 0,
  has_dd_results INTEGER DEFAULT 0,
  is_service_message INTEGER DEFAULT 0,
  is_forward INTEGER DEFAULT 0,
  was_downgraded INTEGER DEFAULT 0,
  is_archive INTEGER DEFAULT 0,
  cache_has_attachments INTEGER DEFAULT 0,
  cache_roomnames TEXT,
  was_data_detected INTEGER DEFAULT 0,
  was_deduplicated INTEGER DEFAULT 0,
  is_audio_message INTEGER DEFAULT 0,
  is_played INTEGER DEFAULT 0,
  date_played INTEGER,
  item_type INTEGER DEFAULT 0,
  other_handle INTEGER DEFAULT 0,
  group_title TEXT,
  group_action_type INTEGER DEFAULT 0,
  share_status INTEGER DEFAULT 0,
  share_direction INTEGER DEFAULT 0,
  is_expirable INTEGER DEFAULT 0,
  expire_state INTEGER DEFAULT 0,
  message_action_type INTEGER DEFAULT 0,
  message_source INTEGER DEFAULT 0,
  associated_message_guid TEXT,
  associated_message_type INTEGER DEFAULT 0,
  balloon_bundle_id TEXT,
  payload_data BLOB,
  expressive_send_style_id TEXT,
  associated_message_range_location INTEGER DEFAULT 0,
  associated_message_range_length INTEGER DEFAULT 0,
  time_expressive_send_played INTEGER,
  message_summary_info BLOB,
  ck_sync_state INTEGER DEFAULT 0,
  ck_record_id TEXT,
  ck_record_change_tag TEXT,
  destination_caller_id TEXT,
  is_corrupt INTEGER DEFAULT 0,
  reply_to_guid TEXT,
  sort_id INTEGER,
  is_spam INTEGER DEFAULT 0,
  has_unseen_mention INTEGER DEFAULT 0,
  thread_originator_guid TEXT,
  thread_originator_part TEXT,
  syndication_ranges TEXT,
  synced_syndication_ranges TEXT,
  was_delivered_quietly INTEGER DEFAULT 0,
  did_notify_recipient INTEGER DEFAULT 0
);

CREATE TABLE chat (
  ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
  guid TEXT UNIQUE NOT NULL,
  style INTEGER,
  state INTEGER,
  account_id TEXT,
  properties BLOB,
  chat_identifier TEXT,
  service_name TEXT,
  room_name TEXT,
  account_login TEXT,
  is_archived INTEGER DEFAULT 0,
  last_addressed_handle TEXT,
  display_name TEXT,
  group_id TEXT,
  is_filtered INTEGER DEFAULT 0,
  successful_query INTEGER,
  engram_id TEXT,
  server_change_token TEXT,
  ck_sync_state INTEGER DEFAULT 0,
  original_group_id TEXT,
  last_read_message_timestamp INTEGER DEFAULT 0,
  cloudkit_record_id TEXT,
  last_addressed_sim_id TEXT,
  is_blackholed INTEGER DEFAULT 0,
  syndication_date INTEGER DEFAULT 0,
  syndication_type INTEGER DEFAULT 0
);

CREATE TABLE attachment (
  ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
  guid TEXT UNIQUE NOT NULL,
  created_date INTEGER DEFAULT 0,
  start_date INTEGER DEFAULT 0,
  filename TEXT,
  uti TEXT,
  mime_type TEXT,
  transfer_state INTEGER DEFAULT 0,
  is_outgoing INTEGER DEFAULT 0,
  user_info BLOB,
  transfer_name TEXT,
  total_bytes INTEGER DEFAULT 0,
  is_sticker INTEGER DEFAULT 0,
  sticker_user_info BLOB,
  attribution_info BLOB,
  hide_attachment INTEGER DEFAULT 0,
  ck_sync_state INTEGER DEFAULT 0,
  ck_server_change_token_blob BLOB,
  ck_record_id TEXT,
  original_guid TEXT UNIQUE NOT NULL,
  is_commsafety_sensitive INTEGER DEFAULT 0
);

CREATE TABLE sqlite_stat1(tbl, idx, stat);

CREATE INDEX message_attachment_join_idx_message_id ON message_attachment_join(message_id);

CREATE INDEX chat_idx_chat_identifier_service_name ON chat(chat_identifier, service_name);

CREATE INDEX chat_handle_join_idx_handle_id ON chat_handle_join(handle_id);

CREATE INDEX message_attachment_join_idx_attachment_id ON message_attachment_join(attachment_id);

CREATE INDEX message_idx_date ON message(date);

CREATE INDEX attachment_idx_purged_attachments_v2 ON attachment(hide_attachment, ck_sync_state, transfer_state)
WHERE
  hide_attachment = 0
  AND (
    ck_sync_state = 1
    OR ck_sync_state = 4
  )
  AND transfer_state = 0;

CREATE INDEX message_idx_thread_originator_guid ON message(thread_originator_guid);

CREATE INDEX message_idx_handle ON message(handle_id, date);

CREATE INDEX message_idx_handle_id ON message(handle_id);

CREATE INDEX message_idx_is_sent_is_from_me_error ON message(is_sent, is_from_me, error);

CREATE INDEX chat_message_join_idx_message_id_only ON chat_message_join(message_id);

CREATE INDEX message_idx_associated_message ON message(associated_message_guid);

CREATE INDEX chat_idx_chat_identifier ON chat(chat_identifier);

CREATE INDEX message_processing_task_idx_guid_task_flags ON message_processing_task(guid, task_flags);

CREATE INDEX message_idx_undelivered_one_to_one_imessage ON message(
  cache_roomnames,
  service,
  is_sent,
  is_delivered,
  was_downgraded,
  item_type
)
where
  cache_roomnames IS NULL
  AND service = 'iMessage'
  AND is_sent = 1
  AND is_delivered = 0
  AND was_downgraded = 0
  AND item_type == 0;

CREATE INDEX chat_message_join_idx_chat_id ON chat_message_join(chat_id);

CREATE INDEX message_idx_cache_has_attachments ON message(cache_has_attachments);

CREATE INDEX chat_idx_chat_room_name_service_name ON chat(room_name, service_name);

CREATE INDEX message_idx_other_handle ON message(other_handle);

CREATE INDEX message_idx_was_downgraded ON message(was_downgraded);

CREATE INDEX chat_idx_is_archived ON chat(is_archived);

CREATE INDEX chat_idx_group_id ON chat(group_id);

CREATE INDEX message_idx_expire_state ON message(expire_state);

CREATE INDEX chat_message_join_idx_message_date_id_chat_id ON chat_message_join(chat_id, message_date, message_id);

CREATE INDEX message_idx_is_read ON message(is_read, is_from_me, is_finished);

CREATE INDEX message_idx_isRead_isFromMe_itemType ON message(is_read, is_from_me, item_type);

CREATE INDEX message_idx_failed ON message(is_finished, is_from_me, error);

CREATE INDEX message_idx_date_read ON message (date_read);

CREATE TRIGGER after_delete_on_chat_message_join
AFTER
  DELETE ON chat_message_join BEGIN
UPDATE
  message
SET
  cache_roomnames = (
    SELECT
      group_concat(c.room_name)
    FROM
      chat c
      INNER JOIN chat_message_join j ON c.ROWID = j.chat_id
    WHERE
      j.message_id = OLD.message_id
  )
WHERE
  message.ROWID = OLD.message_id;

DELETE FROM
  message
WHERE
  message.ROWID = OLD.message_id
  AND OLD.message_id NOT IN (
    SELECT
      chat_message_join.message_id
    from
      chat_message_join
    WHERE
      chat_message_join.message_id = OLD.message_id
    LIMIT
      1
  );

END;

CREATE TRIGGER after_delete_on_attachment
AFTER
  DELETE ON attachment BEGIN
SELECT
  delete_attachment_path(OLD.filename);

END;

CREATE TRIGGER after_insert_on_message_attachment_join
AFTER
INSERT
  ON message_attachment_join BEGIN
UPDATE
  message
SET
  cache_has_attachments = 1
WHERE
  message.ROWID = NEW.message_id;

END;

CREATE TRIGGER after_delete_on_chat_handle_join
AFTER
  DELETE ON chat_handle_join BEGIN
DELETE FROM
  handle
WHERE
  handle.ROWID = OLD.handle_id
  AND (
    SELECT
      1
    from
      chat_handle_join
    WHERE
      handle_id = OLD.handle_id
    LIMIT
      1
  ) IS NULL
  AND (
    SELECT
      1
    from
      message
    WHERE
      handle_id = OLD.handle_id
    LIMIT
      1
  ) IS NULL
  AND (
    SELECT
      1
    from
      message
    WHERE
      other_handle = OLD.handle_id
    LIMIT
      1
  ) IS NULL;

END;

CREATE TRIGGER after_insert_on_chat_message_join
AFTER
INSERT
  ON chat_message_join BEGIN
UPDATE
  message
SET
  cache_roomnames = (
    SELECT
      group_concat(c.room_name)
    FROM
      chat c
      INNER JOIN chat_message_join j ON c.ROWID = j.chat_id
    WHERE
      j.message_id = NEW.message_id
  )
WHERE
  message.ROWID = NEW.message_id;

END;

CREATE TRIGGER after_delete_on_message
AFTER
  DELETE ON message BEGIN
DELETE FROM
  handle
WHERE
  handle.ROWID = OLD.handle_id
  AND (
    SELECT
      1
    from
      chat_handle_join
    WHERE
      handle_id = OLD.handle_id
    LIMIT
      1
  ) IS NULL
  AND (
    SELECT
      1
    from
      message
    WHERE
      handle_id = OLD.handle_id
    LIMIT
      1
  ) IS NULL
  AND (
    SELECT
      1
    from
      message
    WHERE
      other_handle = OLD.handle_id
    LIMIT
      1
  ) IS NULL;

END;

CREATE TRIGGER update_message_date_after_update_on_message
AFTER
UPDATE
  OF date ON message BEGIN
UPDATE
  chat_message_join
SET
  message_date = NEW.date
WHERE
  message_id = NEW.ROWID
  AND message_date != NEW.date;

END;

CREATE TRIGGER after_delete_on_message_plugin
AFTER
  DELETE ON message
  WHEN OLD.balloon_bundle_id IS NOT NULL BEGIN
SELECT
  after_delete_message_plugin(OLD.ROWID, OLD.guid);

END;

CREATE TRIGGER add_to_sync_deleted_messages
AFTER
  DELETE ON message BEGIN
INSERT INTO
  sync_deleted_messages (guid, recordID)
VALUES
  (OLD.guid, OLD.ck_record_id);

END;

CREATE TRIGGER after_delete_on_chat
AFTER
  DELETE ON chat BEGIN
DELETE FROM
  chat_message_join
WHERE
  chat_id = OLD.ROWID;

END;

CREATE TRIGGER delete_associated_messages_after_delete_on_message
AFTER
  DELETE ON message BEGIN
DELETE FROM
  message
WHERE
  (
    OLD.associated_message_guid IS NULL
    AND associated_message_guid IS NOT NULL
    AND guid = OLD.associated_message_guid
  );

END;

CREATE TRIGGER before_delete_on_attachment BEFORE DELETE ON attachment BEGIN
SELECT
  before_delete_attachment_path(OLD.ROWID, OLD.guid);

END;

CREATE TRIGGER add_to_sync_deleted_attachments
AFTER
  DELETE ON attachment BEGIN
INSERT INTO
  sync_deleted_attachments (guid, recordID)
VALUES
  (OLD.guid, OLD.ck_record_id);

END;

CREATE TRIGGER add_to_deleted_messages
AFTER
  DELETE ON message BEGIN
INSERT INTO
  deleted_messages (guid)
VALUES
  (OLD.guid);

END;

CREATE TRIGGER after_delete_on_message_attachment_join
AFTER
  DELETE ON message_attachment_join BEGIN
DELETE FROM
  attachment
WHERE
  attachment.ROWID = OLD.attachment_id
  AND (
    SELECT
      1
    from
      message_attachment_join
    WHERE
      attachment_id = OLD.attachment_id
    LIMIT
      1
  ) IS NULL;

END;

CREATE TRIGGER update_last_failed_message_date
AFTER
UPDATE
  OF error ON message
  WHEN NEW.error != 0
  AND NEW.date > COALESCE(
    (
      SELECT
        value
      FROM
        kvtable
      WHERE
        key = 'lastFailedMessageDate'
    ),
    0
  ) BEGIN
INSERT
  OR REPLACE INTO kvtable (key, value)
VALUES
  ('lastFailedMessageDate', NEW.date);

INSERT
  OR REPLACE INTO kvtable (key, value)
VALUES
  ('lastFailedMessageRowID', NEW.rowID);

END;
