/** types from platform-sdk */
use napi::bindgen_prelude::*;

pub type ServerEvent = Either3<ToastEvent, ThreadMessagesRefreshEvent, UpdateStateSyncEvent>;

#[napi(object)]
pub struct Toast {
    pub id: Option<String>,

    pub text: String,

    pub timeout_ms: Option<u32>,
}

#[napi(object)]
pub struct ToastEvent {
    pub r#type: String,

    pub toast: Toast,
}

impl ToastEvent {
    pub fn new(text: String) -> ToastEvent {
        ToastEvent {
            r#type: "toast".to_string(),
            toast: Toast {
                id: None,
                text,
                timeout_ms: None,
            },
        }
    }
}

#[napi(object)]
pub struct ThreadMessagesRefreshEvent {
    pub r#type: String,

    #[napi(js_name = "threadID")]
    pub thread_id: String,
}

impl ThreadMessagesRefreshEvent {
    pub fn new(thread_id: String) -> ThreadMessagesRefreshEvent {
        ThreadMessagesRefreshEvent {
            r#type: "thread_messages_refresh".to_string(),
            thread_id,
        }
    }
}

#[napi(object)]
pub struct ObjectIDs {
    #[napi(js_name = "threadID")]
    pub thread_id: Option<String>,

    #[napi(js_name = "messageID")]
    pub message_id: Option<String>,
}

#[napi(object)]
pub struct UpdateStateSyncEvent {
    pub r#type: String,

    #[napi(js_name = "objectIDs")]
    pub object_ids: ObjectIDs,

    pub object_name: String,

    pub mutation_type: String,

    pub entries: Vec<UpdateStateSyncEventEntry>,
}

#[napi(object)]
pub struct UpdateStateSyncEventEntry {
    pub id: String,

    pub unread_count: f64,
    pub last_read_message_sort_key: f64,
}

impl UpdateStateSyncEvent {
    pub fn new(thread_id: String, unread_count: u64, last_read_message_sort_key: u64) -> Self {
        UpdateStateSyncEvent {
            r#type: "state_sync".to_string(),
            object_ids: ObjectIDs {
                thread_id: None,
                message_id: None,
            },
            object_name: "thread".to_string(),
            mutation_type: "update".to_string(),
            entries: vec![UpdateStateSyncEventEntry {
                id: thread_id,
                // FIXME(skip): DESK-8155
                unread_count: unread_count as f64,
                // FIXME(skip): DESK-8155
                last_read_message_sort_key: last_read_message_sort_key as f64,
            }],
        }
    }
}
