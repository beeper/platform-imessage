import AppKit

extension NSPasteboard {
    func backup() -> [NSPasteboardItem]? {
        guard let items = self.pasteboardItems else { return nil }
        return items.map { item in
            let itemCopy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemCopy.setData(data, forType: type)
                }
            }
            return itemCopy
        }
    }

    func withRestoration(perform: () async throws -> Void) async rethrows {
        let backup = self.backup()
        func restore() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) {
                    self.prepareForNewContents()
                    if let backup { self.writeObjects(backup) }
                    continuation.resume()
                }
            }
        }
        self.prepareForNewContents(with: .currentHostOnly) // currentHostOnly disables universal clipboard
        do {
            try await perform()
        } catch {
            await restore()
            throw error
        }
        // Complete restoration before releasing the automation lane. Deferring
        // it lets the next attachment send back up our temporary file URL, or
        // lets this restore overwrite the next send's clipboard contents.
        await restore()
    }
}
