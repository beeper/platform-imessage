import Foundation
import PlatformSDK

let objectReplacementCharacter = "\u{fffc}"
let imessageExtensionCharacter = "\u{fffd}"
let assocMsgGUIDPrefixRegex = try! NSRegularExpression(pattern: #"^(?:p:([-\d]+)/|bp:)"#)
let uuidStart = 11
let uuidLength = 36
let coreFoundationReferenceDateMilliseconds: Int64 = 978_307_200_000

struct AssociatedMessageTarget {
    let part: String?
    let messageGUID: String

    var messageID: PlatformSDK.MessageID {
        if let part, part != "0" {
            return "\(messageGUID)_\(part)"
        }
        return messageGUID
    }
}

func parseAssociatedMessageTarget(_ associatedMessageGUID: String) -> AssociatedMessageTarget {
    let range = NSRange(associatedMessageGUID.startIndex ..< associatedMessageGUID.endIndex, in: associatedMessageGUID)
    guard let match = assocMsgGUIDPrefixRegex.firstMatch(in: associatedMessageGUID, range: range),
          let upper = Range(match.range, in: associatedMessageGUID)?.upperBound else {
        return AssociatedMessageTarget(part: nil, messageGUID: associatedMessageGUID)
    }

    let part = Range(match.range(at: 1), in: associatedMessageGUID).map { String(associatedMessageGUID[$0]) }
    let rawMessageGUID = String(associatedMessageGUID[upper...])
    let messageGUID = rawMessageGUID.hasPrefix("bp:") ? String(rawMessageGUID.dropFirst(3)) : rawMessageGUID
    return AssociatedMessageTarget(part: part, messageGUID: messageGUID)
}

enum ReactionAction {
    case reacted
    case unreacted
}

enum AssociatedReactionKey: String {
    case heart
    case like
    case dislike
    case laugh
    case emphasize
    case question
    case emoji
    case sticker
}

struct AssociatedReaction {
    let action: ReactionAction
    let key: AssociatedReactionKey

    func platformReactionKey(emoji: String?) -> String? {
        switch key {
        case .emoji:
            return emoji
        default:
            return key.rawValue
        }
    }

    var isSticker: Bool {
        key == .sticker
    }

    var verb: String {
        switch (action, key) {
        case (.reacted, .heart): return "loved"
        case (.reacted, .like): return "liked"
        case (.reacted, .dislike): return "disliked"
        case (.reacted, .laugh): return "laughed at"
        case (.reacted, .emphasize): return "emphasized"
        case (.reacted, .question): return "questioned"
        case (.reacted, .emoji): return "reacted to"
        case (.reacted, .sticker): return "reacted with a sticker to"
        case (.unreacted, .heart): return "removed a heart from"
        case (.unreacted, .like): return "removed a like from"
        case (.unreacted, .dislike): return "removed a dislike from"
        case (.unreacted, .laugh): return "removed a laugh from"
        case (.unreacted, .emphasize): return "removed an exclamation from"
        case (.unreacted, .question): return "removed a question mark from"
        case (.unreacted, .emoji): return "unreacted from"
        case (.unreacted, .sticker): return "removed a sticker from"
        }
    }
}

enum AssociatedMessageType {
    case extensionUpdate
    case heading
    case pollVote
    case sticker
    case reaction(AssociatedReaction)
}

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

let gamePigeonDisplayName = "GamePigeon"

func gamePigeonHeading(for game: String?) -> String {
    guard let game else {
        return gamePigeonDisplayName
    }
    let trimmed = game.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return gamePigeonDisplayName
    }
    return "\(gamePigeonDisplayName): \(trimmed)"
}

let unsupportedBalloonBundleNames: [String: String] = [
    "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.ActivityMessagesApp.MessagesExtension": "Activity",
    "com.apple.messages.chatbot": "Business Chat",
    "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.mobileslideshow.PhotosMessagesApp": "Photos",
    "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.gamecenter.GameCenterUIService.GameCenterMessageExtension": "Game Center",
    "com.apple.messages.MSMessageExtensionBalloonPlugin:EQHXZ8M8AV:com.google.Maps.MessagesExtension": "Google Maps",
    "com.apple.messages.MSMessageExtensionBalloonPlugin:55377VK7X2:net.kortina.labs.Venmo.iMessageExtension": "Venmo",
    "com.apple.messages.MSMessageExtensionBalloonPlugin:HV6K4MJNS7:com.rapgenius.RapGenius.LyricCardMaker": "Genius",
    "com.apple.messages.MSMessageExtensionBalloonPlugin:HLSX4DMBX6:com.miniclip.8ballpoolmult.PooliMessage": "8 Ball Pool",
    "com.apple.messages.MSMessageExtensionBalloonPlugin:22DR3P88DS:com.robotdestroy.Moon.MessagesExtension": "Moon",
    "com.apple.messages.MSMessageExtensionBalloonPlugin:29QZK2TJ24:com.discoverfinancial.mobile.messageextension": "Discover",
    "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.CredentialSharingService.ShareableCredentialsMessagesExtension": "shared password",
]

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

private func associatedReaction(_ action: ReactionAction, _ key: AssociatedReactionKey) -> AssociatedMessageType {
    .reaction(AssociatedReaction(action: action, key: key))
}

let associatedMessageTypes: [Int: AssociatedMessageType] = [
    2: .extensionUpdate,
    3: .heading,
    1000: .sticker,
    4000: .pollVote,
    2000: associatedReaction(.reacted, .heart),
    2001: associatedReaction(.reacted, .like),
    2002: associatedReaction(.reacted, .dislike),
    2003: associatedReaction(.reacted, .laugh),
    2004: associatedReaction(.reacted, .emphasize),
    2005: associatedReaction(.reacted, .question),
    2006: associatedReaction(.reacted, .emoji),
    2007: associatedReaction(.reacted, .sticker),
    3000: associatedReaction(.unreacted, .heart),
    3001: associatedReaction(.unreacted, .like),
    3002: associatedReaction(.unreacted, .dislike),
    3003: associatedReaction(.unreacted, .laugh),
    3004: associatedReaction(.unreacted, .emphasize),
    3005: associatedReaction(.unreacted, .question),
    3006: associatedReaction(.unreacted, .emoji),
    3007: associatedReaction(.unreacted, .sticker),
]

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
