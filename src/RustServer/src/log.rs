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

const LOG_FILE_NAME: &str = "platform-imessage-poller.log";

pub(crate) fn init_logging_once() {
    INIT_LOGGING.call_once(|| {
        let Some(app_dir) = app_data_dir() else {
            eprintln!("platform-imessage: unable to resolve app data directory!");
            return;
        };
        let logs_dir = app_dir.join("logs");

        if let Err(err) = std::fs::create_dir_all(&logs_dir) {
            eprintln!(
                "platform-imessage: failed to create log directory {logs_dir:?} because: {err:?}"
            );
            return;
        }

        // Manually keep the log file under 10 MiB every launch. Not using `tracing_appender`'s
        // built-in rolling functionality because Desktop's RollingLogger isn't familiar with its
        // naming scheme (looks like `name.log.2025-03-31`; it'd only compare the day).
        const TEN_MIB: u64 = 10 * 1_024 * 1_024;
        let log_file_path = logs_dir.join(LOG_FILE_NAME);
        if let Ok(stats) = std::fs::metadata(&log_file_path) {
            if stats.len() > TEN_MIB {
                match std::fs::remove_file(&log_file_path) {
                    Ok(_) => eprintln!("platform-imessage: deleted big log file"),
                    Err(_) => eprintln!("platform-imessage: couldn't delete big log file"),
                }
            } else {
                // Log file is still under the threshold, so keep on appending to it.
            }
        } else {
            eprintln!("platform-imessage: no log file yet");
        }

        // Not using the non-blocking logger because it isn't uncommon for the app to crash and
        // suddenly exit, which can lose log entries.
        let appender = tracing_appender::rolling::never(logs_dir, LOG_FILE_NAME);

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
