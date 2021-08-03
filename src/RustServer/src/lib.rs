use neon::prelude::*;

mod poller;
mod server;

#[neon::main]
fn main(mut cx: ModuleContext) -> NeonResult<()> {
    cx.export_function("newServer", server::Server::js_new)?;
    cx.export_function("dropServer", server::Server::js_destroy)?;

    cx.export_function("startPoller", server::Server::js_start_poller)?;
    cx.export_function("stopPoller", server::Server::js_stop_poller)?;

    Ok(())
}
