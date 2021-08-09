use std::cell::RefCell;
use std::sync::Arc;

use neon::prelude::*;

use crate::callback::Callback;
use crate::error::ServerResult;
use crate::poller::Poller;

pub struct Server(Option<ServerInner>);

pub struct ServerInner {
    poller: Poller,

    shared: Arc<Shared>,
}

pub struct Shared {
    pub channel: Channel,

    pub callback: Callback,
}

pub type BoxedServer = JsBox<RefCell<Server>>;

impl Finalize for Server {}

impl Server {
    pub fn new<'a, C: Context<'a>>(cx: &mut C, cb: Root<JsFunction>) -> ServerResult<Self> {
        Ok(Self(Some(ServerInner::new(cx, cb)?)))
    }

    pub fn containerize(cb: ServerInner) -> RefCell<Server> {
        RefCell::new(Self(Some(cb)))
    }
}

// JS v8 bindings
impl Server {
    pub fn js_new(mut cx: FunctionContext) -> JsResult<BoxedServer> {
        let handler = cx.argument::<JsFunction>(0)?.root(&mut cx);

        match Self::new(&mut cx, handler) {
            Ok(inner) => {
                // TODO: Should we invoke callback with error here?

                Ok(JsBox::new(&mut cx, RefCell::new(inner)))
            }

            Err(e) => cx.throw_error(e.to_string()),
        }
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
    fn new<'a, C: Context<'a>>(cx: &mut C, cb: Root<JsFunction>) -> ServerResult<Self> {
        let shared = Arc::new(Shared::new(cb, cx.channel()));

        Ok(Self {
            poller: Poller::new(shared.clone())?,
            shared,
        })
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
            callback: Callback::new(cb),
            channel,
        }
    }

    pub fn emit_error(&self, error: String) {
        let cb = self.callback.clone();

        self.channel.send(move |mut cx| {
            let cb = cb.0.to_inner(&mut cx);
            let this = cx.undefined();

            let arr = cx.empty_array();

            let err_obj = cx.empty_object();

            let event_type = cx.string("toast");
            err_obj.set(&mut cx, "type", event_type)?;

            let toast_obj = cx.empty_object();
            let toast_text = cx.string(error);
            toast_obj.set(&mut cx, "text", toast_text)?;

            err_obj.set(&mut cx, "toast", toast_obj)?;

            arr.set(&mut cx, 0, err_obj)?;

            let args = vec![arr];

            cb.call(&mut cx, this, args)?;

            Ok(())
        });
    }
}
