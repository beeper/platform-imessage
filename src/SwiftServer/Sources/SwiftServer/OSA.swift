import OSAKit

enum OSA {
    private static func run(_ source: String, language: OSALanguage? = .init(forName: "JavaScript")) throws {
        let script = OSAScript(source: source, language: language)
        var compileError: NSDictionary?
        script.compileAndReturnError(&compileError)
        if let compileError = compileError { throw ErrorMessage(String(describing: compileError)) }
        var scriptError: NSDictionary?
        let result = script.executeAndReturnError(&scriptError)
        if let scriptError = scriptError { throw ErrorMessage(String(describing: scriptError)) }
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
