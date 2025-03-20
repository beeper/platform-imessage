use crate::{DigestBytes, HasherError};

pub(crate) fn digest_bytes_to_hex(b: &DigestBytes) -> String {
    base16ct::lower::encode_string(b)
}

pub(crate) fn hex_to_bytes(hex: &str) -> Result<DigestBytes, HasherError> {
    let byte_vec = base16ct::lower::decode_vec(hex).map_err(HasherError::DecodingHex)?;
    byte_vec.try_into().map_err(|_| HasherError::IncorrectSize)
}
