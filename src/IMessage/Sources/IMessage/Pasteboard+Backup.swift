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
        self.prepareForNewContents(with: .currentHostOnly) // currentHostOnly disables universal clipboard
        do {
            try await perform()
        } catch {
            await restore(backup)
            throw error
        }
        await restore(backup)
    }

    /// Restores a `backup()` snapshot. Structured (awaited by `withRestoration`)
    /// so restoration isn't silently dropped when the surrounding task is
    /// cancelled mid-automation — the old fire-and-forget `asyncAfter` was.
    private func restore(_ backup: [NSPasteboardItem]?) async {
        // Keep the brief post-perform beat the asyncAfter hop used to provide,
        // so the paste consumer sees the automation contents before we restore.
        // If the task was cancelled the sleep returns early and we restore
        // immediately — no paste is in flight to protect at that point.
        try? await Task.sleep(forTimeInterval: 0.001)
        self.prepareForNewContents()
        if let backup { self.writeObjects(backup) }
    }
}
