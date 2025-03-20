use std::fmt::Display;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HasherKind {
    ThreadID,
    ParticipantID,
}

impl Display for HasherKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HasherKind::ThreadID => write!(f, "thread"),
            HasherKind::ParticipantID => write!(f, "participant"),
        }
    }
}
