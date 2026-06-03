import AccessibilityControl
import AppKit
import IMessageCore
import Logging

private let messagesApplicationWindowLog = Logger(imessageLabel: "messages-window")

extension MessagesApplication {
    struct ElementLookupError: Error, CustomStringConvertible {
        let name: String
        let underlyingErrors: [Error]
        let dumpID: String?

        var description: String {
            var desc = "\(name) not found"
            if !underlyingErrors.isEmpty {
                desc += " - underlying: " + underlyingErrors.map(String.init(describing:)).joined(separator: "; ")
            }
            if let dumpID {
                desc += " (AX dump ID: \(dumpID))"
            }
            return desc
        }
    }
}

extension MessagesApplication.Window {
    static func isMessageContainerCell(_ element: Accessibility.Element) throws -> Bool {
        let hasDescription = try !element.localizedDescription().isEmpty
        guard hasDescription else { return false }

        return try element.children[0].supportedActions().contains {
            $0.name.value.hasPrefix("Name:\(LocalizedStrings.react)")
        }
    }

    static func messageContainerCells(in transcriptView: Accessibility.Element) throws -> [Accessibility.Element] {
        try transcriptView.children().filter { (try? isMessageContainerCell($0)) ?? false }
    }

    static func firstMessageCell(in transcriptView: Accessibility.Element) throws -> Accessibility.Element? {
        try transcriptView.children().first { (try? isMessageContainerCell($0)) ?? false }?.children[0]
    }

    static func firstSelectedMessageCell(in transcriptView: Accessibility.Element) throws -> Accessibility.Element? {
        try transcriptView.children().first { (try? $0.children[0].isSelected()) == true }?.children[0]
    }

    static func threadActivityCells(in transcriptView: Accessibility.Element) throws -> [Accessibility.Element] {
        let count = try transcriptView.children.count()
        guard count > 0 else { return [] }

        let lastN = isSequoiaOrUp ? 10 : (isMontereyOrUp ? 3 : 1)
        return try transcriptView.children(range: (count - min(count, lastN))..<count)
    }

    func find(
        _ name: String,
        logTime: Bool = false,
        dumpOnError: Bool = false,
        in root: Accessibility.Element? = nil,
        _ search: () throws -> Accessibility.Element?
    ) throws -> Accessibility.Element {
        let startTime = logTime ? Date() : nil
        defer {
            if let startTime {
                messagesApplicationWindowLog.debug("\(name) took \(startTime.elapsedMilliseconds)ms")
            }
        }

        var errors: [Error] = []
        do {
            if let result = try search() {
                return result
            }
        } catch {
            errors.append(error)
        }

        var dumpID: String?
        if dumpOnError {
            let id = String(UUID().uuidString.prefix(8)).lowercased()
            dumpID = id
            do {
                var buffer = ""
                try (root ?? element).dumpXML(to: &buffer, maxDepth: 10, excludingPII: true, includeActions: false, includeSections: true)
                messagesApplicationWindowLog.error("[\(id)] AX dump for \(name):\n\(buffer)")
            } catch {
                messagesApplicationWindowLog.error("[\(id)] failed to dump AX tree for \(name): \(error)")
                errors.append(error)
            }
        }

        throw MessagesApplication.ElementLookupError(name: name, underlyingErrors: errors, dumpID: dumpID)
    }

    func sectionObjects() throws -> [Accessibility.Element] {
        try application.sectionObjects(in: element)
    }

    func conversationList() throws -> Accessibility.Element {
        try retry(withTimeout: 1, interval: 0.1) {
            try application.conversationList(in: element, useFastPath: true)
                .orThrow(ErrorMessage("ConversationList not found"))
        } onError: { _, _ in
            let searchField = try self.searchField()
            messagesApplicationWindowLog.error("fetching ConversationList errored, calling searchField.cancel")
            try searchField.cancel()
        }
    }

    func selectedThreadCell() throws -> Accessibility.Element? {
        try conversationList().selectedChildren[0]
    }

    func transcriptView(replyTranscript: Bool) throws -> Accessibility.Element {
        let startTime = Date()
        defer {
            messagesApplicationWindowLog.debug("transcriptView(replyTranscript: \(replyTranscript)) took \(startTime.elapsedMilliseconds)ms")
        }

        func isReplyTranscriptView(_ element: Accessibility.Element) -> Bool {
            (try? element.localizedDescription()) == LocalizedStrings.replyTranscript
        }

        let predicate = { (element: Accessibility.Element) -> Bool in
            (try? element.identifier()) == "TranscriptCollectionView" && isReplyTranscriptView(element) == replyTranscript
        }

        if let transcriptView = try? sectionObjects().first(where: predicate) {
            return transcriptView
        }
        if let transcriptView = element.recursiveChildren().lazy.first(where: predicate) {
            return transcriptView
        }
        throw ErrorMessage("TranscriptCollectionView(replyTranscript: \(replyTranscript)) not found")
    }

    func transcriptView() throws -> Accessibility.Element {
        try transcriptView(replyTranscript: false)
    }

    func replyTranscriptView() throws -> Accessibility.Element {
        try transcriptView(replyTranscript: true)
    }

    func messageBodyField() throws -> Accessibility.Element {
        let startTime = Date()
        defer { messagesApplicationWindowLog.debug("messageBodyField took \(startTime.elapsedMilliseconds)ms") }
        var alternate = false
        return try retry(withTimeout: 1.5, interval: 0.1) {
            if alternate {
                return try element.recursivelyFindChild(withID: "messageBodyField")
                    .orThrow(ErrorMessage("messageBodyField not found"))
            }

            return try sectionObjects()
                .first { (try? $0.identifier()) == "messageBodyField" }
                .orThrow(ErrorMessage("messageBodyField not found"))
        } onError: { attempt, _ in
            alternate = attempt % 2 == 0
        }
    }

    func searchField() throws -> Accessibility.Element {
        let startTime = Date()
        defer { messagesApplicationWindowLog.debug("searchField took \(startTime.elapsedMilliseconds)ms") }
        return try retry(withTimeout: 1, interval: 0.1) {
            let conversationListView = try application.ckConversationListCollectionView(in: element)
                .orThrow(ErrorMessage("CKConversationListCollectionView not found"))
            return try conversationListView.children()
                .first { (try? $0.subrole()) == Accessibility.Subrole.searchField }
                .orThrow(ErrorMessage("searchField not found"))
        }
    }

    func iOSContentGroup() throws -> Accessibility.Element {
        try find("iOSContentGroup") {
            try element.children()
                .first(where: { (try? $0.subrole()) == "iOSContentGroup" && (try? $0.role()) == NSAccessibility.Role.group.rawValue })
        }
    }

    func iOSContentGroupFirstChild() throws -> Accessibility.Element {
        try find("iOSContentGroupFirstChild", logTime: true) {
            try iOSContentGroup().children[0]
        }
    }

    func addCustomEmojiReactionButton() throws -> Accessibility.Element {
        let element = try (try? iOSContentGroupFirstChild())?.children().first {
            (try? $0.identifier()) == nil && (try? $0.role()) == "AXButton"
        }
        return try element.orThrow(ErrorMessage("couldn't find button to add custom emoji reaction"))
    }

    func characterPickerPopover() throws -> Accessibility.Element {
        try find("characterPickerPopover") {
            if let attachedPopover = element.recursiveChildren().lazy.first(where: CharacterPickerPopover.isPopover) {
                return attachedPopover
            }

            return try CharacterPickerPopover(app: application.accessibilityElement, ownerPID: processIdentifier).detachedPopover()
        }
    }

    func characterPickerSearchField() throws -> Accessibility.Element {
        try find("characterPickerSearchField") {
            try CharacterPickerPopover(app: application.accessibilityElement, ownerPID: processIdentifier)
                .searchField(in: characterPickerPopover())
        }
    }

    func splitter() throws -> Accessibility.Element {
        try find("splitter", logTime: true) {
            try iOSContentGroupFirstChild().children()
                .first(where: { (try? $0.role()) == Accessibility.Role.splitter })
        }
    }

    func reactionsView() throws -> Accessibility.Element {
        let startTime = Date()
        defer { messagesApplicationWindowLog.debug("reactionsView took \(startTime.elapsedMilliseconds)ms") }
        return try retry(withTimeout: 1.5, interval: 0.1) {
            let view = try iOSContentGroupFirstChild()
            guard (try? view.children.count()) ?? 0 > 0 else {
                throw ErrorMessage("reactionsView not found")
            }
            return view
        }
    }

    func reactButtons() throws -> [Accessibility.Element] {
        let startTime = Date()
        defer { messagesApplicationWindowLog.debug("reactButtons took \(startTime.elapsedMilliseconds)ms") }
        guard let buttons = try? reactionsView().children().filter({ (try? $0.role()) == Accessibility.Role.button }) else {
            throw ErrorMessage("reactButtons not found")
        }
        return buttons
    }

    func tapbackPickerCollectionView() throws -> Accessibility.Element {
        let startTime = Date()
        defer { messagesApplicationWindowLog.debug("tapbackPickerCollectionView took \(startTime.elapsedMilliseconds)ms") }
        guard let element = try? reactionsView().children().first(where: { (try? $0.identifier()) == "TapbackPickerCollectionView" }) else {
            throw ErrorMessage("tapbackPickerCollectionView not found")
        }
        return element
    }

    func alertSheet() throws -> Accessibility.Element {
        try find("alertSheet") {
            try element.children().first(where: { try $0.role() == Accessibility.Role.sheet })
        }
    }

    func alertSheetDeleteButton() throws -> Accessibility.Element {
        try find("alertSheetDeleteButton") {
            try alertSheet().children().first(where: { try $0.role() == Accessibility.Role.button })
        }
    }

    func notifyAnywayButton() throws -> Accessibility.Element {
        let startTime = Date()
        defer { messagesApplicationWindowLog.debug("notifyAnywayButton took \(startTime.elapsedMilliseconds)ms") }
        let cells = try Self.threadActivityCells(in: transcriptView())
        return try cells.lazy.reversed().compactMap {
            guard let child = try? $0.children[0],
                  (try? child.role()) == Accessibility.Role.button,
                  (try? child.localizedDescription()) == LocalizedStrings.notifyAnyway else {
                return nil
            }
            return child
        }.first.orThrow(ErrorMessage("notifyAnywayButton not found"))
    }

    func editableMessageField() throws -> Accessibility.Element {
        let editingConfirmButton = try iOSContentGroup().recursiveChildren().lazy.first(where: {
            (try? $0.localizedDescription()) == LocalizedStrings.editingConfirm
        }).orThrow(ErrorMessage("editingConfirmButton not found"))
        return try editingConfirmButton.parent().recursiveChildren().lazy.first(where: {
            (try? $0.role()) == Accessibility.Role.textField
        }).orThrow(ErrorMessage("editableMessageField not found"))
    }

    func menu() throws -> Accessibility.Element {
        try retry(withTimeout: 2, interval: 0.1) {
            try iOSContentGroup().children()
                .first { try $0.role() == Accessibility.Role.menu }
                .orThrow(ErrorMessage("menu not found"))
        }
    }

    func menuEditItem() throws -> Accessibility.Element {
        try retry(withTimeout: 1, interval: 0.05) {
            try menu().children()
                .first { (try? $0.identifier()) == "edit" }
                .orThrow(ErrorMessage("Couldn't find \"Edit\" menu item; messages are only editable for 15 minutes after sending"))
        }
    }

    func cancelEditButton() throws -> Accessibility.Element {
        try find("cancelEditButton") {
            try iOSContentGroupFirstChild().recursiveChildren()
                .first(where: {
                    (try? $0.localizedDescription()) == LocalizedStrings.editingReject
                })
        }
    }

    func toFieldPopupButton() throws -> Accessibility.Element {
        try find("toFieldPopupButton") {
            try iOSContentGroup().children[0].children()
                .first { try $0.role() == Accessibility.Role.popUpButton }
        }
    }
}
