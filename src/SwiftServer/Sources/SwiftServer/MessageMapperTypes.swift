import Foundation

let objectReplacementCharacter = "\u{fffc}"
let imessageExtensionCharacter = "\u{fffd}"
let assocMsgGUIDPrefix = #"^(?:p:([-\d]+)/|bp:)"#
let uuidStart = 11
let uuidLength = 36
let coreFoundationReferenceDateMilliseconds: Int64 = 978_307_200_000

enum MessagePart {
    case text(index: Int, end: Int, text: String, attributes: [String: Any]?)
    case attachment(index: Int, end: Int, attachmentID: String)
    case unsent(index: Int, end: Int)

    var index: Int {
        switch self {
        case let .text(index, _, _, _), let .attachment(index, _, _), let .unsent(index, _):
            return index
        }
    }

    var end: Int {
        switch self {
        case let .text(_, end, _, _), let .attachment(_, end, _), let .unsent(_, end):
            return end
        }
    }

    var isText: Bool {
        if case .text = self {
            return true
        }
        return false
    }
}

enum BalloonBundleID {
    static let url = "com.apple.messages.URLBalloonProvider"
    static let digitalTouch = "com.apple.DigitalTouchBalloonProvider"
    static let handwriting = "com.apple.Handwriting.HandwritingProvider"
    static let businessExtension = "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.icloud.apps.messages.business.extension"
    static let applePay = "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.PassbookUIService.PeerPaymentMessagesExtension"
    static let youtube = "com.apple.messages.MSMessageExtensionBalloonPlugin:EQHXZ8M8AV:com.google.ios.youtube.MessagesExtension"
}

enum IMFileTransferState {
    static let finished = 5
}

let ImageExts: Set<String> = [
    "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp",
]

let AudioExts: Set<String> = [
    "mp3", "m4a", "mp4", "aac", "wav", "aiff", "caf", "amr", "ogg", "oga", "webm",
]

let VideoExts: Set<String> = [
    "mov", "mp4", "m4v", "avi", "webm", "ogg", "ogv", "3gp", "3g2",
]

let AssociatedMessageTypes: [Int: String] = [
    3: "heading",
    1000: "sticker",
    2000: "reacted_heart",
    2001: "reacted_like",
    2002: "reacted_dislike",
    2003: "reacted_laugh",
    2004: "reacted_emphasize",
    2005: "reacted_question",
    2006: "reacted_emoji",
    2007: "reacted_sticker",
    3000: "unreacted_heart",
    3001: "unreacted_like",
    3002: "unreacted_dislike",
    3003: "unreacted_laugh",
    3004: "unreacted_emphasize",
    3005: "unreacted_question",
    3006: "unreacted_emoji",
    3007: "unreacted_sticker",
]

let ReactionVerbMap = [
    "reacted_heart": "loved",
    "reacted_like": "liked",
    "reacted_dislike": "disliked",
    "reacted_laugh": "laughed at",
    "reacted_emphasize": "emphasized",
    "reacted_question": "questioned",
    "reacted_emoji": "reacted to",
    "reacted_sticker": "reacted with a sticker to",
    "unreacted_heart": "removed a heart from",
    "unreacted_like": "removed a like from",
    "unreacted_dislike": "removed a dislike from",
    "unreacted_laugh": "removed a laugh from",
    "unreacted_emphasize": "removed an exclamation from",
    "unreacted_question": "removed a question mark from",
    "unreacted_emoji": "unreacted from",
    "unreacted_sticker": "removed a sticker from",
]

let SupportedReactionKeys: Set<String> = ["heart", "like", "dislike", "laugh", "emphasize", "question"]

let ExpressiveMessages = [
    "com.apple.messages.effect.CKEchoEffect": "Echo screen",
    "com.apple.messages.effect.CKSpotlightEffect": "Spotlight screen",
    "com.apple.messages.effect.CKHappyBirthdayEffect": "Balloons screen",
    "com.apple.messages.effect.CKConfettiEffect": "Confetti screen",
    "com.apple.messages.effect.CKHeartEffect": "Love screen",
    "com.apple.messages.effect.CKLasersEffect": "Lasers screen",
    "com.apple.messages.effect.CKFireworksEffect": "Fireworks screen",
    "com.apple.messages.effect.CKShootingStarEffect": "Shooting Star screen",
    "com.apple.messages.effect.CKSparklesEffect": "Celebration screen",
    "com.apple.MobileSMS.expressivesend.impact": "Slam text",
    "com.apple.MobileSMS.expressivesend.loud": "Loud text",
    "com.apple.MobileSMS.expressivesend.gentle": "Gentle text",
    "com.apple.MobileSMS.expressivesend.invisibleink": "Invisible Ink text",
]

let ServiceFooters = [
    "iMessageLite": "iMessage · Satellite",
    "SatelliteSMS": "SMS · Satellite",
]

let receiverNameConstant = "$(kIMTranscriptPluginBreadcrumbTextReceiverIdentifier)"
let senderNameConstant = "$(kIMTranscriptPluginBreadcrumbTextSenderIdentifier)"
