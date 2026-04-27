import Foundation

extension PlatformSDK {
    public enum AttachmentType: String {
        case unknown
        case img
        case video
        case audio
    }

    @PlatformSDKJSONObject
    public struct Size: JSONObjectConvertible, Sendable {
        public let width: Double
        public let height: Double

    }

    @PlatformSDKJSONObject
    public struct Attachment: JSONObjectConvertible {
        public let id: AttachmentID
        public let type: AttachmentType
        public let size: Size?
        public let posterImg: String?
        public let mimeType: String?
        public let fileName: String?
        public let fileSize: Int64?
        public let loading: Bool?
        public let isGif: Bool?
        public let isSticker: Bool?
        public let isVoiceNote: Bool?
        public let playStatus: String?
        public let srcURL: String?
        public let data: Any?
        public let extra: Any?

    }
}
