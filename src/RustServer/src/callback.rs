use std::sync::Arc;

use neon::prelude::*;

#[derive(Clone)]
pub struct Callback(pub Arc<Root<JsFunction>>);

impl Finalize for Callback {}

impl Callback {
    pub fn new(callback: Root<JsFunction>) -> Self {
        Self(Arc::new(callback))
    }
}
