use rustc_hash::{FxHashMap, FxHashSet};

#[derive(Default, Debug, Clone)]
pub(crate) struct Unreads {
    map: FxHashMap<u64 /* chat rowid */, UnreadState>,
}

impl FromIterator<(u64, UnreadState)> for Unreads {
    fn from_iter<T: IntoIterator<Item = (u64, UnreadState)>>(iter: T) -> Self {
        let map = iter.into_iter().collect();
        Self { map }
    }
}

impl Unreads {
    pub(crate) fn get(&self, chat_rowid: u64) -> Option<UnreadState> {
        self.map.get(&chat_rowid).copied()
    }

    pub(crate) fn all(&self) -> &FxHashMap<u64, UnreadState> {
        &self.map
    }

    pub(crate) fn len(&self) -> usize {
        self.map.len()
    }

    pub(crate) fn is_unread(&self, chat_rowid: u64) -> bool {
        self.map.contains_key(&chat_rowid)
    }

    pub(crate) fn diff_with_newer(&self, newer: &Unreads) -> FxHashSet<u64> {
        let mut changed_chat_rowids: FxHashSet<u64> = FxHashSet::default();

        // Check for current states that mismatch with the new map.
        for (&chat_rowid, state) in &self.map {
            if newer.get(chat_rowid) != Some(*state) {
                changed_chat_rowids.insert(chat_rowid);
            }
        }

        // Vice versa.
        for (&chat_rowid, state) in newer.all() {
            if self.get(chat_rowid) != Some(*state) {
                changed_chat_rowids.insert(chat_rowid);
            }
        }

        changed_chat_rowids
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct UnreadState {
    pub(crate) unread_count: u64,
    // (this is relative to Apple's "reference date" epoch; not parsing for now)
    pub(crate) last_read_message_timestamp: u64,
}
