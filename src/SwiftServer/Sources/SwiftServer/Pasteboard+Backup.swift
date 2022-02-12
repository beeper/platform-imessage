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

    func withRestoration(perform: () throws -> Void) rethrows {
        let backup = self.backup()
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) {
                self.prepareForNewContents()
                if let backup = backup { self.writeObjects(backup) }
            }
        }
        self.prepareForNewContents(with: .currentHostOnly) // currentHostOnly disables universal clipboard
        try perform()
    }
}
