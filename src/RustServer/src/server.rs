use napi::bindgen_prelude::*;
use napi::threadsafe_function::ThreadSafeCallContext;
use napi::threadsafe_function::{ErrorStrategy, ThreadsafeFunction};
use napi::Error;

use crate::poller::Poller;
use crate::sdk::ServerEvent;

pub type EventCallback = ThreadsafeFunction<Vec<ServerEvent>, ErrorStrategy::Fatal>;

#[napi]
pub struct PollerServer {
    // For future usage
    #[allow(dead_code)]
    callback: EventCallback,

    poller: Poller,
}

#[napi]
impl PollerServer {
    #[napi(constructor)]
    pub fn new(callback: JsFunction) -> Result<Self> {
        let tsfn: EventCallback = callback
            .create_threadsafe_function(0, |ctx: ThreadSafeCallContext<Vec<ServerEvent>>| {
                Ok(vec![ctx.value])
            })?;

        let poller = Poller::new(tsfn.clone()).map_err(|e| Error::from_reason(e.to_string()))?;

        Ok(Self {
            callback: tsfn,
            poller,
        })
    }

    #[napi]
    pub fn start_poller(&self, last_row_id: BigInt, last_date_read: BigInt) {
        self.poller
            .start(last_row_id.get_u64().1, last_date_read.get_u64().1);
    }

    #[napi]
    pub fn stop_poller(&self) {
        self.poller.stop();
    }

    #[napi]
    pub fn is_chat_rowid_unread(&self, chat_rowid: BigInt) -> bool {
        self.poller.is_chat_rowid_unread(chat_rowid.get_u64().1)
    }
}
