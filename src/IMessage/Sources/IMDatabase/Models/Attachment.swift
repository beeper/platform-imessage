public struct Attachment: Identifiable {
    public var id: Int
    /** formatted like "at_`(part number)`_`(uuid)`", e.g. `at_1_55E4DD19-D7DC-4457-8BE2-B6458F755F81` */
    public var guid: GUID<Attachment>
    /** file path to the attachment, e.g. `~/Library/Messages/Attachments/30/00/at_1_7B8C5CE4-FD7F-4D3D-BCC2-7E4E8504BAA0/IMG_5553.png` */
    public var fileName: String?
    /** seemingly the basename of the file path, e.g. `IMG_5553.png` */
    public var transferName: String?
    public var isSticker: Bool
    public var transferState: IMFileTransferState?
    // TODO: not using UTType due to deployment target
    public var uti: String?
}

// MARK: - Attachment+IMFileTransferState

public extension Attachment {
    struct IMFileTransferState: RawRepresentable, Equatable, Hashable, Sendable {
        public var rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let waitingForAccept = Self(rawValue: 0)
        public static let accepted = Self(rawValue: 1)
        public static let preparing = Self(rawValue: 2)
        public static let transferring = Self(rawValue: 3)
        public static let finalizing = Self(rawValue: 4)
        public static let finished = Self(rawValue: 5)
        public static let error = Self(rawValue: 6)
        public static let recoverableError = Self(rawValue: 7)
        public static let rejected = Self(rawValue: 8)
        public static let thumbnail = Self(rawValue: 9)

        /// A state the file will never recover from, so any waiter should give up
        /// rather than poll out its full timeout budget.
        public var isTerminalFailure: Bool {
            self == .error || self == .recoverableError || self == .rejected
        }
    }
}
