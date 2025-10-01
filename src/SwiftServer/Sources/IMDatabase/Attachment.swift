public struct Attachment: Identifiable {
    public var id: Int
    /** formatted like "at_`(part number)`_`(uuid)`", e.g. `at_1_55E4DD19-D7DC-4457-8BE2-B6458F755F81` */
    public var guid: GUID<Attachment>
    /** file path to the attachment, e.g. `~/Library/Messages/Attachments/30/00/at_1_7B8C5CE4-FD7F-4D3D-BCC2-7E4E8504BAA0/IMG_5553.png` */
    public var fileName: String?
    /** seemingly the basename of the file path, e.g. `IMG_5553.png` */
    public var transferName: String?
    public var isSticker: Bool
    public var transferState: TransferState?
}

// MARK: - Attachment+Transfer State

public extension Attachment {
    struct TransferState: RawRepresentable, Equatable, Hashable {
        public var rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static var notDownloaded: Self { Self(rawValue: 0) }
        // 1: unknown
        public static var downloading: Self { Self(rawValue: 3) }
        public static var downloaded: Self { Self(rawValue: 5) }
        // 6: unknown
    }
}

extension Attachment.TransferState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notDownloaded: "not downloaded"
        case .downloading: "downloading"
        case .downloaded: "downloaded"
        default: "unknown (\(self))"
        }
    }
}
