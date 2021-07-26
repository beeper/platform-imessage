use std::io::BufRead;

use serde::Deserialize;

mod server;

#[derive(Deserialize)]
struct Command<'c> {
    method: &'c str,

    args: Vec<u64>,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    for line in std::io::stdin().lock().lines() {
        let mut line = line?;

        let command: Command<'_> = serde_json::from_str(&mut line)?;

        match command.method {
            // args: [ last_row_id, last_date_read ]
            "start_polling" => {
                let last_row_id = command.args[0];
                let last_date_read = command.args[1];

                std::thread::spawn(move || {
                    server::Server::new().start(last_row_id, last_date_read);
                });
            }

            m => eprintln!("Unimplemented method {}", m),
        }
    }

    Ok(())
}
