use napi::bindgen_prelude::{Error as NapiError, ToNapiValue};
use std::fmt::Display;
use std::sync::{Arc, LazyLock, Mutex};

use rustc_hash::FxHashMap;
use sha2::{Digest, Sha512};

// NOTE(skip): not a secret; merely used so that we aren't just hashing the PII standalone
const HASH_FLAVOR: &str = "50884d99c97714e59ad1a8147a145b5ef5528e40cba846de595af3f043327904";

#[napi]
#[derive(Debug)]
pub enum HasherKind {
    Thread,
    Participant,
}

impl Display for HasherKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HasherKind::Thread => write!(f, "thread"),
            HasherKind::Participant => write!(f, "thread"),
        }
    }
}

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

/// "imsg##<type>:0123456789abcdef"
pub type Token = String;
pub type Pii = String;
pub type DigestBytes = [u8; 64];

fn digest_bytes_to_hex(b: &DigestBytes) -> String {
    base16ct::lower::encode_string(b)
}

fn hex_to_bytes(hex: &str) -> Result<DigestBytes, HasherError> {
    let v = base16ct::lower::decode_vec(hex).map_err(HasherError::DecodingHex)?;
    v.try_into().map_err(|_| HasherError::IncorrectSize)
}

// interior mutability for convenient access from JS and Rust
#[napi]
#[derive(Clone)]
pub struct Hasher {
    inner: Arc<Mutex<HasherInner>>,
}

struct HasherInner {
    kind: HasherKind,
    originals: FxHashMap<DigestBytes, Pii>,
    cache: FxHashMap<Token, DigestBytes>,
    hasher: Sha512,
}

#[napi]
impl Hasher {
    #[napi(constructor)]
    pub fn new(kind: HasherKind) -> Self {
        Self {
            inner: Arc::new(Mutex::new(HasherInner::new(kind))),
        }
    }

    pub fn original(&self, token: Token) -> Result<Pii, HasherError> {
        let inner = Arc::clone(&self.inner);
        let lock = inner.lock().expect("mutex poisoned");
        lock.original(token)
    }

    pub fn hash_and_remember(&self, pii: impl AsRef<str>) -> Token {
        let inner = Arc::clone(&self.inner);
        let mut lock = inner.lock().expect("mutex poisoned");
        lock.hash_and_remember(pii)
    }
}

impl HasherInner {
    fn new(kind: HasherKind) -> Self {
        Self {
            kind,
            originals: FxHashMap::default(),
            cache: FxHashMap::default(),
            hasher: Sha512::default(),
        }
    }

    fn hash_text(&self, input: &str) -> String {
        format!("{kind}_{HASH_FLAVOR}_{input}", kind = self.kind)
    }

    fn wrap_hex(&self, hex: &str) -> Token {
        format!("imsg##{kind}:{hex}", kind = self.kind)
    }

    pub fn original(&self, token: Token) -> Result<Pii, HasherError> {
        let Some((_, hex)) = token.split_once(':') else {
            return Err(HasherError::MalformedInput(token));
        };

        let digest_bytes = hex_to_bytes(&hex)?;
        let Some(pii) = self.originals.get(&digest_bytes) else {
            return Err(HasherError::OriginalNotFound(digest_bytes));
        };
        Ok(pii.clone())
    }

    pub fn hash_and_remember(&mut self, pii: impl AsRef<str>) -> Token {
        let pii = pii.as_ref();

        if let Some(cached_digest) = self.cache.get(pii) {
            // we've already hashed this
            return self.wrap_hex(&digest_bytes_to_hex(cached_digest));
        }

        self.hasher.update(self.hash_text(pii));
        let output: DigestBytes = self.hasher.finalize_reset().into();

        self.cache.insert(pii.to_owned(), output);
        self.originals.insert(output, pii.to_owned());
        self.wrap_hex(&digest_bytes_to_hex(&output))
    }
}

pub static THREAD_HASHER: LazyLock<Hasher> = LazyLock::new(|| Hasher::new(HasherKind::Thread));
pub static PARTICIPANT_HASHER: LazyLock<Hasher> =
    LazyLock::new(|| Hasher::new(HasherKind::Participant));

#[napi]
pub fn hash_thread_id(thread_id: String) -> String {
    (&*THREAD_HASHER.hash_and_remember(thread_id)).to_owned()
}

#[napi]
pub fn hash_participant_id(participant_id: String) -> String {
    (&*PARTICIPANT_HASHER.hash_and_remember(participant_id)).to_owned()
}

#[napi]
pub fn original_thread_id(hashed: String) -> napi::Result<String> {
    Ok(THREAD_HASHER.original(hashed)?)
}

#[napi]
pub fn original_participant_id(hashed: String) -> napi::Result<String> {
    Ok(PARTICIPANT_HASHER.original(hashed)?)
}
