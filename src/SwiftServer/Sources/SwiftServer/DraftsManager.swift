import AppKit

// extension FileManager {
//     func directoryExists(atPath: URL) -> Bool {
//         var isDirectory: ObjCBool = false
//         let exists = fileExists(atPath: atPath.path, isDirectory: &isDirectory)
//         return exists && isDirectory.boolValue
//     }
// }

enum DraftsManager {
    static let draftsDir = messagesDir?
        .appendingPathComponent("Drafts", isDirectory: true)

    static let objReplacementChar = "\u{fffc}"

    static let CKCompositionFileURL = NSAttributedString.Key(rawValue: "CKCompositionFileURL")

    static func saveDraft(address: String, filePath: String) throws {
        let draftsDir = try draftsDir.orThrow(ErrorMessage("draftsDir nil"))

        let ogFileURL = URL(fileURLWithPath: filePath)
        let addressDir = draftsDir.appendingPathComponent(address, isDirectory: true)
        let uniqueAttachmentDir = addressDir
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = uniqueAttachmentDir.appendingPathComponent(ogFileURL.lastPathComponent)

        try FileManager.default.createDirectory(at: uniqueAttachmentDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ogFileURL, to: fileURL)

        let attrs = [CKCompositionFileURL: fileURL]
        let rootObj = NSAttributedString(string: objReplacementChar, attributes: attrs)
        let data = try NSKeyedArchiver.archivedData(withRootObject: rootObj, requiringSecureCoding: false)
        let compositionDict = ["text": data]

        try (compositionDict as NSDictionary).write(to: addressDir.appendingPathComponent("composition.plist"))
    }

    // static var pendingDraftExists: Bool {
    //     get throws {
    //         let draftsDir = try draftsDir.orThrow(ErrorMessage("draftsDir not found"))

    //         let pendingDir = draftsDir.appendingPathComponent("Pending", isDirectory: true)
    //         return FileManager.default.directoryExists(atPath: pendingDir)
    //     }
    // }
}
