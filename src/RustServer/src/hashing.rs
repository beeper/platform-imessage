mod error;
mod globals;

use napi::bindgen_prelude::ToNapiValue;
use std::fmt::Display;
use std::sync::{Arc, Mutex};

use rustc_hash::FxHashMap;
use sha2::{Digest, Sha512};

pub use error::HasherError;
#[allow(unused_imports)]
pub use globals::{PARTICIPANT_ID_HASHER, THREAD_ID_HASHER};

// NOTE(skip): not a secret; merely used so that we aren't just hashing the PII standalone
const HASH_FLAVOR: &str = "50884d99c97714e59ad1a8147a145b5ef5528e40cba846de595af3f043327904";

#[napi]
#[derive(Debug)]
pub enum HasherKind {
    ThreadID,
    ParticipantID,
}

impl Display for HasherKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HasherKind::ThreadID => write!(f, "thread"),
            HasherKind::ParticipantID => write!(f, "thread"),
        }
    }
}

/// a string encompassing an opaque identifier of a certain type
/// looks like: `imsg##<kind>:0123456789abcdef`
pub type Token = String;

/// "personally identifiable information"
pub type Pii = String;

/// sha-512 hash output
pub type DigestBytes = [u8; 64];

fn digest_bytes_to_hex(b: &DigestBytes) -> String {
    base16ct::lower::encode_string(b)
}

fn hex_to_bytes(hex: &str) -> Result<DigestBytes, HasherError> {
    let v = base16ct::lower::decode_vec(hex).map_err(HasherError::DecodingHex)?;
    v.try_into().map_err(|_| HasherError::IncorrectSize)
}

#[napi]
#[derive(Clone)]
pub struct Hasher {
    kind: HasherKind,
    // interior mutability for convenient access from JS and Rust
    inner: Arc<Mutex<HasherInner>>,
}

#[napi]
impl Hasher {
    #[napi(constructor)]
    pub fn new(kind: HasherKind) -> Self {
        Self {
            kind,
            inner: Arc::new(Mutex::new(HasherInner::default())),
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

        let inner = Arc::clone(&self.inner);
        let lock = inner.lock().expect("mutex poisoned");

        let digest_bytes = hex_to_bytes(&hex)?;
        let Some(pii) = lock.originals.get(&digest_bytes) else {
            return Err(HasherError::OriginalNotFound(digest_bytes));
        };
        Ok(pii.clone())
    }

    pub fn hash_and_remember(&self, pii: impl AsRef<str>) -> Token {
        let pii = pii.as_ref();

        let inner = Arc::clone(&self.inner);
        let mut lock = inner.lock().expect("mutex poisoned");

        let digest_bytes: DigestBytes = if let Some(cached_digest) = lock.cache.get(pii) {
            *cached_digest
        } else {
            lock.hasher.update(self.hash_text(pii));
            let digest: DigestBytes = lock.hasher.finalize_reset().into();

            lock.cache.insert(pii.to_owned(), digest);
            lock.originals.insert(digest, pii.to_owned());
            digest
        };

        self.wrap_hex(&digest_bytes_to_hex(&digest_bytes))
    }
}

struct HasherInner {
    pub(crate) originals: FxHashMap<DigestBytes, Pii>,
    pub(crate) cache: FxHashMap<Token, DigestBytes>,
    pub(crate) hasher: Sha512,
}

impl HasherInner {
    fn new() -> Self {
        Self {
            originals: FxHashMap::default(),
            cache: FxHashMap::default(),
            hasher: Sha512::default(),
        }
    }
}

impl Default for HasherInner {
    fn default() -> Self {
        Self::new()
    }
}
