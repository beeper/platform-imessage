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
}

private final class Runner {
    private let options: RunnerOptions
    private var state: RunnerState?
    private var apiInstance: PlatformAPI?
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
        guard let command = commandMap[commandName] else {
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
        guard let command = commandMap[name] else {
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
        name: "threads",
        category: .chat,
        summary: "List chats from the normal inbox.",
        usage: ["threads [--before CURSOR|--after CURSOR]"],
        examples: ["threads", "threads --before 725506281967999900"],
        requiredAuthorization: readOnlyAuth
    ) { args, context in
        let pagination = try parsePaginationArgs(context.command, args, positionalCount: 0)
        try await context.invoke(args: ["normal", pagination.logArgument as Any]) { api in
            let threads = try await api.getThreads(folderName: "normal", pagination: pagination.platformSDKArg)
            return try encodeJSON(threads.jsonObject)
        }
    },
    CommandDefinition(
        name: "thread",
        category: .chat,
        summary: "Fetch a single chat by chat ID.",
        usage: ["thread CHAT_ID"],
        examples: ["thread any;-;sjobs@apple.com"],
        requiredAuthorization: readOnlyAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 1)
        try await context.invoke(args: [args[0]]) { api in
            let thread = try await api.getThread(threadID: args[0])
            return try encodeJSON(thread?.jsonObject)
        }
    },
    CommandDefinition(
        name: "messages",
        category: .message,
        summary: "List messages in a chat.",
        usage: ["messages CHAT_ID [--before CURSOR|--after CURSOR]"],
        examples: ["messages any;-;sjobs@apple.com", "messages any;-;sjobs@apple.com --before 725506281967999900"],
        requiredAuthorization: readOnlyAuth
    ) { args, context in
        let pagination = try parsePaginationArgs(context.command, args, positionalCount: 1)
        let threadID = pagination.positionals[0]
        try await context.invoke(args: [threadID, pagination.logArgument as Any]) { api in
            let messages = try await api.getMessages(threadID: threadID, pagination: pagination.platformSDKArg)
            return try encodeJSON(messages.jsonObject)
        }
    },
    CommandDefinition(
        name: "message",
        category: .message,
        summary: "Fetch a single message by chat ID and message ID.",
        usage: ["message CHAT_ID MESSAGE_ID"],
        examples: ["message any;-;sjobs@apple.com C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678"],
        requiredAuthorization: readOnlyAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 2)
        try await context.invoke(args: args) { api in
            let message = try await api.getMessage(threadID: args[0], messageID: args[1])
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
        name: "create-thread",
        category: .message,
        summary: "Create or resolve a chat for one or more recipients and send the initial message.",
        usage: ["create-thread RECIPIENT... --message TEXT"],
        examples: ["create-thread sjobs@apple.com --message \"hello from cli\"", "create-thread +15551234567 +15557654321 --message \"group kickoff\""],
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
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireMinArgs(context.command, args, 2)
        let text = try joinText(context.command, args, startIndex: 1)
        try await context.invoke(args: [args[0], ["text": text]]) { api in
            let result = try await api.sendMessage(threadID: args[0], text: text, filePath: nil, quotedMessageID: nil)
            return try encodeJSON(result.jsonValue)
        }
    },
    CommandDefinition(
        name: "reply",
        category: .message,
        summary: "Reply to a specific message with text.",
        usage: ["reply CHAT_ID MESSAGE_ID TEXT"],
        examples: ["reply any;-;sjobs@apple.com C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 \"sounds good\""],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireMinArgs(context.command, args, 3)
        let text = try joinText(context.command, args, startIndex: 2)
        try await context.invoke(args: [args[0], ["text": text], ["quotedMessageID": args[1]]]) { api in
            let result = try await api.sendMessage(threadID: args[0], text: text, filePath: nil, quotedMessageID: args[1])
            return try encodeJSON(result.jsonValue)
        }
    },
    CommandDefinition(
        name: "send-file",
        category: .message,
        summary: "Send a file attachment to a chat.",
        usage: ["send-file CHAT_ID FILE"],
        examples: ["send-file any;-;sjobs@apple.com ./image.png"],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 2)
        let filePath = absolutePath(args[1])
        try await context.invoke(args: [args[0], ["filePath": filePath]]) { api in
            let result = try await api.sendMessage(threadID: args[0], text: nil, filePath: filePath, quotedMessageID: nil)
            return try encodeJSON(result.jsonValue)
        }
    },
    CommandDefinition(
        name: "reply-file",
        category: .message,
        summary: "Reply to a specific message with a file attachment.",
        usage: ["reply-file CHAT_ID MESSAGE_ID FILE"],
        examples: ["reply-file any;-;sjobs@apple.com C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 ./document.pdf"],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 3)
        let filePath = absolutePath(args[2])
        try await context.invoke(args: [args[0], ["filePath": filePath], ["quotedMessageID": args[1]]]) { api in
            let result = try await api.sendMessage(threadID: args[0], text: nil, filePath: filePath, quotedMessageID: args[1])
            return try encodeJSON(result.jsonValue)
        }
    },
    CommandDefinition(
        name: "edit",
        category: .message,
        summary: "Edit a previously sent message.",
        usage: ["edit CHAT_ID MESSAGE_ID TEXT"],
        examples: ["edit any;-;sjobs@apple.com C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 \"updated text\""],
        notes: ["Message editing is only supported on macOS Ventura or later."],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireMinArgs(context.command, args, 3)
        let text = try joinText(context.command, args, startIndex: 2)
        try await context.invoke(args: [args[0], args[1], ["text": text]]) { api in
            try await api.editMessage(threadID: args[0], messageID: args[1], content: text)
            return nil
        }
    },
    CommandDefinition(
        name: "undo-send",
        category: .message,
        summary: "Undo send for a previously sent message.",
        usage: ["undo-send CHAT_ID MESSAGE_ID"],
        examples: ["undo-send any;-;sjobs@apple.com C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678"],
        notes: ["Undo send is only supported on macOS Ventura or later and must be used within 2 minutes of sending."],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 2)
        try await context.invoke(args: args) { api in
            try await api.deleteMessage(threadID: args[0], messageID: args[1])
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
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 1)
        try await context.invoke(args: args) { api in
            try await api.sendReadReceipt(threadID: args[0])
            return nil
        }
    },
    CommandDefinition(
        name: "mark-unread",
        category: .chat,
        summary: "Mark a chat as unread.",
        usage: ["mark-unread CHAT_ID"],
        examples: ["mark-unread any;-;sjobs@apple.com"],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 1)
        try await context.invoke(args: args) { api in
            try await api.markAsUnread(threadID: args[0])
            return nil
        }
    },
    CommandDefinition(
        name: "delete-thread",
        category: .chat,
        summary: "Delete a chat from Messages.",
        usage: ["delete-thread CHAT_ID"],
        examples: ["delete-thread any;-;sjobs@apple.com"],
        notes: ["This mutates real Messages state."],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 1)
        try await context.invoke(args: args) { api in
            try await api.deleteThread(threadID: args[0])
            return nil
        }
    },
    CommandDefinition(
        name: "notify-anyway",
        category: .chat,
        summary: "Trigger the \"notify anyway\" action for a chat.",
        usage: ["notify-anyway CHAT_ID"],
        examples: ["notify-anyway any;-;sjobs@apple.com"],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 1)
        try await context.invoke(args: args) { api in
            try await api.notifyAnyway(threadID: args[0])
            return nil
        }
    },
    muteCommand(name: "mute", muted: true),
    muteCommand(name: "unmute", muted: false),
    CommandDefinition(
        name: "select-thread",
        category: .chat,
        summary: "Select a chat and start the chat-activity watcher.",
        usage: ["select-thread CHAT_ID"],
        examples: ["select-thread any;-;sjobs@apple.com"],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 1)
        try await context.invoke(args: args) { api in
            try await api.onThreadSelected(threadID: args[0]) { events in
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
            try await api.sendActivityIndicator(type: type, threadID: args[0])
            return nil
        }
    },
]

private let commandMap = Dictionary(uniqueKeysWithValues: commandDefinitions.map { ($0.name, $0) })

private func runBootstrapFreeCommandIfNeeded(_ commandArgs: [String]) throws -> Bool {
    guard let name = commandArgs.first, name == "version" else { return false }
    guard let command = commandMap[name] else { return false }
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
        usage: ["\(name) CHAT_ID MESSAGE_ID REACTION"],
        examples: [
            "\(name) any;-;sjobs@apple.com C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 heart",
            "\(name) any;-;sjobs@apple.com C0FFEE12-CAFE-4BAD-8ACE-1234FACE5678 ❤️",
        ],
        notes: ["Supported standard keys: heart, like, dislike, laugh, emphasize, question.", "Sticker reactions are not exposed in this CLI."],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 3)
        try await context.invoke(args: args) { api in
            try await apply(api, args[0], args[1], args[2])
            return nil
        }
    }
}

private func muteCommand(name: String, muted: Bool) -> CommandDefinition {
    CommandDefinition(
        name: name,
        category: .chat,
        summary: muted ? "Mute a chat indefinitely." : "Unmute a chat.",
        usage: ["\(name) CHAT_ID"],
        examples: ["\(name) any;-;sjobs@apple.com"],
        requiredAuthorization: mutatingAuth
    ) { args, context in
        try requireExactArgs(context.command, args, 1)
        let mutedUntil: Any = muted ? "forever" : NSNull()
        try await context.invoke(args: [args[0], ["mutedUntil": mutedUntil]]) { api in
            try await api.updateThread(threadID: args[0], muted: muted)
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
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    if #available(macOS 14, *) {
        app.activate()
    } else {
        app.activate(ignoringOtherApps: true)
    }
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
