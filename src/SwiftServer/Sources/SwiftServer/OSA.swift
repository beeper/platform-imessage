import Foundation
import OSAKit
import SwiftServerFoundation
import Logging

private let log = Logger(swiftServerLabel: "osa")

enum OSA {
    private static let scriptExecutionLock = UnfairLock()

    private static let messagesScriptResult: Result<OSAScript, Error> = Result {
        let messagesScript = try makeCompiledScript(
            source: """
            const messagesApplication = Application('/System/Applications/Messages.app')

            function chatForThreadID(threadID) {
                const chat = messagesApplication.chats.byId(threadID)()
                if (!chat) {
                    throw new Error(`Could not find Messages chat for thread ID: ${threadID}`)
                }
                return chat
            }

            function sendText(threadID, text) {
                const chat = chatForThreadID(threadID)
                messagesApplication.send(text, { to: chat })
            }

            function sendFile(threadID, filePath) {
                const chat = chatForThreadID(threadID)
                messagesApplication.send(Path(filePath), { to: chat })
            }
            """,
            languageName: "JavaScript"
        )
        log.debug("compiled cached Messages OSA script")
        return messagesScript
    }

    private static let automationAccessPromptScriptResult: Result<OSAScript, Error> = Result {
        let automationAccessPromptScript = try makeCompiledScript(
            source: """
            on promptAutomationAccess()
                tell application "Messages" to set automationAccessPromptAccounts to accounts
            end promptAutomationAccess
            """,
            languageName: "AppleScript"
        )
        log.debug("compiled cached automation access OSA script")
        return automationAccessPromptScript
    }

    static func send(threadID: String, text: String) throws {
        try executeHandler(
            script: messagesScriptResult.get(),
            handlerName: "sendText",
            arguments: [threadID, text]
        )
    }

    static func send(threadID: String, filePath: String) throws {
        try executeHandler(
            script: messagesScriptResult.get(),
            handlerName: "sendFile",
            arguments: [threadID, filePath]
        )
    }

    static func promptAutomationAccess() throws {
        try executeHandler(
            script: automationAccessPromptScriptResult.get(),
            handlerName: "promptAutomationAccess",
            arguments: []
        )
    }

    private static func executeHandler(
        script: OSAScript,
        handlerName: String,
        arguments: [Any]
    ) throws {
        try scriptExecutionLock.withLock {
            try autoreleasepool {
                var scriptErrorInfo: NSDictionary?
                let _ = script.executeHandler(withName: handlerName, arguments: arguments, error: &scriptErrorInfo)
                if let scriptErrorInfo {
                    throw makeErrorMessage(from: scriptErrorInfo)
                }
            }
        }
    }

    private static func makeCompiledScript(source: String, languageName: String) throws -> OSAScript {
        guard let language = OSALanguage(forName: languageName) else {
            throw ErrorMessage("\(languageName) OSA language is unavailable")
        }

        let script = OSAScript(source: source, language: language)
        var scriptErrorInfo: NSDictionary?
        let didCompile = script.compileAndReturnError(&scriptErrorInfo)
        if !didCompile || scriptErrorInfo != nil {
            throw makeErrorMessage(from: scriptErrorInfo ?? NSDictionary())
        }
        return script
    }

    private static func makeErrorMessage(from scriptErrorInfo: NSDictionary) -> ErrorMessage {
        if let detailedMessage = scriptErrorInfo[OSAScriptErrorMessageKey] as? String {
            return ErrorMessage(detailedMessage)
        }
        if let briefMessage = scriptErrorInfo[OSAScriptErrorBriefMessageKey] as? String {
            return ErrorMessage(briefMessage)
        }
        return ErrorMessage(String(describing: scriptErrorInfo))
    }
}
