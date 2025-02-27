import OSAKit
import SwiftServerFoundation
import Logging

private let log = Logger(swiftServerLabel: "osa")

enum OSA {
    private static func run(_ source: String, language: OSALanguage? = .init(forName: "JavaScript")) throws {
        let script = OSAScript(source: source, language: language)
        var scriptError: NSDictionary?
        let _ = script.executeAndReturnError(&scriptError)
        if let scriptError { throw ErrorMessage(String(describing: scriptError)) }
    }

    static func send(threadID: String, text: String) throws {
        try run("""
        const [tid, txt] = \(try jsonStringify([threadID, text]))
        const Messages = Application('Messages')
        const to = Messages.chats.byId(tid)()
        Messages.send(txt, { to })
        """)
    }

    static func send(threadID: String, filePath: String) throws {
        try run("""
        const [tid, fp] = \(try jsonStringify([threadID, filePath]))
        const Messages = Application('Messages')
        const to = Messages.chats.byId(tid)()
        Messages.send(Path(fp), { to })
        """)
    }

    static func promptAutomationAccess() throws {
        try run("""
        tell application "Messages" to set a to accounts
        """, language: .init(forName: "AppleScript"))
    }
}
