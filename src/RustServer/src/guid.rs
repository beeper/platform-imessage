use std::fmt::Debug;

use rusqlite::types::{FromSql, FromSqlResult, ValueRef};

use crate::hashing::{Token, THREAD_ID_HASHER};

#[derive(Clone, PartialEq, Eq, Hash)]
pub(crate) struct ChatGuid(String);

impl ChatGuid {
    pub(crate) fn seal(guid: impl Into<String>) -> Self {
        Self(guid.into())
    }

    pub(crate) fn token(&self) -> Token {
        THREAD_ID_HASHER.hash_and_remember(&self.0)
    }

    // pub(crate) fn expose(&self) -> &str {
    //     &self.0
    // }
}

impl Debug for ChatGuid {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let token = THREAD_ID_HASHER.hash_and_remember(&self.0);
        write!(f, "{}", token)
    }
}

impl FromSql for ChatGuid {
    fn column_result(value: ValueRef<'_>) -> FromSqlResult<Self> {
        String::column_result(value).map(ChatGuid::seal)
    }
}
