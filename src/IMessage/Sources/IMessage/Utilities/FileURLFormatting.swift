import Foundation

func fileURLString(_ filePath: String) -> String {
    let fileURL = URL(fileURLWithPath: filePath).absoluteString
    // Match the legacy JS mapper's file URL escaping for filenames containing "~".
    return fileURL.replacingOccurrences(of: "~", with: "%7E")
}

func waitForFileToExist(_ filePath: String, maxWait: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(maxWait)
    while !FileManager.default.fileExists(atPath: filePath) {
        guard Date() <= deadline else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return true
}

func replaceTilde(_ string: String) -> String {
    (string as NSString).expandingTildeInPath
}
