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

    // TODO: replace with Task and figure out if the delay is really needed
    func withRestoration(perform: () async throws -> Void) async rethrows {
        let backup = self.backup()
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) {
                self.prepareForNewContents()
                if let backup { self.writeObjects(backup) }
            }
        }
        self.prepareForNewContents(with: .currentHostOnly) // currentHostOnly disables universal clipboard
        try await perform()
    }
}
