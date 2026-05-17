import AppKit
import ArgumentParser
import Darwin
import Foundation
import IMessage
import IMessageCore
import PlatformSDK

private let accountID = "default"
private let prompt = "imessage> "
private let commandCategories: [Category] = [.general, .watching, .message, .chat]
private let quitCommands: Set<String> = ["q", "quit", "exit"]

@main
struct IMessageCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imessage-cli",
        abstract: "Send, read, and manage local iMessage chats from the command line.",
        discussion: """
        Run without a command, or with `shell`, to open the interactive shell.
        Run `version` to print the embedded package version.
        Run `help` for the command list or `help COMMAND` for command help.
        """
    )

    @Option(name: .long, help: "Store CLI state under PATH instead of a temp directory.")
    var dataDir: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Use a secondary Messages.app instance.")
    var useSecondaryInstance = true

    @Flag(name: .long, help: "Run one command, then stay open in the interactive shell.")
    var stayOpen = false

    @Flag(name: .long, help: "Do not subscribe to new DB changes after running commands.")
    var noEvents = false

    @Flag(name: .long, help: "Enable verbose logging.")
    var verbose = false

    @Argument(parsing: .allUnrecognized, help: "Command and command arguments.")
    var commandArgs: [String] = []

    mutating func run() async throws {
        let options = RunnerOptions(
            commandArgs: commandArgs,
            customDataDir: dataDir,
            keepAlive: stayOpen,
            loggingEnabled: verbose,
            subscribeToEvents: !noEvents,
            useSecondaryInstance: IMessageHost.useSecondaryInstanceEnvironment ?? useSecondaryInstance
        )
        if !options.keepAlive, try runBootstrapFreeCommandIfNeeded(options.commandArgs) {
            return
        }
        try await Runner(options: options).run()
    }
}

private enum Category: String {
    case general = "General"
    case watching = "Watching"
    case message = "Message"
    case chat = "Chat"
}

private enum AuthorizationRequirement: String {
    case accessibility
    case contacts
    case messagesData = "messages-data"

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .contacts: return "Contacts"
        case .messagesData: return "Messages Data"
        }
    }

    func currentStatus() async -> (authorized: Bool, detail: String) {
        switch self {
        case .accessibility:
            let ok = MacPermissions.getAuthStatus(.accessibility) == .authorized
            return (ok, ok ? "Your current Terminal app can control Messages.app." : "Enable your current Terminal app in System Settings > Privacy & Security > Accessibility.")
        case .contacts:
            let ok = MacPermissions.getAuthStatus(.contacts) == .authorized
            return (ok, ok ? "Contacts lookups are available." : "Allow Contacts access if you want contact-name lookups from the CLI.")
        case .messagesData:
            let ok = await canAccessMessagesDir()
            return (ok, ok ? "The CLI can read your local Messages data." : "The CLI cannot read ~/Library/Messages yet.")
        }
    }

    func request() async throws {
        switch self {
        case .accessibility:
            MacPermissions.askForAccessibilityAccess()
            SystemSettingsOnboarding.start()
            defer { SystemSettingsOnboarding.stop() }
            _ = await pollAuthorization(timeout: 120) {
                MacPermissions.getAuthStatus(.accessibility) == .authorized
            }
        case .contacts:
            _ = try? await MacPermissions.askForContactsAccess()
        case .messagesData:
            try? await MacPermissions.askForMessagesDirAccess()
            if !(await canAccessMessagesDir()) {
                print("  note: Opening Full Disk Access as a fallback.")
                MacPermissions.askForFullDiskAccess()
            }
        }
    }
}

private struct RunnerOptions {
    var commandArgs: [String]
    var customDataDir: String?
    var keepAlive: Bool
    var loggingEnabled: Bool
    var subscribeToEvents: Bool
    var useSecondaryInstance: Bool
}

private struct RunnerState {
    var options: RunnerOptions
    var dataDirPath: String
    var sessionFilePath: String
}

private struct CommandDefinition {
    var name: String
    var category: Category
    var summary: String
    var usage: [String]
    var examples: [String]
    var notes: [String] = []
    var requiredAuthorization: [AuthorizationRequirement] = []
    var execute: ([String], InvokeContext) async throws -> Void
}

private final class InvokeContext {
    let command: CommandDefinition
    private let runner: Runner

    init(command: CommandDefinition, runner: Runner) {
        self.command = command
        self.runner = runner
    }

    func invoke(
        args: [Any],
        _ operation: @escaping (PlatformAPI) async throws -> String?
    ) async throws {
        try await runner.invoke(
            commandName: command.name,
            args: args,
            operation
        )
    }

    func showHelp(_ commandName: String?) throws {
        try runner.showHelp(commandName)
    }

    func showState() {
        runner.showState()
    }

    func startEventWatching(api: PlatformAPI) async throws {
        try await runner.startEventWatching(api: api)
    }

    func printEventJSON(_ json: String) {
        runner.printEventJSON(json)
    }

    func enrichThreadPageJSON(_ pageObject: JSONObject) -> JSONObject {
        runner.enrichThreadPageJSON(pageObject)
    }

    func enrichThreadJSON(_ threadObject: JSONObject?) -> JSONObject? {
        runner.enrichThreadJSON(threadObject)
    }
}

private final class Runner {
    private let options: RunnerOptions
    private var state: RunnerState?
    private var apiInstance: PlatformAPI?
    private lazy var contactResolver = CLIContactResolver()
    private var nextCallID = 1
    private var eventsSubscribed = false
    private var shuttingDown = false

    init(options: RunnerOptions) {
        self.options = options
    }

    func run() async throws {
        state = try ensureRunnerState(options)
        guard let state else { return }

        IMessageHost.bootstrapWithOptions(
            dataDirPath: state.dataDirPath,
            verbose: state.options.loggingEnabled,
            useSecondaryInstance: state.options.useSecondaryInstance
        )

        defer {
            if state.options.customDataDir == nil {
                try? FileManager.default.removeItem(atPath: state.dataDirPath)
            }
        }

        if !options.commandArgs.isEmpty {
            let name = options.commandArgs[0]
            let args = Array(options.commandArgs.dropFirst())
            if name != "shell" {
                try await runParsedCommand(name: name, args: args)
                if !options.keepAlive {
                    try await shutdown()
                    return
                }
            }
        }

        try await runShell()
    }

    func api() throws -> PlatformAPI {
        guard let apiInstance else {
            throw CLIError("PlatformAPI has not been initialized")
        }
        return apiInstance
    }

    @discardableResult
    func initializeAPIIfNeeded() throws -> PlatformAPI {
        if let apiInstance {
            return apiInstance
        }
        let created = try PlatformAPI(accountID: accountID)
        apiInstance = created
        return created
    }

    func invoke(
        commandName: String,
        args: [Any],
        _ operation: @escaping (PlatformAPI) async throws -> String?
    ) async throws {
        let api = try api()
        if options.subscribeToEvents {
            ensureEventSubscription(api: api)
        }

        let id = String(format: "%05d", nextCallID)
        nextCallID += 1
        print("[\(id)] call \(commandName) \(formatValue(args))")

        let started = Date()
        do {
            let result = try await operation(api)
            print("[\(id)] ok \(commandName) (\(elapsedMilliseconds(since: started))ms)")
            if let result {
                print(prettyJSONString(result))
            }
        } catch {
            fputs("[\(id)] failed \(commandName) (\(elapsedMilliseconds(since: started))ms) \(error)\n", stderr)
            throw error
        }
    }

    func showHelp(_ commandName: String?) throws {
        guard let commandName else {
            printTopLevelHelp()
            return
        }
        guard let command = resolveCommand(commandName) else {
            throw CLIError("unknown command: \"\(commandName)\"")
        }
        printCommandHelp(command)
    }

    func showState() {
        guard let state else { return }
        print(formatValue([
            "dataDirPath": state.dataDirPath,
            "sessionFilePath": state.sessionFilePath,
            "subscribeToEvents": state.options.subscribeToEvents,
            "loggingEnabled": state.options.loggingEnabled,
            "useSecondaryInstance": state.options.useSecondaryInstance,
        ]))
    }

    func enrichThreadPageJSON(_ pageObject: JSONObject) -> JSONObject {
        CLIThreadContactEnricher.enrichThreadPageJSON(
            pageObject,
            resolver: contactResolver
        )
    }

    func enrichThreadJSON(_ threadObject: JSONObject?) -> JSONObject? {
        CLIThreadContactEnricher.enrichThreadJSON(
            threadObject,
            resolver: contactResolver
        )
    }

    func ensureEventSubscription(api: PlatformAPI) {
        guard !eventsSubscribed else { return }
        eventsSubscribed = true
        api.subscribeToEvents { [weak self] events in
            let json = try encodeJSON(events.map { $0.jsonObject() })
            self?.printEventJSON(json)
        }
    }

    func startEventWatching(
        api: PlatformAPI,
        reportStartupErrors: Bool = false
    ) async throws {
        ensureEventSubscription(api: api)
        do {
            try await api.startEventWatchingFromCurrentState()
        } catch {
            if reportStartupErrors {
                fputs("event watching startup failed: \(error)\n", stderr)
            } else {
                throw error
            }
        }
    }

    func printEventJSON(_ json: String) {
        printConsoleLine("[events \(Date().iso8601Formatted)] \(prettyJSONString(json))")
    }

    private func printConsoleLine(_ line: String) {
        Log.consoleEmitter(line)
    }

    private func runShell() async throws {
        let shouldStartEventWatching = try await runShellAuthorizationFlowIfNeeded()
        printTopLevelHelp()
        let lineReader = ShellLineReader(prompt: prompt)
        Log.consoleEmitter = { [lineReader] line in
            lineReader.printConsoleLine(line)
        }
        if shouldStartEventWatching {
            let api = try initializeAPIIfNeeded()
            try await startEventWatching(api: api, reportStartupErrors: true)
        }
        while true {
            guard let input = lineReader.readLine() else {
                try await shutdown()
                return
            }
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if quitCommands.contains(trimmed) {
                try await shutdown()
                return
            }

            do {
                let tokens = try tokenizeInput(trimmed)
                guard let name = tokens.first else { continue }
                try await runParsedCommand(name: name, args: Array(tokens.dropFirst()))
            } catch {
                fputs("\(error)\n", stderr)
            }
        }
    }

    private func runShellAuthorizationFlowIfNeeded() async throws -> Bool {
        let messagesDataStatus = await AuthorizationRequirement.messagesData.currentStatus()
        guard !messagesDataStatus.authorized else { return options.subscribeToEvents }

        let missingSetup = await missingAuthorizationRequirements([.accessibility, .contacts, .messagesData])
        let authTarget = missingSetup.count > 1 ? "all" : AuthorizationRequirement.messagesData.rawValue
        print("imessage-cli requires certain permissions to function. Launching authorization flow...")
        try await runAuthorizationFlow(target: authTarget)

        let updated = await AuthorizationRequirement.messagesData.currentStatus()
        guard updated.authorized else {
            fputs("event watching startup skipped: Messages Data was not granted. \(updated.detail)\n", stderr)
            return false
        }
        return options.subscribeToEvents
    }

    private func runParsedCommand(name: String, args: [String]) async throws {
        guard let command = resolveCommand(name) else {
            throw CLIError("unknown command: \"\(name)\"")
        }
        if args.contains("--help") || args.contains("-h") {
            printCommandHelp(command)
            return
        }

        let context = InvokeContext(command: command, runner: self)
        if !command.requiredAuthorization.isEmpty {
            try await runPreflightAuthCheck(commandName: command.name, requirements: command.requiredAuthorization)
            try initializeAPIIfNeeded()
        }
        try await command.execute(args, context)
    }

    private func shutdown() async throws {
        guard !shuttingDown else { return }
        shuttingDown = true
        if let apiInstance {
            try await apiInstance.dispose()
        }
        print("Exiting...")
    }
}

private let readOnlyAuth: [AuthorizationRequirement] = [.messagesData]
private let mutatingAuth: [AuthorizationRequirement] = [.messagesData, .accessibility]
private let latestMessageIDAliases = ["last-message", "lastMessage", "latestMessage", "latest"]
private let maxLatestMessageOffset = 999_999
private let messageIDAliasNote = "MESSAGE_ID may be \(latestMessageIDAliases.joined(separator: ", ")), or latest-N (N up to \(maxLatestMessageOffset)) to target a newest message in the chat, or overall when CHAT_ID is omitted."
private let threadIDAliasServicePrefixes = ["any", "iMessage", "RCS", "SMS"]
private let threadIDAliasNote = "CHAT_ID may be a chat ID or recipient identifier; the CLI will resolve bare values to existing chat IDs such as any;-;VALUE, iMessage;-;VALUE, RCS;-;VALUE, or SMS;-;VALUE."

private let commandDefinitions: [CommandDefinition] = [
    CommandDefinition(
        name: "help",
        category: .general,
        summary: "Show top-level help or help for a specific command.",
        usage: ["help", "help COMMAND"],
        examples: ["help", "help send"]
    ) { args, context in
        if args.count > 1 { throw CLIError("usage: help [COMMAND]") }
        try context.showHelp(args.first)
    },
    CommandDefinition(
        name: "version",
        category: .general,
        summary: "Print the platform-imessage package version.",
        usage: ["version"],
        examples: ["version"]
    ) { args, context in
        try requireExactArgs(context.command, args, 0)
        printCLIVersion()
    },
    CommandDefinition(
        name: "shell",
        category: .general,
        summary: "Open the interactive shell.",
        usage: ["shell"],
        examples: ["shell"]
    ) { _, _ in },
    CommandDefinition(
        name: "state",
        category: .general,
        summary: "Print the current CLI runtime state and data paths.",
        usage: ["state"],
        examples: ["state"]
    ) { args, context in
        try requireExactArgs(context.command, args, 0)
        context.showState()
    },
    CommandDefinition(
        name: "watch-status",
        category: .watching,
        summary: "Print event watcher subscription and running state.",
        usage: ["watch-status"],
        examples: ["watch-status"]
    ) { args, context in
        try requireExactArgs(context.command, args, 0)
        print(IMessageHost.isEventWatching)
    },
    CommandDefinition(
        name: "start-watching",
        category: .watching,
        summary: "Start watching Messages database changes and print new DB changes.",
        usage: ["start-watching"],
        examples: ["start-watching"],
        notes: ["Most useful in the interactive shell, or with --stay-open."],
        requiredAuthorization: readOnlyAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 0)
        try await context.invoke(args: []) { api in
            try await context.startEventWatching(api: api)
            return nil
        }
    },
    CommandDefinition(
        name: "stop-watching",
        category: .watching,
        summary: "Stop watching Messages database changes.",
        usage: ["stop-watching"],
        examples: ["stop-watching"],
        notes: ["Stops the watcher task but keeps the CLI process open."],
        requiredAuthorization: readOnlyAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 0)
        try await context.invoke(args: []) { api in
            await IMessageHost.stopEventWatching()
            return nil
        }
    },
    CommandDefinition(
        name: "current-user",
        category: .general,
        summary: "Show the current iMessage identity known to the platform.",
        usage: ["current-user"],
        examples: ["current-user"],
        requiredAuthorization: readOnlyAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 0)
        try await context.invoke(args: []) { api in
            let currentUser = try await api.getCurrentUser()
            return try encodeJSON(currentUser.jsonObject)
        }
    },
    CommandDefinition(
        name: "open-settings",
        category: .general,
        summary: "Open the settings window.",
        usage: ["open-settings"],
        examples: ["open-settings"]
    ) { args, context in
        try requireExactArgs(context.command, args, 0)
        await revealSettingsWindowFromCLI()
    },
    CommandDefinition(
        name: "authorize",
        category: .general,
        summary: "Inspect or request CLI permissions for Accessibility, Contacts, Messages Data, and Automation.",
        usage: ["authorize", "authorize TARGET"],
        examples: ["authorize", "authorize accessibility", "authorize all"],
        notes: ["Targets: all, accessibility, contacts, messages-data, automation."]
    ) { args, context in
        if args.count > 1 { throw CLIError("usage: authorize [all|accessibility|contacts|messages-data|automation]") }
        try await runAuthorizationFlow(target: args.first)
    },
    CommandDefinition(
        name: "chats",
        category: .chat,
        summary: "List chats from the normal inbox.",
        usage: ["chats [--before CURSOR|--after CURSOR]"],
        examples: ["chats", "chats --before 725506281967999900"],
        requiredAuthorization: readOnlyAuth
    ) { args, context in
        let pagination = try parsePaginationArgs(context.command, args, positionalCount: 0)
        try await context.invoke(args: ["normal", pagination.logArgument as Any]) { api in
            let threads = try await api.getThreads(folderName: "normal", pagination: pagination.platformSDKArg)
            return try encodeJSON(context.enrichThreadPageJSON(threads.jsonObject))
        }
    },
    CommandDefinition(
        name: "chat",
        category: .chat,
        summary: "Fetch a single chat by chat ID.",
        usage: ["chat CHAT_ID"],
        examples: ["chat any;-;sjobs@apple.com"],
        notes: [threadIDAliasNote],
        requiredAuthorization: readOnlyAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 1)
        try await context.invoke(args: [args[0]]) { api in
            let threadID = try await resolveThreadIDAlias(args[0], api: api)
            let thread = try await api.getThread(threadID: threadID)
            return try encodeJSON(context.enrichThreadJSON(thread?.jsonObject))
        }
    },
    CommandDefinition(
        name: "messages",
        category: .message,
        summary: "List messages in a chat.",
        usage: ["messages CHAT_ID [--before CURSOR|--after CURSOR]"],
        examples: ["messages any;-;sjobs@apple.com", "messages any;-;sjobs@apple.com --before 725506281967999900"],
        notes: [threadIDAliasNote],
        requiredAuthorization: readOnlyAuth
    ) { args, context in
        let pagination = try parsePaginationArgs(context.command, args, positionalCount: 1)
        let threadID = pagination.positionals[0]
        try await context.invoke(args: [threadID, pagination.logArgument as Any]) { api in
            let threadID = try await resolveThreadIDAlias(threadID, api: api)
            let messages = try await api.getMessages(threadID: threadID, pagination: pagination.platformSDKArg)
            return try encodeJSON(messages.jsonObject)
        }
    },
    CommandDefinition(
        name: "message",
        category: .message,
        summary: "Fetch a single message by message ID.",
        usage: ["message MESSAGE_ID", "message CHAT_ID MESSAGE_ID"],
        examples: ["message C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678", "message latest-1", "message +14155551234 latest"],
        notes: [threadIDAliasNote, messageIDAliasNote],
        requiredAuthorization: readOnlyAuth
    ) { args, context in
        let parsed = try parseMessageReferenceArgs(context.command, args, trailingCount: 0)
        try await context.invoke(args: args) { api in
            let reference = try await resolveMessageReference(
                rawThreadID: parsed.rawThreadID,
                rawMessageID: parsed.rawMessageID,
                api: api
            )
            let message = try await api.getMessage(threadID: reference.threadID, messageID: reference.messageID)
            return try encodeJSON(message?.jsonObject)
        }
    },
    CommandDefinition(
        name: "search",
        category: .message,
        summary: "Search messages by text.",
        usage: ["search QUERY"],
        examples: ["search hello", "search \"project status\""],
        requiredAuthorization: readOnlyAuth
    ) { args, context in
        try requireMinArgs(context.command, args, 1)
        let query = args.joined(separator: " ")
        try await context.invoke(args: [query]) { api in
            let messages = try await api.searchMessages(typed: query, threadID: nil, mediaOnly: false, sender: nil, limit: nil)
            return try encodeJSON(messages.jsonObject)
        }
    },
    CommandDefinition(
        name: "create-chat",
        category: .message,
        summary: "Create or resolve a chat for one or more recipients and send the initial message.",
        usage: ["create-chat RECIPIENT... --message TEXT"],
        examples: ["create-chat sjobs@apple.com --message \"hello from cli\"", "create-chat +15551234567 +15557654321 --message \"group kickoff\""],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        let parsed = try parseStringOption(args, optionName: "message")
        try requireMinArgs(context.command, parsed.positionals, 1)
        let message = try requireStringOption(context.command, optionName: "--message TEXT", value: parsed.value)
        try await context.invoke(args: [parsed.positionals, message]) { api in
            let result = try await api.createThread(userIDs: parsed.positionals, title: nil, messageText: message)
            return try encodeJSON(result.jsonValue)
        }
    },
    CommandDefinition(
        name: "send",
        category: .message,
        summary: "Send a text message to a chat.",
        usage: ["send CHAT_ID TEXT"],
        examples: ["send any;-;sjobs@apple.com \"hello from cli\""],
        notes: [threadIDAliasNote],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireMinArgs(context.command, args, 2)
        let text = try joinText(context.command, args, startIndex: 1)
        try await context.invoke(args: [args[0], ["text": text]]) { api in
            let threadID = try await resolveThreadIDAlias(args[0], api: api)
            let result = try await api.sendMessage(threadID: threadID, text: text, filePath: nil, quotedMessageID: nil)
            return try encodeJSON(result.jsonValue)
        }
    },
    CommandDefinition(
        name: "reply",
        category: .message,
        summary: "Reply to a specific message with text.",
        usage: ["reply MESSAGE_ID TEXT", "reply CHAT_ID MESSAGE_ID TEXT"],
        examples: ["reply C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 \"sounds good\"", "reply latest-1 \"sounds good\"", "reply +14155551234 latest \"sounds good\""],
        notes: [threadIDAliasNote, messageIDAliasNote],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        let parsed = try parseMessageTextArgs(context.command, args)
        try await context.invoke(args: args) { api in
            let reference = try await resolveMessageReference(
                rawThreadID: parsed.rawThreadID,
                rawMessageID: parsed.rawMessageID,
                api: api
            )
            let result = try await api.sendMessage(threadID: reference.threadID, text: parsed.text, filePath: nil, quotedMessageID: reference.messageID)
            return try encodeJSON(result.jsonValue)
        }
    },
    CommandDefinition(
        name: "send-file",
        category: .message,
        summary: "Send a file attachment to a chat.",
        usage: ["send-file CHAT_ID FILE"],
        examples: ["send-file any;-;sjobs@apple.com ./image.png"],
        notes: [threadIDAliasNote],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 2)
        let filePath = absolutePath(args[1])
        try await context.invoke(args: [args[0], ["filePath": filePath]]) { api in
            let threadID = try await resolveThreadIDAlias(args[0], api: api)
            let result = try await api.sendMessage(threadID: threadID, text: nil, filePath: filePath, quotedMessageID: nil)
            return try encodeJSON(result.jsonValue)
        }
    },
    CommandDefinition(
        name: "reply-file",
        category: .message,
        summary: "Reply to a specific message with a file attachment.",
        usage: ["reply-file MESSAGE_ID FILE", "reply-file CHAT_ID MESSAGE_ID FILE"],
        examples: ["reply-file C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 ./document.pdf", "reply-file latest-1 ./document.pdf", "reply-file +14155551234 latest ./document.pdf"],
        notes: [threadIDAliasNote, messageIDAliasNote],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        let parsed = try parseMessageReferenceArgs(context.command, args, trailingCount: 1)
        let filePath = absolutePath(parsed.trailing[parsed.trailing.startIndex])
        try await context.invoke(args: args) { api in
            let reference = try await resolveMessageReference(
                rawThreadID: parsed.rawThreadID,
                rawMessageID: parsed.rawMessageID,
                api: api
            )
            let result = try await api.sendMessage(threadID: reference.threadID, text: nil, filePath: filePath, quotedMessageID: reference.messageID)
            return try encodeJSON(result.jsonValue)
        }
    },
    CommandDefinition(
        name: "edit",
        category: .message,
        summary: "Edit a previously sent message.",
        usage: ["edit MESSAGE_ID TEXT", "edit CHAT_ID MESSAGE_ID TEXT"],
        examples: ["edit C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 \"updated text\"", "edit latest-1 \"updated text\"", "edit +14155551234 latest \"updated text\""],
        notes: ["Message editing is only supported on macOS Ventura or later.", threadIDAliasNote, messageIDAliasNote],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        let parsed = try parseMessageTextArgs(context.command, args)
        try await context.invoke(args: args) { api in
            let reference = try await resolveMessageReference(
                rawThreadID: parsed.rawThreadID,
                rawMessageID: parsed.rawMessageID,
                api: api,
                ownedOnly: true
            )
            try await api.editMessage(threadID: reference.threadID, messageID: reference.messageID, content: parsed.text)
            return nil
        }
    },
    CommandDefinition(
        name: "undo-send",
        category: .message,
        summary: "Undo send for a previously sent message.",
        usage: ["undo-send MESSAGE_ID", "undo-send CHAT_ID MESSAGE_ID"],
        examples: ["undo-send C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678", "undo-send latest-1", "undo-send +14155551234 latest"],
        notes: ["Undo send is only supported on macOS Ventura or later and must be used within 2 minutes of sending.", threadIDAliasNote, messageIDAliasNote],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        let parsed = try parseMessageReferenceArgs(context.command, args, trailingCount: 0)
        try await context.invoke(args: args) { api in
            let reference = try await resolveMessageReference(
                rawThreadID: parsed.rawThreadID,
                rawMessageID: parsed.rawMessageID,
                api: api,
                ownedOnly: true
            )
            try await api.deleteMessage(threadID: reference.threadID, messageID: reference.messageID)
            return nil
        }
    },
    reactionCommand(name: "react", summaryVerb: "Add", preposition: "to") { api, threadID, messageID, key in
        try await api.addReaction(threadID: threadID, messageID: messageID, reactionKey: key)
    },
    reactionCommand(name: "unreact", summaryVerb: "Remove", preposition: "from") { api, threadID, messageID, key in
        try await api.removeReaction(threadID: threadID, messageID: messageID, reactionKey: key)
    },
    CommandDefinition(
        name: "mark-read",
        category: .chat,
        summary: "Mark a chat as read.",
        usage: ["mark-read CHAT_ID"],
        examples: ["mark-read any;-;sjobs@apple.com"],
        notes: [threadIDAliasNote],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 1)
        try await context.invoke(args: args) { api in
            let threadID = try await resolveThreadIDAlias(args[0], api: api)
            try await api.sendReadReceipt(threadID: threadID)
            return nil
        }
    },
    CommandDefinition(
        name: "mark-unread",
        category: .chat,
        summary: "Mark a chat as unread.",
        usage: ["mark-unread CHAT_ID"],
        examples: ["mark-unread any;-;sjobs@apple.com"],
        notes: [threadIDAliasNote],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 1)
        try await context.invoke(args: args) { api in
            let threadID = try await resolveThreadIDAlias(args[0], api: api)
            try await api.markAsUnread(threadID: threadID)
            return nil
        }
    },
    CommandDefinition(
        name: "delete-chat",
        category: .chat,
        summary: "Delete a chat from Messages.",
        usage: ["delete-chat CHAT_ID"],
        examples: ["delete-chat any;-;sjobs@apple.com"],
        notes: ["This mutates real Messages state.", threadIDAliasNote],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 1)
        try await context.invoke(args: args) { api in
            let threadID = try await resolveThreadIDAlias(args[0], api: api)
            try await api.deleteThread(threadID: threadID)
            return nil
        }
    },
    CommandDefinition(
        name: "notify-anyway",
        category: .chat,
        summary: "Trigger the \"notify anyway\" action for a chat.",
        usage: ["notify-anyway CHAT_ID"],
        examples: ["notify-anyway any;-;sjobs@apple.com"],
        notes: [threadIDAliasNote],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 1)
        try await context.invoke(args: args) { api in
            let threadID = try await resolveThreadIDAlias(args[0], api: api)
            try await api.notifyAnyway(threadID: threadID)
            return nil
        }
    },
    muteCommand(name: "mute", muted: true),
    muteCommand(name: "unmute", muted: false),
    CommandDefinition(
        name: "select-chat",
        category: .chat,
        summary: "Select a chat and start the chat activity watcher.",
        usage: ["select-chat CHAT_ID"],
        examples: ["select-chat any;-;sjobs@apple.com"],
        notes: [threadIDAliasNote],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 1)
        try await context.invoke(args: args) { api in
            let threadID = try await resolveThreadIDAlias(args[0], api: api)
            try await api.onThreadSelected(threadID: threadID) { events in
                let json = try encodeJSON(events.map { $0.jsonObject() })
                context.printEventJSON(json)
            }
            return nil
        }
    },
    CommandDefinition(
        name: "typing",
        category: .chat,
        summary: "Send typing on/off status for a chat.",
        usage: ["typing CHAT_ID on|off"],
        examples: ["typing any;-;sjobs@apple.com on", "typing any;-;sjobs@apple.com off"],
        notes: [threadIDAliasNote],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 2)
        let type: String
        switch args[1] {
        case "on": type = "typing"
        case "off": type = "none"
        default: throw CLIError("usage: \(context.command.usage[0])")
        }
        try await context.invoke(args: [type, args[0]]) { api in
            let threadID = try await resolveThreadIDAlias(args[0], api: api)
            try await api.sendActivityIndicator(type: type, threadID: threadID)
            return nil
        }
    },
]

private let commandMap = Dictionary(uniqueKeysWithValues: commandDefinitions.map { ($0.name, $0) })
private let commandAliases = [
    "threads": "chats",
    "thread": "chat",
    "create-thread": "create-chat",
    "delete-thread": "delete-chat",
    "select-thread": "select-chat",
]

private func resolveCommand(_ name: String) -> CommandDefinition? {
    commandMap[name] ?? commandAliases[name].flatMap { commandMap[$0] }
}

private func runBootstrapFreeCommandIfNeeded(_ commandArgs: [String]) throws -> Bool {
    guard let name = commandArgs.first, name == "version" else { return false }
    guard let command = resolveCommand(name) else { return false }
    let args = Array(commandArgs.dropFirst())
    if args.contains("--help") || args.contains("-h") {
        printCommandHelp(command)
    } else {
        try requireExactArgs(command, args, 0)
        printCLIVersion()
    }
    return true
}

private func printCLIVersion() {
    print("platform-imessage \(IMessageCLIVersion.packageVersion)")
}

private func reactionCommand(
    name: String,
    summaryVerb: String,
    preposition: String,
    apply: @escaping (PlatformAPI, String, String, String) async throws -> Void
) -> CommandDefinition {
    CommandDefinition(
        name: name,
        category: .message,
        summary: "\(summaryVerb) a reaction \(preposition) a message using a standard key or emoji.",
        usage: ["\(name) MESSAGE_ID REACTION", "\(name) CHAT_ID MESSAGE_ID REACTION"],
        examples: [
            "\(name) C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 heart",
            "\(name) latest-1 ❤️",
            "\(name) +14155551234 latest heart",
        ],
        notes: [threadIDAliasNote, messageIDAliasNote, "Supported standard keys: heart, like, dislike, laugh, emphasize, question.", "Sticker reactions are not exposed in this CLI."],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        let parsed = try parseMessageReferenceArgs(context.command, args, trailingCount: 1)
        try await context.invoke(args: args) { api in
            let reference = try await resolveMessageReference(
                rawThreadID: parsed.rawThreadID,
                rawMessageID: parsed.rawMessageID,
                api: api
            )
            try await apply(api, reference.threadID, reference.messageID, parsed.trailing[parsed.trailing.startIndex])
            return nil
        }
    }
}

private struct MessageReferenceArgs {
    let rawThreadID: String?
    let rawMessageID: String
    let trailing: ArraySlice<String>
}

private func parseMessageReferenceArgs(_ command: CommandDefinition, _ args: [String], trailingCount: Int) throws -> MessageReferenceArgs {
    let bare = 1 + trailingCount
    let withChat = 2 + trailingCount
    if args.count == bare {
        if looksLikeFullThreadIDOrAlias(args[0]) {
            throw missingMessageIDAliasError(command, args)
        }
        return MessageReferenceArgs(rawThreadID: nil, rawMessageID: args[0], trailing: args.dropFirst())
    }
    if args.count == withChat {
        if parsesAsThreadIDAndMessageID(args[0], args[1]) {
            return MessageReferenceArgs(rawThreadID: args[0], rawMessageID: args[1], trailing: args.dropFirst(2))
        }
        throw CLIError("\(command.name) could not parse \"\(args[0]) \(args[1])\" as CHAT_ID MESSAGE_ID. MESSAGE_ID must be a UUID or a latest alias.\n\(commandUsageSummary(command))")
    }
    throw CLIError("\(command.name) expects \(bare) or \(withChat) arguments, got \(args.count).\n\(commandUsageSummary(command))")
}

private func parseMessageTextArgs(_ command: CommandDefinition, _ args: [String]) throws -> (rawThreadID: String?, rawMessageID: String, text: String) {
    guard args.count >= 2 else {
        throw CLIError("\(command.name) expects at least 2 arguments.\n\(commandUsageSummary(command))")
    }

    if args.count == 2, looksLikeFullThreadIDOrAlias(args[0]) {
        throw missingMessageIDAliasError(command, args)
    }

    let hasThreadID = args.count >= 3 && parsesAsThreadIDAndMessageID(args[0], args[1])
    let messageIndex = hasThreadID ? 1 : 0
    let textStartIndex = hasThreadID ? 2 : 1
    let text = try joinText(command, args, startIndex: textStartIndex)
    return (hasThreadID ? args[0] : nil, args[messageIndex], text)
}

private func missingMessageIDAliasError(_ command: CommandDefinition, _ args: [String]) -> CLIError {
    var suggestedArgs = args
    suggestedArgs.insert("latest", at: 1)
    let suggestion = ([command.name] + suggestedArgs)
        .map(shellQuoteForSuggestion)
        .joined(separator: " ")

    return CLIError(
        "\(command.name) got a chat ID or recipient alias where MESSAGE_ID was expected. " +
            "To target the newest message in that chat, add latest: \(suggestion)"
    )
}

private func shellQuoteForSuggestion(_ token: String) -> String {
    let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
    if !token.isEmpty, token.rangeOfCharacter(from: safeCharacters.inverted) == nil {
        return token
    }
    return "'\(token.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func resolveMessageReference(rawThreadID: String?, rawMessageID: String, api: PlatformAPI, ownedOnly: Bool = false) async throws -> PlatformAPI.MessageReference {
    if let rawThreadID {
        let threadID = try await resolveThreadIDAlias(rawThreadID, api: api)
        let messageID = try await resolveMessageID(rawMessageID, threadID: threadID, api: api, ownedOnly: ownedOnly)
        return PlatformAPI.MessageReference(threadID: threadID, messageID: messageID)
    }

    if let offset = try latestMessageOffset(rawMessageID) {
        guard let reference = try await api.resolveLatestMessageReference(offset: offset, ownedOnly: ownedOnly) else {
            let scope = ownedOnly ? "sent messages" : "messages"
            throw CLIError("cannot resolve \(rawMessageID): no \(scope) found")
        }
        return reference
    }

    guard let reference = try await api.resolveMessageReference(messageID: rawMessageID) else {
        throw CLIError("cannot resolve message \(rawMessageID): no matching message found")
    }
    return reference
}

private func resolveThreadIDAlias(_ threadID: String, api: PlatformAPI) async throws -> String {
    let trimmed = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return threadID }

    let candidates = threadIDCandidates(forAlias: trimmed)
    if candidates.isEmpty {
        return trimmed
    }

    let existingChatGUIDs = Set(try await api.lookupExistingThreadGUIDs(guids: candidates))
    guard let best = candidates.first(where: existingChatGUIDs.contains) else {
        let tried = candidates.joined(separator: ", ")
        throw CLIError("cannot resolve chat \(trimmed): no existing chat found. Tried \(tried)")
    }

    return best
}

private func threadIDCandidates(forAlias alias: String) -> [String] {
    guard !alias.hasPrefix("imsg##thread:"),
          !alias.contains(";") else {
        return []
    }

    var candidates = [String]()

    func append(_ candidate: String) {
        guard !candidate.isEmpty, !candidates.contains(candidate) else { return }
        candidates.append(candidate)
    }

    for variant in threadIDAliasVariants(alias) {
        append(variant)
        for servicePrefix in threadIDAliasServicePrefixes {
            append("\(servicePrefix);-;\(variant)")
        }
    }

    return candidates
}

private func resolveMessageID(_ messageID: String, threadID: String, api: PlatformAPI, ownedOnly: Bool = false) async throws -> String {
    guard let offset = try latestMessageOffset(messageID) else { return messageID }
    guard let reference = try await api.resolveLatestMessageReference(threadID: threadID, offset: offset, ownedOnly: ownedOnly) else {
        let scope = ownedOnly ? "sent messages" : "messages"
        throw CLIError("cannot resolve \(messageID): no \(scope) found in chat \(threadID)")
    }
    return reference.messageID
}

private func latestMessageOffset(_ messageID: String) throws -> Int? {
    if latestMessageIDAliases.contains(messageID) {
        return 0
    }

    let prefix = "latest-"
    guard messageID.hasPrefix(prefix) else { return nil }
    let rawOffset = messageID.dropFirst(prefix.count)
    guard !rawOffset.isEmpty,
          rawOffset.allSatisfy(\.isNumber),
          let offset = Int(rawOffset),
          (0...maxLatestMessageOffset).contains(offset) else {
        throw CLIError("latest message aliases must be latest or latest-N where N is 0...\(maxLatestMessageOffset)")
    }
    return offset
}

private func looksLikeFullThreadID(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.hasPrefix("imsg##thread:")
        || trimmed.contains(";")
}

private func looksLikeFullThreadIDOrAlias(_ value: String) -> Bool {
    looksLikeFullThreadID(value) || looksLikeBareThreadIDAlias(value)
}

private func parsesAsThreadIDAndMessageID(_ rawThreadID: String, _ rawMessageID: String) -> Bool {
    looksLikeFullThreadID(rawThreadID)
        || (looksLikeBareThreadIDAlias(rawThreadID) && looksLikeMessageReferenceID(rawMessageID))
}

private func looksLikeBareThreadIDAlias(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty
        && !looksLikeFullThreadID(trimmed)
        && !looksLikeMessageReferenceID(trimmed)
}

private func looksLikeMessageReferenceID(_ value: String) -> Bool {
    looksLikeLatestMessageAlias(value) || looksLikeMessageGUID(value)
}

private func looksLikeLatestMessageAlias(_ value: String) -> Bool {
    if latestMessageIDAliases.contains(value) {
        return true
    }
    let prefix = "latest-"
    guard value.hasPrefix(prefix) else { return false }
    let rawOffset = value.dropFirst(prefix.count)
    return !rawOffset.isEmpty && rawOffset.allSatisfy(\.isNumber)
}

private func looksLikeMessageGUID(_ value: String) -> Bool {
    UUID(uuidString: messageGUID(fromID: value)) != nil
}

private func looksLikeBarePhoneNumber(_ value: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "+0123456789 -().")
    guard !value.isEmpty,
          value.rangeOfCharacter(from: allowed.inverted) == nil else {
        return false
    }
    return value.filter(\.isNumber).count >= 3
}

private func threadIDAliasVariants(_ address: String) -> [String] {
    var variants = [String]()

    func append(_ variant: String) {
        guard !variant.isEmpty, !variants.contains(variant) else { return }
        variants.append(variant)
    }

    append(address)

    append(address.lowercased())

    if looksLikeBarePhoneNumber(address) {
        let compactPhone = address.filter { $0 == "+" || $0.isNumber }
        append(compactPhone)

        // iMessage stores numbers in E.164 (`+14155551234`). Best-effort upgrade
        // for bare US-shaped input so `4155551234` and `14155551234` resolve.
        if !compactPhone.hasPrefix("+") {
            let digits = compactPhone.filter(\.isNumber)
            if digits.count == 10 {
                append("+1\(digits)")
            } else if digits.count == 11, digits.hasPrefix("1") {
                append("+\(digits)")
            }
        }
    }

    return variants
}

private func muteCommand(name: String, muted: Bool) -> CommandDefinition {
    CommandDefinition(
        name: name,
        category: .chat,
        summary: muted ? "Mute a chat indefinitely." : "Unmute a chat.",
        usage: ["\(name) CHAT_ID"],
        examples: ["\(name) any;-;sjobs@apple.com"],
        notes: [threadIDAliasNote],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 1)
        let mutedUntil: Any = muted ? "forever" : NSNull()
        try await context.invoke(args: [args[0], ["mutedUntil": mutedUntil]]) { api in
            let threadID = try await resolveThreadIDAlias(args[0], api: api)
            try await api.updateThread(threadID: threadID, muted: muted)
            return nil
        }
    }
}

private func ensureRunnerState(_ options: RunnerOptions) throws -> RunnerState {
    let dataDirPath: String
    if let customDataDir = options.customDataDir {
        dataDirPath = absolutePath(customDataDir)
    } else {
        dataDirPath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("platform-imessage-cli-\(UUID().uuidString)", isDirectory: true)
            .path
    }
    try FileManager.default.createDirectory(atPath: dataDirPath, withIntermediateDirectories: true)
    return RunnerState(
        options: options,
        dataDirPath: dataDirPath,
        sessionFilePath: URL(fileURLWithPath: dataDirPath).appendingPathComponent("session.json").path
    )
}

private func printTopLevelHelp() {
    var lines = [
        "platform-imessage Swift CLI \(IMessageCLIVersion.packageVersion)",
        "",
        "Usage:",
        "  imessage-cli [global options]",
        "  imessage-cli COMMAND [ARGS...]",
        "  imessage-cli version",
        "",
        "Bare launch (or `shell`) opens the interactive shell.",
        "",
        "Global options:",
        "  --data-dir PATH          Store CLI state under PATH instead of a temp directory",
        "  --use-secondary-instance Use a secondary Messages.app instance (default). Pass --no-use-secondary-instance to disable",
        "  --no-events              Do not subscribe to new DB changes after running commands",
        "  --stay-open              Run one command, then stay open in the interactive shell",
        "  --verbose                Enable verbose logging",
        "",
    ]

    for category in commandCategories {
        let commands = commandDefinitions.filter { $0.category == category }
        guard !commands.isEmpty else { continue }
        lines.append("\(category.rawValue) commands:")
        for command in commands {
            lines.append("  \(command.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(command.summary)")
        }
        lines.append("")
    }

    lines.append("Run `help COMMAND` for detailed usage and examples.")
    print(lines.joined(separator: "\n"))
}

private func printCommandHelp(_ command: CommandDefinition) {
    var lines = [
        command.name,
        "",
        command.summary,
        "",
        "Usage:",
    ]
    lines.append(contentsOf: command.usage.map { "  \($0)" })
    lines.append("")
    lines.append("Examples:")
    lines.append(contentsOf: command.examples.map { "  \($0)" })
    if !command.notes.isEmpty {
        lines.append("")
        lines.append("Notes:")
        lines.append(contentsOf: command.notes.map { "  \($0)" })
    }
    print(lines.joined(separator: "\n"))
}

private func commandUsageSummary(_ command: CommandDefinition) -> String {
    var lines = ["Usage:"]
    lines.append(contentsOf: command.usage.map { "  \($0)" })
    lines.append("")
    lines.append("Examples:")
    lines.append(contentsOf: command.examples.map { "  \($0)" })
    return lines.joined(separator: "\n")
}

private func requireExactArgs(_ command: CommandDefinition, _ args: [String], _ count: Int) throws {
    guard args.count == count else {
        throw CLIError("\(command.name) expects \(count) argument\(count == 1 ? "" : "s").\nusage: \(command.usage[0])")
    }
}

private func requireMinArgs(_ command: CommandDefinition, _ args: [String], _ count: Int) throws {
    guard args.count >= count else {
        throw CLIError("\(command.name) expects at least \(count) argument\(count == 1 ? "" : "s").\nusage: \(command.usage[0])")
    }
}

private func requireStringOption(_ command: CommandDefinition, optionName: String, value: String?) throws -> String {
    let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let text, !text.isEmpty else {
        throw CLIError("\(command.name) requires \(optionName).\nusage: \(command.usage[0])")
    }
    return text
}

private func joinText(_ command: CommandDefinition, _ tokens: [String], startIndex: Int) throws -> String {
    let text = tokens.dropFirst(startIndex).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        throw CLIError("\(command.name) requires text content.\nusage: \(command.usage[0])")
    }
    return text
}

private struct PaginationParseResult {
    var positionals: [String]
    var cursor: String?
    var direction: String?

    var platformSDKArg: PlatformSDK.PaginationArg? {
        guard let cursor, let directionValue = direction, let direction = PlatformSDK.PaginationDirection(rawValue: directionValue) else {
            return nil
        }
        return PlatformSDK.PaginationArg(cursor: cursor, direction: direction)
    }

    var logArgument: [String: String]? {
        guard let cursor, let direction else { return nil }
        return ["cursor": cursor, "direction": direction]
    }
}

private func parsePaginationArgs(_ command: CommandDefinition, _ args: [String], positionalCount: Int) throws -> PaginationParseResult {
    var positionals = [String]()
    var after: String?
    var before: String?
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--after":
            after = try readOptionValue(command, iterator.next(), flag: "--after")
        case "--before":
            before = try readOptionValue(command, iterator.next(), flag: "--before")
        default:
            if let value = arg.optionValue(prefix: "--after=") {
                after = try readOptionValue(command, value, flag: "--after")
            } else if let value = arg.optionValue(prefix: "--before=") {
                before = try readOptionValue(command, value, flag: "--before")
            } else {
                positionals.append(arg)
            }
        }
    }
    try requireExactArgs(command, positionals, positionalCount)
    if after != nil && before != nil {
        throw CLIError("\(command.name) accepts only one of --after or --before.\nusage: \(command.usage[0])")
    }
    let direction: String? = after != nil ? "after" : (before != nil ? "before" : nil)
    return PaginationParseResult(positionals: positionals, cursor: after ?? before, direction: direction)
}

private func parseStringOption(_ args: [String], optionName: String) throws -> (positionals: [String], value: String?) {
    var positionals = [String]()
    var value: String?
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        if arg == "--\(optionName)" {
            value = iterator.next()
        } else if let inline = arg.optionValue(prefix: "--\(optionName)=") {
            value = inline
        } else {
            positionals.append(arg)
        }
    }
    return (positionals, value)
}

private func readOptionValue(_ command: CommandDefinition, _ value: String?, flag: String) throws -> String {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        throw CLIError("\(command.name) requires a cursor after \(flag).\nusage: \(command.usage[0])")
    }
    return trimmed
}

private func tokenizeInput(_ input: String) throws -> [String] {
    var tokens = [String]()
    var current = ""
    var quote: Character?
    var index = input.startIndex

    func pushCurrent() {
        guard !current.isEmpty else { return }
        tokens.append(current)
        current = ""
    }

    while index < input.endIndex {
        let char = input[index]
        if char == "\\" {
            let next = input.index(after: index)
            if next < input.endIndex {
                current.append(input[next])
                index = input.index(after: next)
            } else {
                index = next
            }
            continue
        }
        if let activeQuote = quote {
            if char == activeQuote {
                quote = nil
            } else {
                current.append(char)
            }
            index = input.index(after: index)
            continue
        }
        if char == "\"" || char == "'" {
            quote = char
        } else if char.isWhitespace {
            pushCurrent()
        } else {
            current.append(char)
        }
        index = input.index(after: index)
    }

    if let quote {
        throw CLIError("unterminated \(quote) quote")
    }
    pushCurrent()
    return tokens
}

private func runPreflightAuthCheck(commandName: String, requirements: [AuthorizationRequirement]) async throws {
    for requirement in requirements {
        if await requirement.currentStatus().authorized { continue }
        print("\"\(commandName)\" needs \(requirement.title) access. Requesting...")
        try await requirement.request()
        let updated = await requirement.currentStatus()
        if !updated.authorized {
            throw CLIError("\(requirement.title) was not granted. \(updated.detail)")
        }
    }
}

private func missingAuthorizationRequirements(_ requirements: [AuthorizationRequirement]) async -> [AuthorizationRequirement] {
    var missing = [AuthorizationRequirement]()
    for requirement in requirements {
        if !(await requirement.currentStatus().authorized) {
            missing.append(requirement)
        }
    }
    return missing
}

private func runAuthorizationFlow(target rawTarget: String?) async throws {
    let trimmed = rawTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = (trimmed?.isEmpty == false ? trimmed : nil) ?? "all"
    let names: [String] = resolved == "all" ? ["accessibility", "contacts", "messages-data", "automation"] : [resolved]

    func printStatus(_ requirement: AuthorizationRequirement, _ status: (authorized: Bool, detail: String)) {
        print("  \(status.authorized ? "[ok]" : "[ ]") \(requirement.title) - \(status.detail)")
    }

    for name in names {
        if name == "automation" {
            print("  Checking Automation - verifying Apple Events access to Messages.app.")
            let ok = await authorizeAutomation()
            print("  \(ok ? "[ok]" : "[ ]") Automation - \(ok ? "Apple Events access to Messages.app is available." : "Automation access was denied or unavailable.")")
            continue
        }
        guard let req = AuthorizationRequirement(rawValue: name) else {
            throw CLIError("unknown authorization target \"\(name)\".\nusage: authorize [all|accessibility|contacts|messages-data|automation]")
        }
        let status = await req.currentStatus()
        printStatus(req, status)
        if !status.authorized {
            print("  Requesting \(req.title)...")
            if req == .messagesData {
                print("  note: After granting Messages Data, macOS may terminate imessage-cli; if it exits, run it again.")
            }
            try await req.request()
            printStatus(req, await req.currentStatus())
        }
    }
}

private func authorizeAutomation() async -> Bool {
    do {
        try await MacPermissions.askForAutomationAccess()
        return true
    } catch {
        print("  note: Automation prompt failed: \(error)")
        return false
    }
}

private func revealSettingsWindowFromCLI() async {
    await MainActor.run {
        prepareSettingsWindowApplication()
        installSettingsWindowCommandMenu()
    }
    await IMessageHost.revealSettingsForUserInteraction()
    await MainActor.run {
        runSettingsWindowEventLoopUntilClosed()
    }
}

@MainActor
private func prepareSettingsWindowApplication() {
    NSApplication.shared.prepareAndActivate()
}

@MainActor
private func installSettingsWindowCommandMenu() {
    let mainMenu = NSMenu()

    let appMenu = NSMenu()
    let appName = ProcessInfo.processInfo.processName
    let quitItem = NSMenuItem(
        title: "Quit \(appName)",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    quitItem.target = NSApp
    appMenu.addItem(quitItem)

    let appMenuItem = NSMenuItem()
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    let fileMenu = NSMenu(title: "File")
    fileMenu.addItem(NSMenuItem(
        title: "Close Window",
        action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w"
    ))

    let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    fileMenuItem.submenu = fileMenu
    mainMenu.addItem(fileMenuItem)

    NSApp.mainMenu = mainMenu
}

@MainActor
private func runSettingsWindowEventLoopUntilClosed() {
    while IMessageHost.isSettingsWindowVisible {
        autoreleasepool {
            if let event = NSApp.nextEvent(
                matching: .any,
                until: Date.distantFuture,
                inMode: .default,
                dequeue: true
            ) {
                NSApp.sendEvent(event)
                NSApp.updateWindows()
            }
        }
    }
}

private func canAccessMessagesDir() async -> Bool {
    do {
        return try await MacPermissions.canAccessMessagesDir()
    } catch {
        return false
    }
}

private func pollAuthorization(timeout: TimeInterval, interval: UInt64 = 250_000_000, test: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if test() { return true }
        try? await Task.sleep(nanoseconds: interval)
    }
    return test()
}

private func absolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return expanded }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).standardized.path
}

private func elapsedMilliseconds(since date: Date) -> String {
    String(format: "%.3f", date.elapsedMilliseconds)
}

private func prettyJSONString(_ raw: String) -> String {
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
          JSONSerialization.isValidJSONObject(object),
          let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let pretty = String(data: prettyData, encoding: .utf8)
    else {
        return raw
    }
    return pretty
}

private func formatValue(_ value: Any) -> String {
    guard let string = try? encodeJSON(value) else { return String(describing: value) }
    return prettyJSONString(string).replacingOccurrences(of: "\n", with: " ")
}

private extension String {
    func optionValue(prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

private struct CLIError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
