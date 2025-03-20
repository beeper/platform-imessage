use std::sync::{Arc, Mutex};

use sha2::Digest as _;

use crate::convert::{digest_bytes_to_hex, hex_to_bytes};
use crate::inner::HasherInner;
use crate::{DigestBytes, HasherError, HasherKind, Pii, Token};

// NOTE(skip): not a secret; merely used so that we aren't just hashing the PII standalone
const HASH_FLAVOR: &str = "50884d99c97714e59ad1a8147a145b5ef5528e40cba846de595af3f043327904";

// DESK-6988: hex strings of the digests are naturally 128 chars long, which is a bit long.
// trimming this would increase the likelihood of collision but our main motivator for hashing
// is preventing PII leaks while retaining a stable identifier
pub const TRIMMED_HASH_SIZE_BYTES: usize = 24;

#[derive(Clone)]
pub struct Hasher {
    kind: HasherKind,
    // Guard the actual hasher state within an atomically reference-counted mutex so it may be
    // conveniently accessed from Node.js, Swift, etc.
    inner: Arc<Mutex<HasherInner>>,
}

impl Hasher {
    pub fn new(kind: HasherKind) -> Self {
        Self {
            kind,
            inner: Arc::new(Mutex::new(HasherInner::default())),
        }
    }

    fn hash_text(&self, input: &str) -> String {
        format!("{kind}_{HASH_FLAVOR}_{input}", kind = self.kind)
    }

    fn form_token(&self, hex: &str) -> Token {
        format!("imsg##{kind}:{hex}", kind = self.kind)
    }

    pub fn original(&self, token: Token) -> Result<Pii, HasherError> {
        let Some((_, hex)) = token.split_once(':') else {
            return Err(HasherError::MalformedInput(token));
        };

        let inner = Arc::clone(&self.inner);
        let lock = inner.lock().expect("mutex poisoned");

        let digest_bytes = hex_to_bytes(hex)?;
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
            let full_digest: [u8; 64] = lock.hasher.finalize_reset().into();
            let trimmed: DigestBytes = full_digest[..TRIMMED_HASH_SIZE_BYTES]
                .try_into()
                .expect("digest wasn't long enough"); // shouldn't be impossible

            lock.cache.insert(pii.to_owned(), trimmed);
            lock.originals.insert(trimmed, pii.to_owned());
            trimmed
        };

        self.form_token(&digest_bytes_to_hex(&digest_bytes))
    }
}
