use rustc_hash::FxHashMap;
use sha2::Sha512;

use crate::{DigestBytes, Pii, Token};

pub(crate) struct HasherInner {
    pub(crate) originals: FxHashMap<DigestBytes, Pii>,
    pub(crate) cache: FxHashMap<Token, DigestBytes>,
    pub(crate) hasher: Sha512,
}

impl HasherInner {
    pub(crate) fn new() -> Self {
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
