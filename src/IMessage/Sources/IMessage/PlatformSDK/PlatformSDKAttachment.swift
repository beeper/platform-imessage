import Foundation
import IMessageCore

extension PlatformSDK {
    public enum AttachmentType: String {
        case unknown
        case img
        case video
        case audio
    }

    public struct Size: JSONObjectConvertible, Sendable {
        public let width: Double
        public let height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }

        public var jsonObject: JSONObject {
            [
                "width": width,
                "height": height,
            ]
        }
    }

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

        public init(
            id: AttachmentID,
            type: AttachmentType,
            size: Size? = nil,
            posterImg: String? = nil,
            mimeType: String? = nil,
            fileName: String? = nil,
            fileSize: Int64? = nil,
            loading: Bool? = nil,
            isGif: Bool? = nil,
            isSticker: Bool? = nil,
            isVoiceNote: Bool? = nil,
            playStatus: String? = nil,
            srcURL: String? = nil,
            data: Any? = nil,
            extra: Any? = nil
        ) {
            self.id = id
            self.type = type
            self.size = size
            self.posterImg = posterImg
            self.mimeType = mimeType
            self.fileName = fileName
            self.fileSize = fileSize
            self.loading = loading
            self.isGif = isGif
            self.isSticker = isSticker
            self.isVoiceNote = isVoiceNote
            self.playStatus = playStatus
            self.srcURL = srcURL
            self.data = data
            self.extra = extra
        }

        public var jsonObject: JSONObject {
            compactDictionary([
                "id": id,
                "type": type.rawValue,
                "size": size?.jsonObject,
                "posterImg": posterImg,
                "mimeType": mimeType,
                "fileName": fileName,
                "fileSize": fileSize,
                "loading": loading,
                "isGif": isGif,
                "isSticker": isSticker,
                "isVoiceNote": isVoiceNote,
                "playStatus": playStatus,
                "srcURL": srcURL,
                "data": data,
                "extra": extra,
            ])
        }
    }
}
