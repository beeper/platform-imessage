import AppKit
import SwiftServerFoundation

// extension FileManager {
//     func directoryExists(atPath: URL) -> Bool {
//         var isDirectory: ObjCBool = false
//         let exists = fileExists(atPath: atPath.path, isDirectory: &isDirectory)
//         return exists && isDirectory.boolValue
//     }
// }

enum DraftsManager {
    static let draftsDirectory = messagesDir?
        .appendingPathComponent("Drafts", isDirectory: true)

    static let objReplacementChar = "\u{fffc}"

    static let CKCompositionFileURL = NSAttributedString.Key(rawValue: "CKCompositionFileURL")

    static func saveDraft(address: String, filePath: String) throws {
        let draftsDirectory: URL = try draftsDirectory.orThrow(ErrorMessage("draftsDirectory nil"))

        let ogFileURL: URL = URL(fileURLWithPath: filePath)
        let addressDirectory: URL = draftsDirectory.appendingPathComponent(address, isDirectory: true)
        let uniqueAttachmentDirectory: URL = addressDirectory
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        
        let fileURL: URL = uniqueAttachmentDirectory.appendingPathComponent(ogFileURL.lastPathComponent)

        try FileManager.default.createDirectory(at: uniqueAttachmentDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ogFileURL, to: fileURL)

        let attributes: [NSAttributedString.Key: Any] = [CKCompositionFileURL: fileURL]
        let rootObject: Any = NSAttributedString(string: objReplacementChar, attributes: attributes)
        let data: Data = try NSKeyedArchiver.archivedData(withRootObject: rootObject, requiringSecureCoding: false)
        let compositionDict: [String: Data] = ["text": data]

        try (compositionDict as NSDictionary).write(to: addressDirectory.appendingPathComponent("composition.plist"))
    }

    // static var pendingDraftExists: Bool {
    //     get throws {
    //         let draftsDirectory = try draftsDirectory.orThrow(ErrorMessage("draftsDirectory not found"))

    //         let pendingDir = draftsDirectory.appendingPathComponent("Pending", isDirectory: true)
    //         return FileManager.default.directoryExists(atPath: pendingDir)
    //     }
    // }
}
