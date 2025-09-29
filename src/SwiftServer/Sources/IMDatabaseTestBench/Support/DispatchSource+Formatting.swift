import Foundation

extension DispatchSource.FileSystemEvent {
    var imdb_description: String {
        switch self {
        case .all: "all"
        case .attrib: "attrib"
        case .delete: "delete"
        case .extend: "extend"
        case .funlock: "funlock"
        case .link: "link"
        case .rename: "rename"
        case .revoke: "revoke"
        case .write: "write"
        default: "unknown"
        }
    }
}
