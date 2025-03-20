use crate::DigestBytes;

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

#[cfg(feature = "napi")]
impl From<HasherError> for napi::bindgen_prelude::Error {
    fn from(error: HasherError) -> Self {
        napi::bindgen_prelude::Error::from_reason(format!("{}", error))
    }
}
