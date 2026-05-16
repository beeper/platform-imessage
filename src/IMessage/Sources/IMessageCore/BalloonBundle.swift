public enum BalloonBundleKind: String, Sendable {
    case url = "com.apple.messages.URLBalloonProvider"
    case digitalTouch = "com.apple.DigitalTouchBalloonProvider"
    case handwriting = "com.apple.Handwriting.HandwritingProvider"
    case businessExtension = "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.icloud.apps.messages.business.extension"
    case applePay = "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.PassbookUIService.PeerPaymentMessagesExtension"
    case findMy = "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.findmy.FindMyMessagesApp"
    case gamePigeon = "com.apple.messages.MSMessageExtensionBalloonPlugin:EWFNLB79LQ:com.gamerdelights.gamepigeon.ext"
    case polls = "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.messages.Polls"
    case youtube = "com.apple.messages.MSMessageExtensionBalloonPlugin:EQHXZ8M8AV:com.google.ios.youtube.MessagesExtension"

    public init?(_ bundleID: String?) {
        guard let bundleID else {
            self = .url
            return
        }
        self.init(rawValue: bundleID)
    }
}
