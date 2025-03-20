use crate::hashing::DigestBytes;
use napi::bindgen_prelude::Error as NapiError;

#[derive(thiserror::Error, Debug)]
pub enum HasherError {
    #[error("failed to decode hex string: {0}")]
    DecodingHex(base16ct::Error),
    #[error("hex string was too long")]
    IncorrectSize,
    #[error("couldn't find corresponding original from token: \"{0:?}\"")]
    OriginalNotFound(DigestBytes),
    #[error("malformed input: \"{0}\"")]
    MalformedInput(String),
}

impl From<HasherError> for NapiError {
    fn from(error: HasherError) -> Self {
        NapiError::from_reason(format!("{}", error)).into()
    }
}
