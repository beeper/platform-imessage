import Foundation

let linkPreviewPayloadAssetKind = "lp"
private let linkPreviewPayloadDownloadWait: TimeInterval = 10

func linkPreviewPayloadAssetURL(attachmentGUID: String) -> String {
    "asset://$accountID/\(linkPreviewPayloadAssetKind)/\(attachmentGUID)"
}

extension PlatformAPI {
    func getLinkPreviewPayloadAsset(attachmentGUID: String) async throws -> AssetResult {
        guard let payload = try database.withDatabase({ db in
            try db.linkPreviewPayload(attachmentGUID: attachmentGUID)
        }) else {
            throw ErrorMessage("Couldn't find link preview payload")
        }
        let filePath = replaceTilde(payload.filename)
        if PluginPayloadAssetSupport.fileSize(URL(fileURLWithPath: filePath)) > 0 {
            return .url(fileURLString(filePath))
        }

        try await withMessagesController { controller in
            guard PluginPayloadAssetSupport.fileSize(URL(fileURLWithPath: filePath)) == 0 else {
                return
            }
            try await controller.revealMessage(threadID: payload.chatGUID, messageGUID: payload.messageGUID)
        }

        guard try await waitForFileURL(maxWait: linkPreviewPayloadDownloadWait, pollInterval: 0.1, matching: {
            PluginPayloadAssetSupport.fileSize(URL(fileURLWithPath: filePath)) > 0 ? URL(fileURLWithPath: filePath) : nil
        }) != nil else {
            throw ErrorMessage("Messages didn't download the link preview image")
        }
        return .url(fileURLString(filePath))
    }
}
