extension PlatformSDK {
    public enum PaginationDirection: String, Sendable {
        case after
        case before
    }

    public struct PaginationArg: Sendable {
        public let cursor: String
        public let direction: PaginationDirection

        public init(cursor: String, direction: PaginationDirection) {
            self.cursor = cursor
            self.direction = direction
        }
    }
}
