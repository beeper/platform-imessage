import AppKit
import CodeEditorView
import Contacts
import Foundation
import IMessage
import LanguageSupport
import PlatformSDK
import RegexBuilder
import SwiftUI

@main
enum IMessageNativeClientEntryPoint {
    static func main() {
        guard #available(macOS 14.0, *) else {
            fputs("imessage-native-client requires macOS 14 or later.\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }

        NSApplication.shared.setActivationPolicy(.regular)
        IMessageNativeClientApp.main()
    }
}

@available(macOS 14.0, *)
struct IMessageNativeClientApp: App {
    @NSApplicationDelegateAdaptor(NativeClientAppDelegate.self) private var appDelegate
    @StateObject private var model = NativeClientModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task {
                    await model.start()
                }
                .onDisappear {
                    Task { await model.shutdown() }
                }
        }
        .defaultSize(width: 1_100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@available(macOS 14.0, *)
final class NativeClientAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        installMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        focusMainWindow()
        DispatchQueue.main.async {
            self.focusMainWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
            self.focusMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func focusMainWindow() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        guard let window = app.windows.first(where: { $0.isVisible }) ?? app.windows.first else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "Quit iMessage Native Client",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

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

        NSApplication.shared.mainMenu = mainMenu
    }
}

@available(macOS 14.0, *)
@MainActor
final class NativeClientModel: ObservableObject, @unchecked Sendable {
    private static let accountID = "default"
    private static let refreshDebounceNanoseconds: UInt64 = 350_000_000

    @Published private(set) var permissionRows: [PermissionRow] = []
    @Published private(set) var threads: [PlatformSDK.Thread] = []
    @Published private(set) var messages: [PlatformSDK.Message] = []
    @Published private(set) var resolvedParticipantNames: [PlatformSDK.UserID: String] = [:]
    @Published private(set) var rawEventLog: [RawEventLogEntry] = []
    @Published var selectedThreadID: PlatformSDK.ThreadID?
    @Published private(set) var hasMoreOlderMessages = false
    @Published private(set) var isBootstrapping = false
    @Published private(set) var isLoadingThreads = false
    @Published private(set) var isLoadingMessages = false
    @Published private(set) var isLoadingOlderMessages = false
    @Published private(set) var isSending = false
    @Published private(set) var isEventWatching = false
    @Published var lastError: String?

    private var api: PlatformAPI?
    private var didStart = false
    private var didSubscribeToEvents = false
    private var liveRefreshTask: Task<Void, Never>?
    private var loadedMessagesThreadID: PlatformSDK.ThreadID?
    private var automationAuthorized: Bool?
    private let contactResolver = ContactDisplayResolver()

    var selectedThread: PlatformSDK.Thread? {
        guard let selectedThreadID else { return nil }
        return threads.first { $0.id == selectedThreadID }
    }

    var hasMessagesDataAccess: Bool {
        permissionRows.first { $0.kind == .messagesData }?.isAuthorized == true
    }

    var allRequiredPermissionsGranted: Bool {
        !permissionRows.isEmpty && permissionRows
            .filter { $0.kind != .contacts }
            .allSatisfy(\.isAuthorized)
    }

    var rawEventText: String {
        rawEventLog.map(\.json).joined(separator: "\n\n")
    }

    func displayTitle(for thread: PlatformSDK.Thread) -> String {
        if let title = thread.title?.nonEmptyString {
            return title
        }

        let participantNames = thread.participants.items
            .filter { $0.user.isSelf != true }
            .map { displayName(for: $0.user) }
            .filter { !$0.isEmpty }

        if !participantNames.isEmpty {
            return participantNames.joined(separator: ", ")
        }

        return thread.id
    }

    func displayName(forMessage message: PlatformSDK.Message) -> String {
        if message.isSender == true {
            return "You"
        }
        return displayName(forParticipantID: message.senderID)
    }

    func displayName(forParticipantID participantID: PlatformSDK.UserID) -> String {
        if let resolved = resolvedParticipantNames[participantID]?.nonEmptyString {
            return resolved
        }

        if let user = participantUser(for: participantID) {
            return displayName(for: user)
        }

        return participantID
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        isBootstrapping = true
        defer { isBootstrapping = false }

        do {
            let dataDirectory = try Self.ensureDataDirectory()
            IMessageHost.bootstrapWithOptions(
                dataDirPath: dataDirectory.path,
                verbose: false,
                useSecondaryInstance: true
            )
            api = try PlatformAPI(accountID: Self.accountID)
            subscribeToEventsIfNeeded()
            await refreshPermissions()
            if hasMessagesDataAccess {
                await refreshAll()
                await startEventWatching()
            }
        } catch {
            record(error)
        }
    }

    func shutdown() async {
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
        guard let api else { return }
        self.api = nil
        try? await api.dispose()
    }

    func refreshPermissions() async {
        let accessibility = MacPermissions.getAuthStatus(.accessibility)
        let contacts = MacPermissions.getAuthStatus(.contacts)
        let canReadMessages = (try? await MacPermissions.canAccessMessagesDir()) == true

        permissionRows = [
            PermissionRow(
                kind: .accessibility,
                title: "Accessibility",
                status: PermissionStatus(accessibility),
                detail: accessibility == .authorized
                    ? "This process can control Messages.app for sends and attachments."
                    : "Required for sending through Messages.app."
            ),
            PermissionRow(
                kind: .messagesData,
                title: "Messages Data",
                status: canReadMessages ? .authorized : .denied,
                detail: canReadMessages
                    ? "The client can read ~/Library/Messages/chat.db."
                    : "Required for loading conversations and live updates."
            ),
            PermissionRow(
                kind: .automation,
                title: "Automation",
                status: automationAuthorized.map { $0 ? .authorized : .denied } ?? .unknown,
                detail: automationAuthorized == true
                    ? "Apple Events access to Messages.app is available."
                    : "Click Request to prompt for Apple Events access."
            ),
            PermissionRow(
                kind: .contacts,
                title: "Contacts",
                status: PermissionStatus(contacts),
                detail: contacts == .authorized
                    ? "Contact lookups are available."
                    : "Optional, but improves display names when available."
            ),
        ]
    }

    func requestPermission(_ kind: PermissionKind) async {
        lastError = nil
        do {
            switch kind {
            case .accessibility:
                MacPermissions.askForAccessibilityAccess()
            case .contacts:
                _ = try await MacPermissions.askForContactsAccess()
                contactResolver.clearCache()
            case .messagesData:
                try await MacPermissions.askForMessagesDirAccess()
                if (try? await MacPermissions.canAccessMessagesDir()) != true {
                    MacPermissions.askForFullDiskAccess()
                }
            case .automation:
                try await MacPermissions.askForAutomationAccess()
                automationAuthorized = true
            }
        } catch {
            if kind == .automation {
                automationAuthorized = false
            }
            record(error)
        }

        await refreshPermissions()
        if hasMessagesDataAccess {
            await resolveContactsForLoadedThreads()
            await refreshAll()
            await startEventWatching()
        }
    }

    func refreshAll() async {
        await loadThreads(preserveSelection: true)
        await loadMessagesForSelection()
    }

    func loadThreads(preserveSelection: Bool) async {
        guard let api else { return }
        isLoadingThreads = true
        defer { isLoadingThreads = false }

        do {
            let page = try await api.getThreads(folderName: "normal", pagination: nil)
            threads = page.items
            await resolveContacts(for: page.items)
            if !preserveSelection || selectedThreadID == nil || !threads.contains(where: { $0.id == selectedThreadID }) {
                selectedThreadID = threads.first?.id
            }
        } catch {
            record(error)
        }
    }

    func loadMessagesForSelection() async {
        guard let api, let threadID = selectedThreadID else {
            messages = []
            loadedMessagesThreadID = nil
            hasMoreOlderMessages = false
            return
        }

        if loadedMessagesThreadID != threadID {
            messages = []
            hasMoreOlderMessages = false
        }

        isLoadingMessages = true
        defer { isLoadingMessages = false }

        do {
            let page = try await api.getMessages(threadID: threadID, pagination: nil)
            guard selectedThreadID == threadID else { return }
            loadedMessagesThreadID = threadID
            messages = Self.sortedMessages(page.items)
            hasMoreOlderMessages = page.hasMore
        } catch {
            record(error)
        }
    }

    @discardableResult
    func loadOlderMessages() async -> PlatformSDK.MessageID? {
        guard let api,
              let threadID = selectedThreadID,
              !isLoadingOlderMessages,
              hasMoreOlderMessages else {
            return nil
        }

        guard let oldestLoadedMessage = messages.first,
              let cursor = oldestLoadedMessage.cursor?.nonEmptyString else {
            hasMoreOlderMessages = false
            return nil
        }

        let scrollAnchorID = oldestLoadedMessage.id
        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }

        do {
            let page = try await api.getMessages(
                threadID: threadID,
                pagination: PlatformSDK.PaginationArg(cursor: cursor, direction: .before)
            )
            guard selectedThreadID == threadID else { return nil }

            let existingIDs = Set(messages.map(\.id))
            let olderMessages = page.items.filter { !existingIDs.contains($0.id) }
            messages = Self.sortedMessages(olderMessages + messages)
            hasMoreOlderMessages = page.hasMore
            return scrollAnchorID
        } catch {
            record(error)
            return nil
        }
    }

    func sendText(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let threadID = selectedThreadID else { return false }
        guard let api else { return false }

        isSending = true
        defer { isSending = false }

        do {
            _ = try await api.sendMessage(threadID: threadID, text: trimmed, filePath: nil, quotedMessageID: nil)
            await refreshAll()
            return true
        } catch {
            record(error)
            return false
        }
    }

    func chooseAndSendFile() async {
        guard let threadID = selectedThreadID, let api else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Send"
        panel.message = "Choose a file to send to this iMessage conversation."

        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        isSending = true
        defer { isSending = false }

        do {
            _ = try await api.sendMessage(threadID: threadID, text: nil, filePath: fileURL.path, quotedMessageID: nil)
            await refreshAll()
        } catch {
            record(error)
        }
    }

    func clearError() {
        lastError = nil
    }

    func clearRawEvents() {
        rawEventLog = []
    }

    private func subscribeToEventsIfNeeded() {
        guard !didSubscribeToEvents, let api else { return }
        didSubscribeToEvents = true
        api.subscribeToEvents { [weak self] events in
            await self?.handleServerEvents(events)
        }
    }

    private func handleServerEvents(_ events: [ServerEvent]) async {
        appendRawEvents(events)

        liveRefreshTask?.cancel()
        liveRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.refreshDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.refreshFromLiveEvent()
        }
    }

    private func appendRawEvents(_ events: [ServerEvent]) {
        rawEventLog.append(contentsOf: events.map { event in
            RawEventLogEntry(json: rawJSONString(for: event))
        })
    }

    private func refreshFromLiveEvent() async {
        await loadThreads(preserveSelection: true)
        await loadMessagesForSelection()
    }

    private func startEventWatching() async {
        guard !isEventWatching, let api else { return }
        do {
            try await api.startEventWatchingFromCurrentState()
            isEventWatching = IMessageHost.isEventWatching
        } catch {
            isEventWatching = false
            record(error)
        }
    }

    private func record(_ error: Error) {
        lastError = String(describing: error)
    }

    private func rawJSONString(for event: ServerEvent) -> String {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: event.jsonObject(),
                options: [.prettyPrinted, .sortedKeys]
            )
            if let string = String(data: data, encoding: .utf8) {
                return string
            }
            return try encodeJSON(event.jsonObject())
        } catch {
            return #"{"type":"event_encode_error"}"#
        }
    }

    private func displayName(for user: PlatformSDK.User) -> String {
        if user.isSelf == true {
            return "You"
        }

        if let resolved = resolvedParticipantNames[user.id]?.nonEmptyString {
            return resolved
        }

        return user.fallbackDisplayName
    }

    private func participantUser(for participantID: PlatformSDK.UserID) -> PlatformSDK.User? {
        if let selectedThread,
           let user = selectedThread.participants.items.first(where: { $0.user.id == participantID })?.user {
            return user
        }

        for thread in threads {
            if let user = thread.participants.items.first(where: { $0.user.id == participantID })?.user {
                return user
            }
        }

        return nil
    }

    private func resolveContactsForLoadedThreads() async {
        await resolveContacts(for: threads)
    }

    private func resolveContacts(for threads: [PlatformSDK.Thread]) async {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            resolvedParticipantNames = [:]
            return
        }

        var names = resolvedParticipantNames
        let users = threads.flatMap { $0.participants.items.map(\.user) }
        for user in users {
            if user.isSelf == true {
                names[user.id] = "You"
                continue
            }

            guard names[user.id] == nil, let handle = user.contactLookupHandle else { continue }
            if let displayName = contactResolver.displayName(for: handle) {
                names[user.id] = displayName
            }
        }
        resolvedParticipantNames = names
    }

    private static func ensureDataDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = base.appendingPathComponent("platform-imessage-native-client", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func sortedMessages(_ messages: [PlatformSDK.Message]) -> [PlatformSDK.Message] {
        messages.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp { return lhs.id < rhs.id }
            return lhs.timestamp < rhs.timestamp
        }
    }
}

@available(macOS 14.0, *)
struct PermissionRow: Identifiable {
    let kind: PermissionKind
    let title: String
    let status: PermissionStatus
    let detail: String

    var id: String { kind.rawValue }
    var isAuthorized: Bool { status == .authorized }
}

@available(macOS 14.0, *)
struct RawEventLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let json: String
}

@available(macOS 14.0, *)
enum PermissionKind: String, CaseIterable {
    case accessibility
    case messagesData
    case automation
    case contacts

    var requestTitle: String {
        switch self {
        case .accessibility, .automation:
            return "Request"
        case .messagesData:
            return "Grant Access"
        case .contacts:
            return "Allow"
        }
    }
}

@available(macOS 14.0, *)
enum PermissionStatus: Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unknown

    init(_ status: MacPermissionAuthStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        case .notDetermined:
            self = .notDetermined
        }
    }

    var label: String {
        switch self {
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not Determined"
        case .unknown:
            return "Not Verified"
        }
    }

    var systemImage: String {
        switch self {
        case .authorized:
            return "checkmark.circle.fill"
        case .denied, .restricted:
            return "xmark.circle.fill"
        case .notDetermined, .unknown:
            return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .authorized:
            return .green
        case .denied, .restricted:
            return .red
        case .notDetermined, .unknown:
            return .orange
        }
    }
}

@available(macOS 14.0, *)
struct ContentView: View {
    @EnvironmentObject private var model: NativeClientModel

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PermissionsView()
                        .padding()
                        .background(Color(nsColor: .windowBackgroundColor))

                    Divider()

                    ThreadListView()
                }
                .frame(width: 340)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                ConversationView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                RawEventsPanel()
                    .frame(width: 360)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let error = model.lastError {
                ErrorBanner(message: error) {
                    model.clearError()
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBootstrapping || model.isLoadingThreads)

                if model.isEventWatching {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                }
            }
        }
        .onChange(of: model.selectedThreadID) { _, _ in
            Task { await model.loadMessagesForSelection() }
        }
    }
}

@available(macOS 14.0, *)
struct PermissionsView: View {
    @EnvironmentObject private var model: NativeClientModel
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.permissionRows) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: row.status.systemImage)
                            .foregroundStyle(row.status.tint)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(row.title)
                                    .font(.headline)
                                Text(row.status.label)
                                    .font(.caption)
                                    .foregroundStyle(row.status.tint)
                            }
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if !row.isAuthorized || row.kind == .automation {
                            Button(row.kind.requestTitle) {
                                Task { await model.requestPermission(row.kind) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Label("Permissions", systemImage: model.allRequiredPermissionsGranted ? "checkmark.shield" : "exclamationmark.shield")
                Spacer()
                if model.isBootstrapping {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }
}

@available(macOS 14.0, *)
struct RawEventsPanel: View {
    @EnvironmentObject private var model: NativeClientModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Raw Events", systemImage: "curlybraces")
                    .font(.headline)

                Text("\(model.rawEventLog.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Clear") {
                    model.clearRawEvents()
                }
                .disabled(model.rawEventLog.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if model.rawEventLog.isEmpty {
                ContentUnavailableView(
                    "No Events Yet",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Incoming platform events will appear here as raw JSON.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RawEventCodeEditor(text: model.rawEventText)
            }
        }
    }
}

@available(macOS 14.0, *)
struct RawEventCodeEditor: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var editorText = ""
    @State private var position = CodeEditor.Position()
    @State private var messages = Set<TextLocated<Message>>()

    var body: some View {
        CodeEditor(
            text: $editorText,
            position: $position,
            messages: $messages,
            language: .jsonEvents
        )
        .environment(\.codeEditorTheme, colorScheme == .dark ? Theme.defaultDark : Theme.defaultLight)
        .environment(\.codeEditorLayoutConfiguration, CodeEditor.LayoutConfiguration(showMinimap: false, wrapText: true))
        .environment(
            \.codeEditorIndentationConfiguration,
            CodeEditor.IndentationConfiguration(
                preference: .preferSpaces,
                tabWidth: 2,
                indentWidth: 2,
                tabKey: .identsInWhitespace,
                indentOnReturn: false
            )
        )
        .onAppear {
            editorText = text
        }
        .onChange(of: text) { _, newValue in
            editorText = newValue
            position.verticalScrollPosition = .greatestFiniteMagnitude
        }
    }
}

@available(macOS 14.0, *)
struct ThreadListView: View {
    @EnvironmentObject private var model: NativeClientModel

    var body: some View {
        List(selection: $model.selectedThreadID) {
            ForEach(model.threads, id: \.id) { thread in
                ThreadRow(thread: thread)
                    .tag(thread.id as PlatformSDK.ThreadID?)
            }
        }
        .overlay {
            if model.isLoadingThreads && model.threads.isEmpty {
                ProgressView("Loading conversations…")
            } else if model.threads.isEmpty {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "message",
                    description: Text(model.hasMessagesDataAccess ? "Click Refresh to load Messages conversations." : "Grant Messages Data access to load conversations.")
                )
            }
        }
    }
}

@available(macOS 14.0, *)
struct ThreadRow: View {
    @EnvironmentObject private var model: NativeClientModel

    let thread: PlatformSDK.Thread

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.displayTitle(for: thread))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if thread.isUnread {
                    Circle()
                        .fill(.blue)
                        .frame(width: 7, height: 7)
                }

                Spacer(minLength: 8)

                if let timestamp = thread.timestamp {
                    Text(formatTimestamp(timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Text(thread.previewText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

@available(macOS 14.0, *)
struct ConversationView: View {
    @EnvironmentObject private var model: NativeClientModel

    var body: some View {
        if let thread = model.selectedThread {
            VStack(spacing: 0) {
                ConversationHeader(thread: thread)

                Divider()

                MessageListView()

                Divider()

                ComposerView()
                    .padding(10)
            }
        } else {
            ContentUnavailableView(
                "No Conversation Selected",
                systemImage: "message",
                description: Text("Select an existing iMessage conversation from the sidebar.")
            )
        }
    }
}

@available(macOS 14.0, *)
struct ConversationHeader: View {
    @EnvironmentObject private var model: NativeClientModel

    let thread: PlatformSDK.Thread

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.displayTitle(for: thread))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(thread.id)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@available(macOS 14.0, *)
struct MessageListView: View {
    @EnvironmentObject private var model: NativeClientModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if model.hasMoreOlderMessages {
                        OlderMessagesLoadRow(isLoading: model.isLoadingOlderMessages) {
                            Task { await loadOlderMessages(preservingPositionWith: proxy) }
                        }
                        .id("older-messages-loader")
                        .onAppear {
                            Task { await loadOlderMessages(preservingPositionWith: proxy) }
                        }
                    }

                    ForEach(model.messages, id: \.id) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .overlay {
                if model.isLoadingMessages && model.messages.isEmpty {
                    ProgressView("Loading messages…")
                } else if model.messages.isEmpty {
                    ContentUnavailableView(
                        "No Messages",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("No messages loaded for this conversation yet.")
                    )
                }
            }
        }
    }

    @MainActor
    private func loadOlderMessages(preservingPositionWith proxy: ScrollViewProxy) async {
        guard !model.isLoadingOlderMessages else { return }
        guard let anchorID = await model.loadOlderMessages() else { return }

        try? await Task.sleep(nanoseconds: 10_000_000)
        withAnimation(nil) {
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }
}

@available(macOS 14.0, *)
struct OlderMessagesLoadRow: View {
    let isLoading: Bool
    let load: () -> Void

    var body: some View {
        Button(action: load) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.circle")
                }
                Text(isLoading ? "Loading older messages…" : "Load older messages")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .help("Scroll here to load the next older page.")
    }
}

@available(macOS 14.0, *)
struct MessageBubble: View {
    @EnvironmentObject private var model: NativeClientModel

    let message: PlatformSDK.Message

    private var isSender: Bool {
        message.isSender == true
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if isSender { Spacer(minLength: 64) }

            VStack(alignment: isSender ? .trailing : .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if isSender {
                        Text(formatTimestamp(message.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Text(model.displayName(forMessage: message))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)

                    if !isSender {
                        Text(formatTimestamp(message.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let text = message.text?.nonEmptyString {
                        Text(text)
                            .textSelection(.enabled)
                    }

                    ForEach(message.attachments ?? [], id: \.id) { attachment in
                        AttachmentPill(attachment: attachment)
                    }

                    if message.text?.nonEmptyString == nil && (message.attachments ?? []).isEmpty {
                        Text("Unsupported message content")
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .foregroundStyle(isSender ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSender ? Color.blue : Color(nsColor: .controlBackgroundColor))
                )

                if let reactions = message.reactions, !reactions.isEmpty {
                    ReactionStrip(reactions: reactions)
                }
            }
            .frame(maxWidth: 560, alignment: isSender ? .trailing : .leading)

            if !isSender { Spacer(minLength: 64) }
        }
        .frame(maxWidth: .infinity)
    }
}

@available(macOS 14.0, *)
struct ReactionStrip: View {
    @EnvironmentObject private var model: NativeClientModel

    let reactions: [PlatformSDK.MessageReaction]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions, id: \.id) { reaction in
                ReactionPill(
                    reaction: reaction,
                    participantName: model.displayName(forParticipantID: reaction.participantID)
                )
            }
        }
    }
}

@available(macOS 14.0, *)
struct ReactionPill: View {
    let reaction: PlatformSDK.MessageReaction
    let participantName: String

    var body: some View {
        HStack(spacing: 4) {
            Text(reaction.displayGlyph)
            Text(participantName)
                .lineLimit(1)
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45))
        )
        .help(reaction.accessibilityDescription(participantName: participantName))
    }
}

@available(macOS 14.0, *)
struct AttachmentPill: View {
    let attachment: PlatformSDK.Attachment

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.iconName)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.fileName?.nonEmptyString ?? attachment.type.rawValue.capitalized)
                    .lineLimit(1)
                if let subtitle = attachment.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
        )
    }
}

@available(macOS 14.0, *)
struct ComposerView: View {
    @EnvironmentObject private var model: NativeClientModel
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                Task { await model.chooseAndSendFile() }
            } label: {
                Label("Attach", systemImage: "paperclip")
            }
            .disabled(model.selectedThreadID == nil || model.isSending)

            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit {
                    Task { await sendDraft() }
                }
                .disabled(model.selectedThreadID == nil || model.isSending)

            Button {
                Task { await sendDraft() }
            } label: {
                if model.isSending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Send")
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.selectedThreadID == nil || model.isSending)
        }
    }

    private func sendDraft() async {
        let sent = await model.sendText(draft)
        if sent {
            draft = ""
        }
    }
}

@available(macOS 14.0, *)
struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .lineLimit(3)
            Spacer()
            Button("Dismiss", action: dismiss)
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.ultraThinMaterial)
    }
}

private final class ContactDisplayResolver {
    private let store = CNContactStore()
    private var cache = [String: String?]()
    private let formatter = CNContactFormatter()

    func clearCache() {
        cache.removeAll()
    }

    func displayName(for handle: String) -> String? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return nil
        }

        if let cached = cache[handle] {
            return cached
        }

        let name = firstMatchingContact(for: handle).flatMap(format)
        cache[handle] = name
        return name
    }

    private func firstMatchingContact(for handle: String) -> CNContact? {
        let isEmail = handle.contains("@")
        let predicate = isEmail
            ? CNContact.predicateForContacts(matchingEmailAddress: handle)
            : CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: handle))

        return try? store.unifiedContacts(
            matching: predicate,
            keysToFetch: contactKeysToFetch(isEmail: isEmail)
        ).first
    }

    private func contactKeysToFetch(isEmail: Bool) -> [CNKeyDescriptor] {
        var keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            isEmail ? CNContactEmailAddressesKey as CNKeyDescriptor : CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ]
        keys.append(CNContactIdentifierKey as CNKeyDescriptor)
        return keys
    }

    private func format(_ contact: CNContact) -> String? {
        formatter.string(from: contact)?.nonEmptyString
            ?? contact.nickname.nonEmptyString
            ?? contact.organizationName.nonEmptyString
    }
}

private extension PlatformSDK.Thread {
    var previewText: String {
        if let text = partialLastMessage?.text?.nonEmptyString {
            return text
        }
        if partialLastMessage?.attachments?.isEmpty == false {
            return "Attachment"
        }
        return "No preview"
    }
}

private extension PlatformSDK.User {
    var fallbackDisplayName: String {
        fullName?.nonEmptyString
            ?? nickname?.nonEmptyString
            ?? username?.nonEmptyString
            ?? phoneNumber?.nonEmptyString
            ?? email?.nonEmptyString
            ?? id
    }

    var contactLookupHandle: String? {
        email?.nonEmptyString ?? phoneNumber?.nonEmptyString
    }
}

private extension PlatformSDK.Attachment {
    var iconName: String {
        switch type {
        case .img:
            return "photo"
        case .video:
            return "film"
        case .audio:
            return "waveform"
        case .unknown:
            return "doc"
        }
    }

    var subtitle: String? {
        var parts = [String]()
        if let mimeType = mimeType?.nonEmptyString {
            parts.append(mimeType)
        }
        if let fileSize {
            parts.append(formatBytes(fileSize))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

private extension PlatformSDK.MessageReaction {
    var displayGlyph: String {
        if emoji == true, let reaction = reactionKey.nonEmptyString {
            return reaction
        }

        switch reactionKey {
        case "heart":
            return "❤️"
        case "like":
            return "👍"
        case "dislike":
            return "👎"
        case "laugh":
            return "😂"
        case "emphasize":
            return "‼️"
        case "question":
            return "❓"
        case "sticker":
            return "🏷️"
        default:
            return reactionKey.nonEmptyString ?? "�"
        }
    }

    func accessibilityDescription(participantName: String) -> String {
        "\(participantName): \(reactionKey)"
    }
}

private extension Optional where Wrapped == String {
    var nonEmptyString: String? {
        switch self {
        case let .some(value):
            return value.nonEmptyString
        case .none:
            return nil
        }
    }
}

private extension String {
    var nonEmptyString: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func formatTimestamp(_ timestamp: PlatformSDK.Timestamp) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
    return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private extension LanguageConfiguration {
    static let jsonEvents = LanguageConfiguration(
        name: "JSON Events",
        supportsSquareBrackets: true,
        supportsCurlyBrackets: true,
        stringRegex: try! Regex<Substring>(#""(?:\\.|[^"\\])*""#),
        characterRegex: nil,
        numberRegex: try! Regex<Substring>(#"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"#),
        singleLineComment: nil,
        nestedComment: nil,
        identifierRegex: try! Regex<Substring>(#"[A-Za-z_][A-Za-z0-9_]*"#),
        operatorRegex: nil,
        reservedIdentifiers: ["true", "false", "null"],
        reservedOperators: [":", ","]
    )
}
