use std::sync::LazyLock;

use crate::hashing::{Hasher, HasherKind};

pub static THREAD_HASHER: LazyLock<Hasher> = LazyLock::new(|| Hasher::new(HasherKind::Thread));
pub static PARTICIPANT_HASHER: LazyLock<Hasher> =
    LazyLock::new(|| Hasher::new(HasherKind::Participant));

// JS entrypoints
// (#[napi] attribute exposes these functions in the N-API binding despite not being `pub`)

#[napi]
fn hash_thread_id(thread_id: String) -> String {
    THREAD_HASHER.hash_and_remember(thread_id)
}

#[napi]
fn hash_participant_id(participant_id: String) -> String {
    PARTICIPANT_HASHER.hash_and_remember(participant_id)
}

#[napi]
fn original_thread_id(hashed: String) -> napi::Result<String> {
    Ok(THREAD_HASHER.original(hashed)?)
}

#[napi]
fn original_participant_id(hashed: String) -> napi::Result<String> {
    Ok(PARTICIPANT_HASHER.original(hashed)?)
}
