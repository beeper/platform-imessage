use std::cell::RefCell;
use std::sync::Arc;

use neon::prelude::*;

use crate::poller::Poller;

// TODO: Proper error propagation.
// Errors needs to be propagated to the server from inner calls,
// and perhaps emitted as an event on TS wrapper side.
pub struct Server(Option<ServerInner>);

pub struct ServerInner {
    poller: Poller,

    shared: Arc<Shared>,
}

pub struct Shared {
    pub channel: Channel,

    // TODO: If in the future, multiple root callback fn are saved,
    // we should create a dedicated "Callback" unit struct.
    pub callback: Root<JsFunction>,
}

pub type BoxedServer = JsBox<RefCell<Server>>;

impl Finalize for Server {}

impl Server {
    pub fn new<'a, C: Context<'a>>(cx: &mut C, cb: Root<JsFunction>) -> Self {
        Self(Some(ServerInner::new(cx, cb)))
    }

    pub fn containerize(cb: ServerInner) -> RefCell<Server> {
        RefCell::new(Self(Some(cb)))
    }
}

// JS v8 bindings
impl Server {
    pub fn js_new(mut cx: FunctionContext) -> JsResult<BoxedServer> {
        let handler = cx.argument::<JsFunction>(0)?.root(&mut cx);

        let inner = Self::new(&mut cx, handler);

        Ok(JsBox::new(&mut cx, RefCell::new(inner)))
    }

    pub fn js_start_poller(mut cx: FunctionContext) -> JsResult<BoxedServer> {
        let last_row_id = cx.argument::<JsNumber>(0)?.value(&mut cx) as u64;
        let last_date_read = cx.argument::<JsNumber>(1)?.value(&mut cx) as u64;

        let boxed = cx.this().downcast_or_throw::<BoxedServer, _>(&mut cx)?;

        let mut rm = boxed.borrow_mut();

        let cb = rm.0.take().unwrap();

        cb.start_poller(last_row_id, last_date_read);

        Ok(JsBox::new(&mut cx, Self::containerize(cb)))
    }

    pub fn js_stop_poller(mut cx: FunctionContext) -> JsResult<BoxedServer> {
        let boxed = cx.this().downcast_or_throw::<BoxedServer, _>(&mut cx)?;

        let mut rm = boxed.borrow_mut();

        let cb = rm.0.take().unwrap();

        cb.stop_poller();

        Ok(JsBox::new(&mut cx, Self::containerize(cb)))
    }

    pub fn js_destroy(mut cx: FunctionContext) -> JsResult<JsUndefined> {
        let boxed = cx.this().downcast_or_throw::<BoxedServer, _>(&mut cx)?;

        let mut rm = boxed.borrow_mut();

        let cb = rm.0.take().unwrap();

        drop(cb);

        Ok(cx.undefined())
    }
}

impl Drop for ServerInner {
    fn drop(&mut self) {
        self.poller.stop();
    }
}

impl ServerInner {
    fn new<'a, C: Context<'a>>(cx: &mut C, cb: Root<JsFunction>) -> Self {
        let shared = Arc::new(Shared::new(cb, cx.channel()));

        Self {
            poller: Poller::new(shared.clone()),
            shared,
        }
    }

    pub fn start_poller(&self, last_row_id: u64, last_date_read: u64) {
        self.poller.start(last_row_id, last_date_read);
    }

    pub fn stop_poller(&self) {
        self.poller.stop();
    }
}

impl Shared {
    pub fn new(cb: Root<JsFunction>, channel: Channel) -> Self {
        Self {
            callback: cb,
            channel,
        }
    }
}
