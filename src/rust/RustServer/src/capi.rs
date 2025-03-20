use core::ffi::c_char;
use std::ffi::{CStr, CString};
use std::ptr::null;

use hashing::THREAD_ID_HASHER;

// Hasher APIs are exposed in RustServer (and not e.g. a dedicated `libhasher.dylib`) in order to
// avoid having RustServer link to a dynamic library, and to potentially avoid duplicate global
// hashers.

// TODO(skip): Expose the participant ID hasher.

// (renamed to `rs_token` via `cbindgen.toml`)
pub type CToken = *const c_char;
pub type CTokenMut = *mut c_char;

#[no_mangle]
pub unsafe extern "C" fn rs_hash_thread_id(thread_id: *const c_char) -> CToken {
    let thread_id = unsafe { CStr::from_ptr(thread_id) };

    let token = THREAD_ID_HASHER.hash_and_remember(
        thread_id
            .to_str()
            .expect("malformed UTF-8 passed to rs_hash_thread_id"),
    );

    CString::new(token)
        .expect("string somehow contains null byte")
        .into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn rs_original_thread_id(token: CToken) -> *const c_char {
    let token = unsafe { CStr::from_ptr(token) }
        .to_str()
        .expect("malformed UTF-8 passed to rs_original_thread_id");

    let Ok(original) = THREAD_ID_HASHER.original(token) else {
        // Bubble up hasher errors as a null string.
        return null();
    };

    CString::new(original)
        .expect("original thread ID somehow contains null byte")
        .into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn rs_free_token(token: CTokenMut) {
    unsafe { drop(CString::from_raw(token)) }
}
