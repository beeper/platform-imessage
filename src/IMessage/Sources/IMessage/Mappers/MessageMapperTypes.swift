import Foundation

public typealias JSONObject = [String: Any]
public typealias JSONArray = [Any]

let objectReplacementCharacter = "\u{fffc}"
let imessageExtensionCharacter = "\u{fffd}"
let assocMsgGUIDPrefixRegex = try! NSRegularExpression(pattern: #"^(?:p:([-\d]+)/|bp:)"#)
let uuidStart = 11
let uuidLength = 36
let coreFoundationReferenceDateMilliseconds: Int64 = 978_307_200_000

enum MessagePart {
    case text(index: Int, end: Int, text: String, attributes: PlatformSDK.TextAttributes?)
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

let imageExtensions: Set<String> = [
    "3dv", "ai", "amf", "art", "ase", "awg", "blp", "bmp", "bw", "cd5", "cdr", "cgm", "cit", "cmx", "cpt",
    "cr2", "cur", "cut", "dds", "dib", "djvu", "dxf", "e2d", "ecw", "egt", "emf", "eps", "exif", "fs",
    "gbr", "gif", "gpl", "grf", "hdp", "heic", "heics", "ico", "icns", "iff", "int", "inta", "jfif",
    "jng", "jp2", "jpeg", "jpg", "jps", "jxr", "lbm", "liff", "max", "miff", "mng", "msp", "nitf",
    "nrrd", "odg", "ota", "pam", "pbm", "pc1", "pc2", "pc3", "pcf", "pct", "pcx", "pdd", "pdn",
    "pgf", "pgm", "PI1", "PI2", "PI3", "pict", "png", "pnm", "pns", "ppm", "psp", "px", "pxm", "pxr",
    "qfx", "ras", "raw", "rgb", "rgba", "rle", "sct", "sgi", "sid", "sun", "svg", "sxd", "tga", "tgs",
    "tif", "tiff", "v2d", "vnd", "vrml", "vtf", "wdp", "webp", "wmf", "x3d", "xar", "xbm", "xcf", "xpm",
]

let audioExtensions: Set<String> = [
    "3gp", "aac", "act", "aiff", "amr", "ast", "au", "bwf", "caf", "dct", "dss", "flac", "gsm", "m4a",
    "m4p", "mmf", "mp2", "mp3", "mp4", "mpc", "oga", "ogg", "opus", "pac", "ra", "raw", "s3m", "sln",
    "tta", "vox", "wav", "wv",
]

let videoExtensions: Set<String> = [
    "3g2", "3gp", "aaf", "asf", "avchd", "avi", "drc", "flv", "m2v", "m4p", "m4v", "mkv", "mng", "mov",
    "mp2", "mp4", "mpe", "mpeg", "mpg", "mpv", "mxf", "nsv", "ogg", "ogv", "qt", "rm", "rmvb", "roq",
    "svi", "vob", "webm", "wmv", "yuv",
]

let associatedMessageTypes: [Int: String] = [
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

let reactionVerbMap = [
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

let supportedReactionKeys: Set<String> = ["heart", "like", "dislike", "laugh", "emphasize", "question"]

let expressiveMessages = [
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

let serviceFooters = [
    "iMessageLite": "iMessage · Satellite",
    "SatelliteSMS": "SMS · Satellite",
]

let receiverNamePlaceholder = "$(kIMTranscriptPluginBreadcrumbTextReceiverIdentifier)"
let senderNamePlaceholder = "$(kIMTranscriptPluginBreadcrumbTextSenderIdentifier)"
