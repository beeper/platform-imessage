import Foundation

private let defaultFilePollInterval: TimeInterval = 0.02

func fileURLString(_ filePath: String) -> String {
    let fileURL = URL(fileURLWithPath: filePath).absoluteString
    // Match the legacy JS mapper's file URL escaping for filenames containing "~".
    return fileURL.replacingOccurrences(of: "~", with: "%7E")
}

func waitForFileToExist(_ filePath: String, maxWait: TimeInterval) async throws -> Bool {
    try await waitForFileURL(maxWait: maxWait) {
        FileManager.default.fileExists(atPath: filePath)
            ? URL(fileURLWithPath: filePath)
            : nil
    } != nil
}

func waitForFileURL(
    maxWait: TimeInterval,
    pollInterval: TimeInterval = defaultFilePollInterval,
    matching existingURL: () throws -> URL?
) async throws -> URL? {
    let deadline = Date().addingTimeInterval(maxWait)
    while true {
        if let url = try existingURL() {
            return url
        }
        guard Date() <= deadline else {
            return nil
        }
        try await Task.sleep(forTimeInterval: pollInterval)
    }
}

func replaceTilde(_ string: String) -> String {
    (string as NSString).expandingTildeInPath
}
