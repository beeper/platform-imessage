use hashing::{PARTICIPANT_ID_HASHER, THREAD_ID_HASHER};

#[napi]
fn hash_thread_id(thread_id: String) -> String {
    THREAD_ID_HASHER.hash_and_remember(thread_id)
}

#[napi]
fn hash_participant_id(participant_id: String) -> String {
    PARTICIPANT_ID_HASHER.hash_and_remember(participant_id)
}

#[napi]
fn original_thread_id(hashed: String) -> napi::Result<String> {
    Ok(THREAD_ID_HASHER.original(hashed)?)
}

#[napi]
fn original_participant_id(hashed: String) -> napi::Result<String> {
    Ok(PARTICIPANT_ID_HASHER.original(hashed)?)
}
