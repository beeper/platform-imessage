use thiserror::Error;

#[derive(Error, Debug)]
pub enum ServerError {
    #[error("IO error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("Sqlite error: {0}")]
    SqliteError(#[from] rusqlite::Error),

    #[error("Cannot find home directory")]
    CannotFindHomeDirectory,
}

pub type ServerResult<T> = std::result::Result<T, ServerError>;
