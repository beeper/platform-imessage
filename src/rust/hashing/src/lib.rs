mod convert;
mod error;
mod hasher;
mod inner;
mod kind;

use std::sync::LazyLock;

pub use error::HasherError;
pub use kind::HasherKind;

use crate::hasher::Hasher;

// These aliases don't provide any real type safety but help improve readability:

/// A string encompassing an opaque identifier of a certain type, incorporating a hash.
///
/// Looks like: `imsg##<kind>:0123456789abcdef`
pub type Token = String;

/// Personally identifiable information.
pub type Pii = String;

/// SHA-512 hash output.
pub type DigestBytes = [u8; crate::hasher::TRIMMED_HASH_SIZE_BYTES];

#[rustfmt::skip]
pub static THREAD_ID_HASHER: LazyLock<Hasher> =
    LazyLock::new(|| Hasher::new(HasherKind::ThreadID));

pub static PARTICIPANT_ID_HASHER: LazyLock<Hasher> =
    LazyLock::new(|| Hasher::new(HasherKind::ParticipantID));
