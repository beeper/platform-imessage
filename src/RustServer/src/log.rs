use std::path::PathBuf;
use std::sync::Once;

static INIT_LOGGING: Once = Once::new();

fn app_data_dir() -> Option<PathBuf> {
    let mut home_dir = PathBuf::from(std::env::var("HOME").ok()?);
    let app_dir_name = if let Ok(profile) = std::env::var("BEEPER_PROFILE") {
        format!("BeeperTexts-{profile}")
    } else {
        "BeeperTexts".to_owned()
    };

    // Probably okay to hardcode this because RustServer only runs on Mac.
    home_dir.extend(["Library", "Application Support", &app_dir_name].iter());
    Some(home_dir)
}

const ROLLING_LOG_FILE_NAME_PREFIX: &str = "platform-imessage-poller.log";

pub(crate) fn init_logging_once() {
    INIT_LOGGING.call_once(|| {
        let Some(app_dir) = app_data_dir() else {
            eprintln!("platform-imessage: unable to resolve app data directory!");
            return;
        };
        let log_dir = app_dir.join("logs").join("platform-imessage");

        if let Err(err) = std::fs::create_dir_all(&log_dir) {
            eprintln!(
                "platform-imessage: failed to create log directory {log_dir:?} because: {err:?}"
            );
            return;
        }

        // Not using the non-blocking logger because it isn't uncommon for the app to crash and
        // suddenly exit, which can lose log entries.
        let appender = tracing_appender::rolling::daily(log_dir, ROLLING_LOG_FILE_NAME_PREFIX);

        use tracing_subscriber::prelude::*;

        tracing_subscriber::registry()
            .with(
                tracing_subscriber::fmt::layer()
                    .event_format(tracing_subscriber::fmt::format().json())
                    .with_writer(appender),
            )
            .with(
                tracing_subscriber::EnvFilter::from_env("RUST_SERVER_LOG")
                    .add_directive(tracing::Level::DEBUG.into()),
            )
            .init();
    });
}
