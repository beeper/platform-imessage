import Foundation

enum MessagesPaths {
    static let messagesDirectory = try? FileManager.default.url(
        for: .libraryDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
    )
    .appendingPathComponent("Messages", isDirectory: true)

    static let draftsDirectory = messagesDirectory?
        .appendingPathComponent("Drafts", isDirectory: true)

    static let temporaryDirectory = URL(
        fileURLWithPath: NSTemporaryDirectory(),
        isDirectory: true
    )

    static let temporaryMobileSMSDirectory = temporaryDirectory
        .appendingPathComponent(messagesBundleID, isDirectory: true)

    static var temporaryMobileSMSPath: String {
        temporaryMobileSMSDirectory.path
    }

    static let temporaryPlatformAttachmentDirectory = temporaryDirectory
        .appendingPathComponent("platform-imessage", isDirectory: true)
}
