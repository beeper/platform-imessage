import Foundation

extension PlatformSDK {
    /// Matches platform-sdk's `createThread?: (...) => Awaitable<boolean | Thread>`.
    public enum CreateThreadResult: JSONValueConvertible {
        case boolean(Bool)
        case thread(Thread)

        public var jsonValue: Any {
            switch self {
            case let .boolean(value):
                return value
            case let .thread(thread):
                return thread.jsonObject
            }
        }
    }

    /// Matches platform-sdk's `sendMessage?: (...) => Promise<boolean | Message[]>`.
    public enum MessageSendResult: JSONValueConvertible {
        case boolean(Bool)
        case messages([Message])

        public var jsonValue: Any {
            switch self {
            case let .boolean(value):
                return value
            case let .messages(messages):
                return messages.map(\.jsonObject)
            }
        }
    }
}
