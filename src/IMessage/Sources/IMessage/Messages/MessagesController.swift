import AccessibilityControl
import AppKit
import Carbon.HIToolbox.Events
import Combine
import Contacts
import Darwin
import EmojiSPI
import IMDatabase
import Logging
import IMessageCore
import PlatformSDK
import WindowControl

private let log = Logger(imessageLabel: "messages-controller")
private let lifecycleLog = Logger(imessageLabel: "lifecycle")

let messagesBundleID = "com.apple.MobileSMS"
let isMontereyOrUp = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0))
let isVenturaOrUp = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0))
let isSonomaOrUp = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0))
let isSequoiaOrUp = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
let isTahoeOrUp = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))

private enum MessageAction {
    case react, reply, undoSend
    /// might've been added around macOS 15; unknown
    case edit

    var localized: String {
        switch self {
        case .react: return LocalizedStrings.react
        case .reply: return LocalizedStrings.reply
        case .undoSend: return LocalizedStrings.undoSend
        case .edit: return LocalizedStrings.editButton
        }
    }
}
private enum ThreadAction {
    case markAsRead, markAsUnread, delete, pin, unpin, showAlerts, hideAlerts

    var localized: String {
        switch self {
        case .markAsRead: return LocalizedStrings.markAsRead
        case .markAsUnread: return LocalizedStrings.markAsUnread
        case .delete: return LocalizedStrings.delete
        case .pin: return LocalizedStrings.pin
        case .unpin: return LocalizedStrings.unpin
        case .showAlerts: return LocalizedStrings.showAlerts
        case .hideAlerts: return LocalizedStrings.hideAlerts
        }
    }
}

enum ThreadAlertsActionIntent {
    case hide
    case show
}

struct ThreadAlertsActionLabel {
    let intent: ThreadAlertsActionIntent
    let isOn: Bool

    /// "Hide Alerts" means unmuted; a checked (", On") action reverses the state.
    var isMuted: Bool {
        switch (intent, isOn) {
        case (.hide, false), (.show, true): false
        case (.show, false), (.hide, true): true
        }
    }
}

func parseThreadAlertsActionLabel(
    _ actionName: String,
    hideAlertsLabel: String,
    showAlertsLabel: String
) -> ThreadAlertsActionLabel? {
    // AX custom action names may append Target/Selector metadata on later lines.
    let actionName = actionName.prefix { !$0.isNewline }
    func parse(_ label: String, intent: ThreadAlertsActionIntent) -> ThreadAlertsActionLabel? {
        let prefix = "Name:\(label)"
        guard actionName.hasPrefix(prefix) else { return nil }

        let suffix = actionName.dropFirst(prefix.count)
        if suffix.isEmpty {
            return ThreadAlertsActionLabel(intent: intent, isOn: false)
        }
        if suffix == ", On" {
            return ThreadAlertsActionLabel(intent: intent, isOn: true)
        }
        return nil
    }

    return parse(hideAlertsLabel, intent: .hide)
        ?? parse(showAlertsLabel, intent: .show)
}

struct MessageCell: Codable {
    let messageGUID: String
    let partIndex: Int?
    let axOffset: Int
    let cellID: String?
    let cellRole: String?
    let overlay: Bool
}

// used for outgoing communicate from observed AX events to `RunLoopConveyor`
//
// (we want to create window observations in response to windows being created,
// but we need a stable thread with a run loop for that)
private enum ConveyorEvent {
    case observeWindow(window: Accessibility.Element)
}

// external API is thread safe
final class MessagesController {
    private let app: NSRunningApplication
    let elements: MessagesAppElements

    private var lifecycleConveyor: RunLoopConveyor<ConveyorEvent>?
    private var lifecycleEventsTask: Task<Void, Never>?

    var cachedDatabase: IMDatabase?
    private var lifecycleObserver: LifecycleObserver
    private var lastOpenedThreadID: String?
    private var activityObservationCache = ThreadActivityObservationCache()

    private var windowCoordinator: WindowCoordinator
    private let keyPresser: KeyPresser
    let contacts = Contacts()
    private var reportErrorMessage: ((_ txt: String) -> Void)?

    let occlusionMonitor = OcclusionMonitor()

    // without expanding splitter, thread cells will not have custom ax actions (on monterey at least)
    private func expandSplitter() async throws {
        if try await elements.conversationsList.size().width < 99 { // width is 94 when in compact mode
            try await elements.splitter.increment()
        }
    }

    private func resetWindow() async {
        try? await elements.searchField.cancel()
        try? await expandSplitter()
        _ = try? await closeReplyTranscriptView()
    }

    @discardableResult
    static func openDeepLink(
        _ deepLink: MessagesDeepLink,
        activating: Bool = false,
        hiding: Bool = true,
        targeting app: NSRunningApplication? = nil
    ) async throws -> NSRunningApplication {
        try Task.checkCancellation()
        let url = try deepLink.url()
        let shouldHide = hiding && Defaults.shouldCoordinateWindow
        logDeepLinkOpen(url, activating: activating, hiding: shouldHide)
        if Preferences.useSecondaryMessagesInstance, let app {
            try MessagesInstanceTarget.sendDeepLink(url, to: app)
            if activating {
                app.activate()
            }
            // The window coordinator owns visibility during automation.
            return app
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activating
        configuration.hides = shouldHide
        // Wait for delivery before allowing another automation to select a thread.
        return try await NSWorkspace.shared.open(url, configuration: configuration)
    }

    private static func logDeepLinkOpen(_ url: URL, activating: Bool, hiding: Bool) {
        #if DEBUG
        let builtForDebugging = true
        #else
        let builtForDebugging = false
        #endif
        if Defaults.deepLinkTracingPII || builtForDebugging {
            log.debug("🚀 OPENING DEEP LINK: \(url) (activating? \(activating), hiding? \(hiding))")
        } else {
            log.debug("🚀 OPENING DEEP LINK (activating? \(activating), hiding? \(hiding))")
        }
    }

    @discardableResult
    private func openDeepLink(
        _ deepLink: MessagesDeepLink,
        activating: Bool = false,
        hiding: Bool = true
    ) async throws -> NSRunningApplication {
        lastOpenedThreadID = nil
        let app = try await Self.openDeepLink(deepLink, activating: activating, hiding: hiding, targeting: app)
        if let targetThreadID = deepLink.targetThreadID {
            lastOpenedThreadID = targetThreadID
        }
        return app
    }

    func isSameContact(_ a: String?, _ b: String?) -> Bool {
        guard let contacts, let a, let b else { return false }
        return contacts.fetchID(for: a) == contacts.fetchID(for: b)
    }

    private func getToFieldAddresses() async -> [String]? {
        let desc = try? await elements.toFieldPopupButton.localizedDescription()
        // unknown if other locales also use , as a separator
        return desc?.split(separator: ",").reversed().map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private func isComposeThreadSelected() async -> Bool {
        (try? await elements.toFieldPopupButton) != nil
    }

    // ignores the service (SMS or iMessage) and matches contact identifiers since it's merged in the UI
    private func assertSelectedThread(threadID: String) async throws {
        let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: threadID)
        guard Defaults.imessage.bool(forKey: DefaultsKeys.misfirePrevention) else {
            log.debug("NOT ensuring selected thread, misfire prevention is off: \(hashedThreadID)")
            return
        }

        let (_, _, addressToMatch) = try splitThreadID(threadID).orThrow(ErrorMessage("invalid threadID"))

        if Defaults.misfirePreventionTracing {
            log.debug("ensuring selected thread: \(hashedThreadID)")
        }

        func assertSelectedThreadViaLastChange(of date: Protected<Date?>, type: String, emoji: String) throws {
            guard let lastChange = date.read() else {
                throw ErrorMessage("misfire prevention: \(type) hasn't changed at all")
            }

            let waitingTime = "\((Date().timeIntervalSince(beganEnsuringThreadSelection) * 1000).rounded())ms"
            guard lastChange > beganEnsuringThreadSelection else {
                throw ErrorMessage("misfire prevention: \(type) hasn't changed yet since we started (\(beganEnsuringThreadSelection.iso8601Formatted)) (waited \(waitingTime) so far)")
            }

            log.debug("misfire prevention: \(emoji) \(type) changed \(lastChange.iso8601Formatted) (waited \(waitingTime) overall)")
        }

        var attempt = 0
        let beganEnsuringThreadSelection = Date()
        var hasLoggedAboutStrategy = false

        try await retry(withTimeout: 1.2, interval: 0.05) {
            attempt += 1
            do {
                let strategy = Defaults.imessage.string(forKey: DefaultsKeys.misfirePreventionFallbackStrategy)
                if Defaults.misfirePreventionTracing, !hasLoggedAboutStrategy {
                    log.debug("misfire prevention: using strategy \"\(strategy ?? "<nil>")\"")
                    hasLoggedAboutStrategy = true
                }

                switch strategy {
                case "title-prediction":
                    // TODO: when contacts details change, iMessage might not update the window title immediately.
                    // TODO: to resolve this, perhaps try jiggling the selection around if the title doesn't match
                    guard let windowTitle = try? await elements.mainWindow.title() else {
                        throw ErrorMessage("misfire prevention: couldn't read window title")
                    }

                    return try assertSelectedThreadByPredictingWindowTitle(desiredChatGUID: threadID, currentWindowTitle: windowTitle)
                case "focus-waiter":
                    // wait until Accessibility posts a notification staging that the focused element has changed.
                    try assertSelectedThreadViaLastChange(of: lifecycleObserver.lastFocusedUIElementChange, type: "focus", emoji: "👆")
                case "layout-waiter":
                    // wait until Accessibility posts a notification stating that the layout has changed.
                    // this happens very frequently, for example after changing the active chat (what we specifically want to know about)
                    // or even scrolling the chat list
                    try assertSelectedThreadViaLastChange(of: lifecycleObserver.lastLayoutChange, type: "layout", emoji: "📐")
                default:
                    var sleepInterval = Defaults.imessage.double(forKey: DefaultsKeys.misfirePreventionSleepInterval)
                    if sleepInterval <= 0.0 { sleepInterval = 0.5 }
                    log.warning("misfire prevention: no fallback strategy specified; sleeping for \(sleepInterval)s instead")
                    try await Task.sleep(forTimeInterval: sleepInterval)
                }
            } catch {
                if attempt > 5 { // 250ms
                    if let addresses = await getToFieldAddresses(), addresses.contains(where: { isSameContact($0, addressToMatch) }) {
                        log.error("assertSelectedThread: resorted to fallback in order to assert selection")
                        return
                    }
                }

                throw error
            }
        }
    }

    private func openThread(_ threadID: String) async throws {
        try? await self.clearTypingStatus()
        try await openDeepLink(try MessagesDeepLink(threadID: threadID, body: nil))
        try await assertSelectedThread(threadID: threadID)
    }

    init(windowCoordinator suppliedCoordinator: WindowCoordinator? = nil, reportErrorMessage: @escaping (_ txt: String) -> Void) async throws {
        self.reportErrorMessage = reportErrorMessage
        guard Accessibility.isTrusted() else {
            throw ErrorMessage("Beeper does not have Accessibility permissions")
        }

        let coordinator = try suppliedCoordinator ?? getBestWindowCoordinator()
        windowCoordinator = coordinator
        let launchedNewApplication: Bool

        if Preferences.useSecondaryMessagesInstance {
            log.info("launching secondary messages instance...")
            app = try await MessagesInstanceTarget.launchSecondaryInstance(
                initialDeepLink: MessagesDeepLink.compose.url(),
                activating: false,
                hiding: false
            )
            launchedNewApplication = true
        } else {
            let messagesApps = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)
            if let existingApp = try MessagesInstanceTarget.primaryInstance(in: messagesApps) {
                log.info("reusing existing messages...")
                app = existingApp
                launchedNewApplication = false
            } else {
                log.info("launching messages...")
                app = try await Self.openDeepLink(MessagesDeepLink.compose, activating: true)
                launchedNewApplication = true
            }
        }

        let selectedApp = app
        await MainActor.run {
            coordinator.app = selectedApp
        }

        do {
            try await selectedApp.waitForLaunch()
        } catch {
            // A partially initialized controller cannot clean up in deinit.
            if launchedNewApplication { selectedApp.terminate() }
            try? coordinator.dispose()
            throw error
        }

        elements = MessagesAppElements(runningApp: selectedApp, openDeepLink: { deepLink in
            try await Self.openDeepLink(deepLink, targeting: selectedApp)
        })

        keyPresser = KeyPresser(pid: selectedApp.processIdentifier)

        let observer = LifecycleObserver()
        lifecycleObserver = observer
        do {
            if Defaults.shouldCoordinateWindow { try windowCoordinator.prepareAfterLaunch() }
            setUpLifecycleConveyor(with: lifecycleObserver)

            guard await isValid else {
                // Diagnostics must remain passive; mainWindow can reopen the app.
                let frameValid = elements.getMainWindow()?.isFrameValid ?? false
                throw ErrorMessage("""
Initialized MessagesController in an invalid state:
appTerminated=\(app.isTerminated)
mwFrameValid=\(frameValid)
isMessagesAppResponsive=\(isMessagesAppResponsive)
""")
            }
            await resetWindow()
            if Defaults.shouldCoordinateWindow {
                try await windowCoordinator.automationDidComplete()
            }
        } catch WindowCoordinatorError.instanceInUse {
            dispose(terminateApp: Preferences.useSecondaryMessagesInstance)
            throw WindowCoordinatorError.instanceInUse
        } catch {
            dispose()
            throw error
        }
    }

    func setUpLifecycleConveyor(with observer: LifecycleObserver) {
        let thread = RunLoopConveyor<ConveyorEvent>(name: "IMessage Lifecycle RunLoop", oneTimeInitialization: { rlt in
            guard !self.isDisposed.read(), !rlt.isCancelled, !self.app.isTerminated else { return }
            do {
                try observer.beginObserving(app: self.elements.app)
            } catch {
                log.error("unable to perform initial observation of app: \(error)")
            }
            do {
                // Avoid the lane's window cache on the lifecycle thread.
                let window = try self.elements.getMainWindow().orThrow(ErrorMessage("main window not found"))
                try observer.beginObserving(window: window)
            } catch {
                log.error("unable to perform initial observation of main window: \(error)")
            }

            // this task doesn't run on the thread with the run loop
            let eventsTask = Task.detached { [weak self] in
                func debuggingStatus() -> String {
                    guard let self else { return "<controller deallocated>" }
                    guard !self.isDisposed.read(), !self.app.isTerminated else { return "<disposed or terminated>" }
                    let app = self.app

                    do {
                        guard let window = self.elements.getMainWindow() else { return "<no main window>" }
                        let frame = try window.frame()
                        let position = try window.position()
                        return "finishedLaunching=\(app.isFinishedLaunching), active=\(app.isActive), hidden=\(app.isHidden), terminated=\(app.isTerminated), AXframe=\(frame), AXpos=\(position)"
                    } catch {
                        return "<failed to query: \(error)>"
                    }
                }

                for await event in observer.events.subscribe() {
                    guard let self, !Task.isCancelled, !self.isDisposed.read(), !self.app.isTerminated else { return }
                    func printLifecycle(event: String) {
                        lifecycleLog.info("@@ AX: \(event) [\(debuggingStatus())]")
                    }

                    switch event {
                    case .appActivated:
                        printLifecycle(event: "APP activated")
                        self.activateMessages()
                    case .appDeactivated:
                        printLifecycle(event: "APP deactivated")
                        self.deactivateMessages()
                    case .appHidden: printLifecycle(event: "APP hidden")
                    case .appShown: printLifecycle(event: "APP shown")
                    case .anyObservedWindowMoved: printLifecycle(event: "WINDOW moved")
                    case .anyObservedWindowResized: printLifecycle(event: "WINDOW resized")
                    case .focusedUIElementChanged:
                        printLifecycle(event: "FOCUSED UI ELEMENT changed")
                        #if DEBUG
                        var focusedDescription = ""
                        try? self.elements.app.focusedElement().dumpXML(to: &focusedDescription, shallow: true)
                        printLifecycle(event: "FOCUSED: \(focusedDescription)")
                        #endif
                    case .windowCreated:
                        do {
                            printLifecycle(event: "WINDOW created")
                            // Refresh window observations without touching the lane's cache.
                            let window = try self.elements.getMainWindow().orThrow(ErrorMessage("main window not found"))
                            rlt.enqueue(.observeWindow(window: window))
                        } catch {
                            log.error("fetching mainWindow failed", error: error)
                        }
                    }
                }
            }
            self.isDisposed.withLock { disposed in
                // Disposal may have raced with observer setup.
                if disposed { eventsTask.cancel() }
                else { self.lifecycleEventsTask = eventsTask }
            }
        }, handlingWorkItemsWithinRunLoop: { event in
            guard !self.isDisposed.read(), !self.app.isTerminated else { return }
            guard case let .observeWindow(window) = event else { return }
            do {
                // swift gives a concurrency warning for capturing `observer` here but it
                // doesn't know that it's only ever touched from the runloop
                // thread (which this closure executes on)
                try observer.beginObserving(window: window)
            } catch {
                log.error("can't observe window \(window) in response to posted work item: \(error)")
            }
        })

        thread.qualityOfService = .userInteractive
        thread.start()
        self.lifecycleConveyor = thread
    }

    var isMessagesAppResponsive: Bool {
        (try? Process.isUnresponsive(app.processIdentifier)) == false
    }

    var isValid: Bool {
        get async {
            guard !isDisposed.read(), !app.isTerminated else { return false }
            return (try? await elements.mainWindow.isFrameValid) != nil && isMessagesAppResponsive
        }
    }

    func withAutomation<T>(_ operation: () async throws -> T) async throws -> T {
        log.info("withAutomation: preparing")
        cancelReplyTranscriptViewTask?.cancel()
        log.debug("withAutomation: making the app automatable")

        var prepared = false
        let result = await Result {
            if Defaults.shouldCoordinateWindow {
                if Defaults.shouldSuppressMessagesDock {
                    do { try await windowCoordinator.suppressDockPresence() }
                    catch { log.error("failed to hide Messages from Dock: \(error)") }
                }
                try windowCoordinator.prepareForAutomation()
                if let mainWindow = elements.getMainWindow() {
                    try await windowCoordinator.makeAutomatable(mainWindow)
                }
            }
            prepared = true
            return try await operation()
        }

        log.info("withAutomation: finished")
        if prepared {
            await automationDidComplete()
            // todo: this can be optimized by scheduling only after we trigger open the rtv instead of after each automation
            scheduleCancelReplyTranscriptView()
        }

        return try result.get()
    }

    private func automationDidComplete() async {
        guard Defaults.shouldCoordinateWindow else { return }
        do {
            try await windowCoordinator.automationDidComplete()
        } catch {
            log.error("failed to call automationDidComplete on window coordinator: \(String(reflecting: error))")
        }
    }

    private var cancelReplyTranscriptViewTask: Task<Void, Never>?

    private func scheduleCancelReplyTranscriptView() {
        // Clear the inherited lane token before enqueueing delayed cleanup.
        cancelReplyTranscriptViewTask = Task.detached { [weak self] in
            do {
                try await Task.sleep(forTimeInterval: 1.5)
                try await PlatformAPI.runOnMessagesControllerLane { [weak self] in
                    try Task.checkCancellation()
                    guard let self, !self.isDisposed.read(), !self.app.isTerminated else { return }
                    try await closeReplyTranscriptView()
                }
            } catch is CancellationError {
                return
            } catch {
                log.error("failed to close reply transcript view after automation: \(String(reflecting: error))")
            }
        }
    }

    private func messageAction(messageCell: Accessibility.Element, action: MessageAction) throws -> Accessibility.Action {
        // [press, AXScrollToVisible, show menu, Escape, scroll left by a page, scroll right by a page, React, Reply, Copy]
        // ["AXPress", "AXScrollToVisible", "AXShowMenu", "AXCancel", "AXScrollLeftByPage", "AXScrollRightByPage", "Name:React\nTarget:0x0\nSelector:(null)", "Name:Reply\nTarget:0x0\nSelector:(null)", "Name:Copy\nTarget:0x0\nSelector:(null)"]
        // non-AX actions are [React, Reply, Copy, Pin]
        // Pin is missing for non-links / Big Sur
        let allActions = try messageCell.supportedActions()
        return try allActions.first(where: { $0.name.value.hasPrefix("Name:\(action.localized)") })
            .orThrow(ErrorMessage("MessageAction.\(action) not found"))
    }

    private func directReactionAction(messageCell: Accessibility.Element, reaction: Reaction) throws -> Accessibility.Action? {
        try customMessageAction(messageCell: messageCell, named: reaction.directActionTitle)
    }

    private func customMessageAction(messageCell: Accessibility.Element, named actionTitle: String) throws -> Accessibility.Action? {
        let actionName = "Name:\(actionTitle)"
        return try messageCell.supportedActions().first {
            $0.name.value.hasPrefix("\(actionName)\n")
        }
    }

    private func openReactionPicker(messageCell: Accessibility.Element) async throws {
        let reactAction = try messageAction(messageCell: messageCell, action: .react)
        try reactAction() // performing this 2x will close reaction view

        if isSequoiaOrUp { // wait for animation
            try await Task.sleep(forTimeInterval: 0.75)
        }
    }

    private func openCustomEmojiReactionPicker(messageCell: Accessibility.Element) async throws {
        if let action = try customMessageAction(messageCell: messageCell, named: LocalizedStrings.addEmojiTapback) {
            try action()
            return
        }

        try await openReactionPicker(messageCell: messageCell)
        try await elements.addCustomEmojiReactionButton.press()
    }

    private func threadCellAction(threadCell: Accessibility.Element, namePrefix: String) throws -> Accessibility.Action? {
        try threadCell.supportedActions().first { $0.name.value.hasPrefix("Name:\(namePrefix)") }
    }

    private func threadCellAction(threadCell: Accessibility.Element, action: ThreadAction) throws -> Accessibility.Action? {
        try threadCellAction(threadCell: threadCell, namePrefix: action.localized)
    }

    private struct ThreadAlertsAction {
        let action: Accessibility.Action
        let label: ThreadAlertsActionLabel
    }

    private func threadAlertsActions(threadCell: Accessibility.Element) throws -> [ThreadAlertsAction] {
        try threadCell.supportedActions().compactMap { action in
            guard let label = parseThreadAlertsActionLabel(
                action.name.value,
                hideAlertsLabel: ThreadAction.hideAlerts.localized,
                showAlertsLabel: ThreadAction.showAlerts.localized
            ) else {
                return nil
            }
            return ThreadAlertsAction(action: action, label: label)
        }
    }

    private func triggerThreadCellAction(threadCell: Accessibility.Element, action: ThreadAction) throws {
        let action = try threadCellAction(threadCell: threadCell, action: action)
            .orThrow(ErrorMessage("ThreadAction.\(action) not found"))
        try action()
    }

    private func triggerThreadCellAction(threadID: String, action: ThreadAction) async throws {
        let threadCell = try await scrollAndGetSelectedThreadCell(threadID: threadID)
        try triggerThreadCellAction(threadCell: threadCell, action: action)
    }

    private func selectNextThreadAndScroll() async throws {
        let selectedThreadCell = await elements.selectedThreadCell
        // ctrlTab() acts differently, has no effect?
        try keyPresser.commandRightBracket() // scrolls to next thread cell, rare edge case: won't work for the last item
        try await retry(withTimeout: 0.5, interval: 0.05) { () async throws in // wait for hotkey to switch threads
            let nextThreadCell = try await elements.selectedThreadCell.orThrow(ErrorMessage("selectedThreadCell nil"))
            if let selectedThreadCell, nextThreadCell == selectedThreadCell {
                throw ErrorMessage("diff thread not selected")
            }
        }
    }

    /*
     other approaches tried here:
     #1:
     1. select not-in-viewport thread by opening deep link
     2. close all windows
     3. open deep link, thread will be in viewport but only when `.withoutActivation` isn't included in options
     ofc can't use bc can't activate app

     #2:
     try elements.selectedThreadCell?.scrollToVisible()
     only works for thread cells that are slightly offscreen/fully visible and for thread cells whose reference was taken _when_ they were in viewport
     elements.selectedThreadCell is an invalid reference if selected cell is offscreen

     #3
     1. keyPresser.command1
     2. open and get compose cell
     3. open target thread
     4. triggerThreadCellAction(threadCell: composeCell, action: .delete) // scrolls to wanted thread
     */
    private func scrollAndGetSelectedThreadCell(threadID: String) async throws -> Accessibility.Element {
        #if DEBUG
        let startTime = Date()
        defer { log.debug("scrollAndGetSelectedThreadCell took \(startTime.timeIntervalSinceNow * -1000)ms") }
        #endif

        // we assume thread is already selected

        let selectedCell = try await elements.selectedThreadCell.orThrow(ErrorMessage("selectedThreadCell nil"))
        if selectedCell.isInViewport { return selectedCell }

        try await selectNextThreadAndScroll()
        try await openThread(threadID)

        let selectedCellAfterScroll = try await elements.selectedThreadCell.orThrow(ErrorMessage("selectedThreadCell nil"))
        if selectedCellAfterScroll.isInViewport { return selectedCellAfterScroll }
        throw ErrorMessage("threadCell not found")
    }

    // performs `perform` while the Messages window is unhidden
    private func withActivation(
        openBefore: MessagesDeepLink?,
        perform: () async throws -> Void
    ) async throws {
        if let openBefore {
            #if DEBUG
            let openBeforeURL = try openBefore.url()
            log.debug("withActivation: opening before performing: \(openBeforeURL.absoluteString)")
            #endif
            try await openDeepLink(openBefore)
        }

        try await perform()
    }

    private func withMessageCell(threadID: String, messageCell: MessageCell, action: (_ cell: Accessibility.Element) async throws -> Void) async throws {
        log.debug("withMessageCell (messageCell=\(messageCell))")

        let deepLink = MessagesDeepLink.message(
            guid: messageCell.messageGUID,
            partIndex: messageCell.partIndex,
            overlay: messageCell.overlay,
            threadID: threadID
        )

        // without closing reply transcript, non-overlay deep link won't select the message
        if !messageCell.overlay {
            _ = try? await closeReplyTranscriptView()
        }

        try await withActivation(openBefore: deepLink) {
            try await assertSelectedThread(threadID: threadID)

            // we don't close transcript view here because when reacting, closing it will undo the reaction
            // defer {
            //     if messageCell.overlay {
            //         // alt: try? sendKeyPress(key: CGKeyCode(kVK_Escape))
            //         try await closeReplyTranscriptViewAndWait()
            //     }
            // }
            if messageCell.overlay {
                try await waitUntilReplyTranscriptVisible()
            }
            guard let (selected, transcript) = (try await retry(withTimeout: 1, interval: 0.2) { () async throws -> (cell: Accessibility.Element, transcript: Accessibility.Element)? in
                let transcript: Accessibility.Element
                let cell: Accessibility.Element?
                if messageCell.overlay {
                    transcript = try await elements.replyTranscriptView
                    cell = try MessagesAppElements.firstMessageCell(in: transcript)
                } else {
                    transcript = try await elements.transcriptView
                    cell = try MessagesAppElements.firstSelectedMessageCell(in: transcript)
                }
                guard let cell else {
                    throw ErrorMessage("message cell nil")
                }
                guard cell.isInViewport else { throw ErrorMessage("message cell not in viewport") }
                return (cell, transcript)
            }) else {
                throw ErrorMessage("Could not find message cell")
            }
            let targetCell: Accessibility.Element
            if messageCell.axOffset == 0 {
                targetCell = selected
            } else {
                let containerCell = try selected.parent()
                let containerFrame = try containerCell.frame()
                let containerCells = try MessagesAppElements.messageContainerCells(
                    in: transcript
                )

                guard let idx: Int = containerCells.firstIndex(where: { (try? $0.frame()) == containerFrame }) else {
                    throw ErrorMessage("Could not find target message cell")
                }

                let targetIndex: Int = (idx - messageCell.axOffset)

                guard targetIndex >= 0, targetIndex < containerCells.count else {
                    throw ErrorMessage("Desired index \(targetIndex) is out of bounds (array count: \(containerCells.count))")
                }

                targetCell = try containerCells[targetIndex].children[0]
            }

            if let cellRole = messageCell.cellRole, let role = try? targetCell.role() {
                guard role == cellRole else {
                    log.debug("Expected cell role \(cellRole), got \(role)")
                    throw ErrorMessage("Cell role mismatch")
                }
            }
            if let cellID = messageCell.cellID, let id = try? targetCell.identifier() {
                guard id == cellID else {
                    log.debug("Expected cell id \(cellID), got \(id)")
                    throw ErrorMessage("Cell id mismatch")
                }
            }
            try await action(targetCell)
        }
    }

    func setReaction(threadID: String, messageCell: MessageCell, reaction: Reaction, on: Bool) async throws {
        let startTime = Date()
        defer { log.debug("setReaction took \(startTime.timeIntervalSinceNow * -1000)ms") }

        try await withAutomation {
            try await withMessageCell(threadID: threadID, messageCell: messageCell) {
                if let directAction = try directReactionAction(messageCell: $0, reaction: reaction) {
                    try directAction()
                    return
                }

                if case let .custom(emoji) = reaction, on {
                    guard isSequoiaOrUp else { throw ErrorMessage("Custom emoji reactions are only supported on macOS 15 or later") }
                    // TODO: support being able to pick a skin tone
                    let search: CharacterPickerSearch
                    let supportsSkinToneVariants: Bool
                    do {
                        search = try CharacterPickerSearch(finding: emoji)
                        supportsSkinToneVariants = try EMFEmojiToken(character: emoji).supportsSkinToneVariants
                    } catch {
                        throw ReactionSearchError(emoji: emoji, underlying: error)
                    }
                    try await openCustomEmojiReactionPicker(messageCell: $0)
                    let searchField = try await retry(withTimeout: 1.0, interval: 0.05) { () async throws in
                        try await elements.characterPickerSearchField
                    }
                    try searchField.value(assign: search.query)
                    try await Task.sleep(forTimeInterval: 0.75) // wait for search
                    // focus the matrix (tab also seems to work for this? full keyboard access needed maybe?)
                    try keyPresser.downArrow()
                    // 6 columns in the character picker matrix
                    let (downArrows, rightArrows) = search.position.quotientAndRemainder(dividingBy: 6)
                    // navigate to the emoji
                    for _ in 0..<downArrows { try keyPresser.downArrow(); try await Task.sleep(forTimeInterval: 0.05) }
                    for _ in 0..<rightArrows { try keyPresser.rightArrow(); try await Task.sleep(forTimeInterval: 0.05) }
                    try await Task.sleep(forTimeInterval: 0.1) // wait for selection
                    try keyPresser.return() // select
                    if supportsSkinToneVariants {
                        try await Task.sleep(forTimeInterval: 0.2) // wait for skin tone picker to appear
                        try keyPresser.return() // always select default skin tone
                    }
                    return
                }

                try await openReactionPicker(messageCell: $0)

                let btn = try await { () async throws -> Accessibility.Element in
                    if isSequoiaOrUp {
                        return try await elements.tapbackPickerCollectionView.children()
                            .first {
                                // standard: "ha", "thumbsUp", etc. custom: emoji string
                                let identifier = try? $0.identifier()
                                return identifier == reaction.idOrEmoji
                            }
                            .orThrow(ErrorMessage("Could not find \(on ? "react" : "unreact") button"))
                    }

                    let idx = reaction.index!
                    let buttons = try await elements.reactButtons
                    guard buttons.count > idx else {
                        throw ErrorMessage("reactButtons count=\(buttons.count)")
                    }

                    return buttons[idx]
                }()

                try await retry(withTimeout: 1.2, interval: 0.1) { () async throws in
                    let isSelected = try btn.isSelected()
                    if isSelected != on {
                        try btn.press()
                        log.debug("Reaction: \(Result { try btn.localizedDescription() }) \(Result { try btn.isSelected() })")
                        guard try btn.isSelected() == on else {
                            throw ErrorMessage("Could not react")
                        }
                    }
                }
            }
        }
    }

    func undoSend(threadID: String, messageCell: MessageCell) async throws {
        guard isVenturaOrUp else {
            throw ErrorMessage("!isVenturaOrUp")
        }

        let startTime = Date()
        defer { log.debug("undoSend took \(startTime.timeIntervalSinceNow * -1000)ms") }

        try await withAutomation {
            try await withMessageCell(threadID: threadID, messageCell: messageCell) {
                let undoSendAction = try messageAction(messageCell: $0, action: .undoSend)
                try undoSendAction()
            }
        }
    }

    func loadAttachment(threadID: String, messageCell: MessageCell) async throws {
        let startTime = Date()
        defer { log.debug("loadAttachment took \(startTime.timeIntervalSinceNow * -1000)ms") }

        try await withAutomation {
            try await withMessageCell(threadID: threadID, messageCell: messageCell) { messageCell in
                try messageCell.press()
            }
        }
    }

    // NOTE: message editing works even when the window is ordered out
    func editMessage(threadID: String, messageCell: MessageCell, newText: String) async throws {
        guard isVenturaOrUp else {
            throw ErrorMessage("!isVenturaOrUp")
        }

        let startTime = Date()
        defer { log.debug("editMessage took \(startTime.timeIntervalSinceNow * -1000)ms") }

        func tryPressingCancelEditButton() async throws {
            if let cancelEditButton = try? await elements.cancelEditButton {
                // this is seemingly always available, even when you're not editing
                log.debug("pressing cancel edit button")

                do {
                    try cancelEditButton.press()
                } catch {
                    log.error("failed to press cancel edit button, continuing anyway: \(error)")
                    return
                }
                try await Task.sleep(forTimeInterval: 0.5)
            } else {
                log.debug("(no cancel edit button was found)")
            }
        }

        func assignAndCommitEdit() async throws {
            try await Task.sleep(forTimeInterval: Defaults.imessage.double(forKey: DefaultsKeys.editingDelayBeforeReplacing))
            let editableMessageField = try await elements.editableMessageField
            try await assignToMessageField(editableMessageField, text: newText)

            try await Task.sleep(forTimeInterval: Defaults.imessage.double(forKey: DefaultsKeys.editingDelayBeforeFocusing))
            try await focusMessageField(editableMessageField)

            try await Task.sleep(forTimeInterval: Defaults.imessage.double(forKey: DefaultsKeys.editingDelayBeforePressingMenuItem))
            try keyPresser.return() // elements.editConfirmButton.press() works only after a 0.2s+ delay
            // todo: wait for it to disappear
        }

        let onError = { (attempt: Int, error: (any Error)?) async throws in
            let errorDescription = String(describing: error)
            log.warning("failed to edit (attempt \(attempt)), pressing cancel edit button and retrying: \(errorDescription)")
            try await tryPressingCancelEditButton()
        }

        try await withAutomation {
            try await tryPressingCancelEditButton()

            try await withMessageCell(threadID: threadID, messageCell: messageCell) { messageCell in
                if let editAction = try? messageAction(messageCell: messageCell, action: .edit) {
                    log.debug("found \"Edit\" message action")

                    try await retry(withTimeout: 6.0, interval: 2.0, {
                        try editAction()
                        try await assignAndCommitEdit()
                    }, onError: onError)

                    return
                }

                // this doesn't work reliably:
                // try $0.press(); $0.isFocused(assign: true); $0.isSelected(assign: true); keyPresser.commandE()
                try messageCell.showMenu()
                // retrying this too rapidly can cause the floating editor to appear more than once?
                try await retry(withTimeout: 6.0, interval: 2.0, {
                    try await Task.sleep(forTimeInterval: Defaults.imessage.double(forKey: DefaultsKeys.editingDelayBeforePressingMenuItem))
                    try await elements.menuEditItem.press()

                    try await assignAndCommitEdit()
                }, onError: onError)
            }
        }
    }

    // this only works when the messages.app window has been activated at least once
    // can randomly stop working. a reactivation of messages.app may fix (unhandled)
    private func markAsReadWithPressHack(threadID: String) async throws {
        #if DEBUG
        let startTime = Date()
        defer { log.debug("markAsReadWithPressHack took \(startTime.timeIntervalSinceNow * -1000)ms") }
        #endif

        try await openThread(threadID)
        let threadCell = try await scrollAndGetSelectedThreadCell(threadID: threadID)
        // select any another cell and then come back
        try await selectNextThreadAndScroll()
        // scrollToVisible is needed since sometimes the thread cell can be behind the search input field causing .press() to focus the input field instead
        try threadCell.scrollToVisible()
        try threadCell.press()
        try? await assertSelectedThread(threadID: threadID)
    }

    /*
     uses 5 methods:
     1. for ventura and up: hotkey                                           (reliable)
     lower than ventura:
     2. for pinned threads: mark-read action                                 (reliable)
     3. when less than 9 pinned threads: pin thread, #2, unpin               (reliable)
     4. threadCell.press() action hack                                       (unreliable)
     */
    func toggleThreadRead(threadID: String, read: Bool) async throws {
        let startTime = Date()
        defer { log.debug("toggleThreadRead took \(startTime.timeIntervalSinceNow * -1000)ms") }

        let deepLink = try MessagesDeepLink(threadID: threadID, body: nil)

        try await withAutomation {
            try await withActivation(openBefore: deepLink) {
                try await assertSelectedThread(threadID: threadID)
                if isVenturaOrUp {
                    return try keyPresser.commandShiftU()
                }
                let action = read ? ThreadAction.markAsRead : ThreadAction.markAsUnread
                if Defaults.isSelectedThreadCellPinned() {
                    try await triggerThreadCellAction(threadID: threadID, action: action)
                } else if let pinnedCount = Defaults.pinnedThreadsCount(), pinnedCount < 9 {
                    func restorePinsIfNecessary() async {
                        guard Defaults.pinnedThreadsCount() != pinnedCount else { return }
                        let deadline = Date().addingTimeInterval(0.3)
                        repeat {
                            log.debug("retrying unpin")
                            if (try? await triggerThreadCellAction(threadID: threadID, action: .unpin)) != nil {
                                break
                            }
                            try? await Task.sleep(forTimeInterval: 0.05)
                        } while Date() < deadline
                        if Defaults.pinnedThreadsCount() != pinnedCount {
                            reportErrorMessage?("couldn't restore pins \(Defaults.pinnedThreadsCount() ?? -1) != \(pinnedCount)")
                        }
                    }
                    do {
                        try await triggerThreadCellAction(threadID: threadID, action: .pin)
                        // after pin/unpin elements.selectedThreadCell is nil because no cells are selected
                        // openThread ensures scroll logic isn't executed
                        try await openThread(threadID)
                        let threadCell = try await scrollAndGetSelectedThreadCell(threadID: threadID)
                        defer { try? triggerThreadCellAction(threadCell: threadCell, action: .unpin) }
                        try triggerThreadCellAction(threadCell: threadCell, action: action)
                    } catch {
                        await restorePinsIfNecessary()
                        throw error
                    }
                    await restorePinsIfNecessary()
                } else {
                    try await markAsReadWithPressHack(threadID: threadID)
                }
            }
        }
    }

    func muteThread(threadID: String, muted shouldMute: Bool) async throws {
        #if DEBUG
        let startTime = Date()
        defer { log.debug("muteThread took \(startTime.timeIntervalSinceNow * -1000)ms") }
        #endif

        let deepLink = try MessagesDeepLink(threadID: threadID, body: nil)

        func dndMuteState() throws -> Bool? {
            guard let mutedThreadIDs = PlatformAPI.permanentDNDThreadIDs(),
                  let chat = try db.mappedThreadRow(guid: threadID),
                  let dndIdentifier = ThreadMapper.dndIdentifier(for: chat) else { return nil }
            return mutedThreadIDs.contains(dndIdentifier)
        }

        try await withAutomation {
            try await withActivation(openBefore: deepLink) {
                try await assertSelectedThread(threadID: threadID)
                let selectedThreadCell = try await scrollAndGetSelectedThreadCell(threadID: threadID)
                let actions = try threadAlertsActions(threadCell: selectedThreadCell)

                let inferredStates = Set(actions.map(\.label.isMuted))
                let labelMuteState = inferredStates.count == 1 ? inferredStates.first : nil
                // Live AX labels update before the DND preferences do.
                guard let isMuted = try labelMuteState ?? dndMuteState() else {
                    throw ErrorMessage("Could not determine whether thread alerts are hidden")
                }
                log.debug("muteThread: isMuted=\(isMuted), shouldMute=\(shouldMute)")

                guard isMuted != shouldMute else { return }

                let action = try (actions.first { $0.label.isMuted == isMuted } ?? actions.first)
                    .orThrow(ErrorMessage("Hide Alerts / Show Alerts action not found"))
                    .action
                try action()
                // Wait for the toggle before accepting another mute request.
                try await retry(withTimeout: 2, interval: 0.05) {
                    let labels = try threadAlertsActions(threadCell: selectedThreadCell)
                    let states = Set(labels.map(\.label.isMuted))
                    let observedState = try (states.count == 1 ? states.first : nil) ?? dndMuteState()
                    guard observedState == shouldMute else {
                        throw ErrorMessage("Waiting for thread alerts to reflect requested mute state")
                    }
                }
            }
        }
    }

    func deleteThread(threadID: String) async throws {
        #if DEBUG
        let startTime = Date()
        defer { log.debug("deleteThread took \(startTime.timeIntervalSinceNow * -1000)ms") }
        #endif

        let deepLink = try MessagesDeepLink(threadID: threadID, body: nil)

        try await withAutomation {
            try await withActivation(openBefore: deepLink) {
                try await assertSelectedThread(threadID: threadID)
                try await triggerThreadCellAction(threadID: threadID, action: .delete)
                try await elements.alertSheetDeleteButton.press()
            }
        }
    }

    func sendTypingStatus(threadID: String) async throws {
        // a space is enough to send a typing indicator, while ensuring that
        // users can't accidentally hit return to send a single-char message
        // (since Messages special-cases space-only messages). The NUL byte
        // is another option that doesn't get sent to the server, but it
        // shows up client-side as a ghost message.
        let deepLink = try MessagesDeepLink(threadID: threadID, body: " ")

        try await withAutomation {
            _ = try await openDeepLink(deepLink)
        }
    }

    func clearTypingStatus() async throws {
        try await elements.messageBodyField.value(assign: "")
    }

    private func focusMessageField(_ messageField: Accessibility.Element) async throws {
        do {
            try await retry(withTimeout: 0.8, interval: 0.1) { () async throws in
                // this doesn't ever focus in compose thread for some reason
                try messageField.isFocused(assign: true)
                if await isComposeThreadSelected() { return }
                if try !messageField.isFocused() {
                    try messageField.press()
                }
                guard try messageField.isFocused() else {
                    throw ErrorMessage("Could not focus message field")
                }
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            return
        }
    }

    private func messageFieldValue(_ messageField: Accessibility.Element) throws -> String {
        do {
            if isVenturaOrUp {
                let value = try (messageField.value() as? NSAttributedString)
                    .orThrow(ErrorMessage("couldn't cast message field value to NSAttributedString"))
                return value.string
            }
            return try (messageField.value() as? String)
                .orThrow(ErrorMessage("couldn't cast message field value to String"))
        } catch {
            if error is AccessibilityError, let axError = error as? AccessibilityError, axError.code == .noValue { return "" }
            throw error
        }
    }

    private func assignToMessageField(_ messageField: Accessibility.Element, text: String) async throws {
        try await retry(withTimeout: 1, interval: 0.1) { () async throws in
            try messageField.value(assign: text)
            // we don't test if messageFieldValue() == text here because a few ms later, messageFieldValue will likely change if text has @mentions
            let charCountResult = Result { try messageField.noOfChars() }
            let atCount = text.filter { $0 == "@" }.count
            log.debug("assignToMessageField: \(charCountResult) \(atCount) \(text.count)")
            guard case let .success(charCount) = charCountResult,
                  charCount > 0,
                  // the assigned value could have X fewer characters than `text`, where X = the number of occurrences of "@"
                  (text.count - charCount) <= atCount
            else {
                throw ErrorMessage("Could not assign value to message field")
            }
        }
    }

    private func sendMessageInField(_ messageField: Accessibility.Element) async throws {
        log.debug("\(#function): focusing field and pressing return")
        try await focusMessageField(messageField) // focus is partially redundant, hitting enter without focus works too unless another text field is focused
        try keyPresser.return() // in some random cases hitting enter will not send the message (even without automation), until the message input is clicked/focused
        log.debug("\(#function): completed initial attempt")

        do {
            log.debug("\(#function): will now attempt to verify the send")

            try await retry(withTimeout: 1.5, interval: 0.1) { () async throws in
                let message = try messageFieldValue(messageField)
                if !message.isEmpty {
                    let hasNewline = message.hasSuffix("\n")
                    throw ErrorMessage("couldn't verify message send\(hasNewline ? " (extra newline)" : "")")
                }
            } onError: { attempt, error in
                if let error {
                    log.warning("\(#function): couldn't verify the send (attempt \(attempt)): \(error)")
                }

                if attempt == 2 {
                    log.debug("\(#function): focusing and pressing enter again")

                    try await self.focusMessageField(messageField)
                    try? self.keyPresser.return()
                } else if attempt == 6 {
                    log.debug("\(#function): focusing and pressing enter again (alt. strategy)")

                    try? messageField.press()
                    try? self.keyPresser.return()
                }
            }

            log.debug("\(#function): successfully verified the send")
        } catch let error as CancellationError {
            throw error
        } catch {
            // if we can't verify the message send, then blindly swallow the error and assume that the send went through; don't let
            // it bubble to the TypeScript side, which will retry (since we specifically do that for failed message sends). this
            // has caused duplicate message sends.
            //
            // user hitting `cannotComplete` repeatedly when we try to fetch the message field value:
            // https://linear.app/beeper/issue/DESK-14971/issue-parent-imessages-sometimes-send-more-than-once
            // https://linear.app/beeper/issue/DESK-16318/mrmangoes-messages-sending-multiple-times#comment-4a743fdf
            log.warning("\(#function): timed out retrying send verification, proceeding anyways: \(error)")
        }
    }

    @discardableResult
    private func closeReplyTranscriptView() async throws -> Bool {
        guard let rtv = try? await elements.replyTranscriptView else { return false }
        log.debug("calling replyTranscriptView.cancel()")
        try rtv.cancel()
        return true
    }

    private func closeReplyTranscriptViewAndWait() async throws {
        guard try await closeReplyTranscriptView() else { return }
        try await retry(withTimeout: 1.2, interval: 0.1) { () async throws in
            guard let pValue = try? await elements.messageBodyField.placeholderValue(),
                  pValue == LocalizedStrings.imessage || pValue == LocalizedStrings.textMessage else {
                throw ErrorMessage("replyTranscriptView visible")
            }
        }
        try await Task.sleep(forTimeInterval: 0.4) // wait for animation still
    }

    private func waitUntilReplyTranscriptVisible() async throws {
        log.debug("waitUntilReplyTranscriptVisible")
        try await retry(withTimeout: 1.2, interval: 0.1) { () async throws in
            guard let pValue = try? await elements.messageBodyField.placeholderValue(),
                  pValue != LocalizedStrings.imessage && pValue != LocalizedStrings.textMessage else {
                throw ErrorMessage("replyTranscriptView not visible")
            }
        }
    }

    private func sendReplyWithoutOverlay(threadID: String, quotedMessage: MessageCell, text: String?, filePath: String?) async throws {
        try await withMessageCell(threadID: threadID, messageCell: quotedMessage) {
            let replyAction = try messageAction(messageCell: $0, action: .reply)
            try replyAction()
            let messageField = try await elements.messageBodyField
            if let text {
                try await assignToMessageField(messageField, text: text)
                try await sendMessageInField(messageField)
            } else if let filePath {
                try await pasteFileInBodyFieldAndSend(messageField, filePath: filePath)
            }
        }
    }

    // this method has a lot of combinations, test carefully
    func sendMessage(threadID: String?, addresses: [String]?, text: String?, filePath: String?, quotedMessage: MessageCell?) async throws {
        let startTime = Date()
        defer { log.debug("sendMessage took \(startTime.timeIntervalSinceNow * -1000)ms") }

        if !Defaults.disableOSAFastPath, !Preferences.useSecondaryMessagesInstance, let threadID, quotedMessage == nil { // fast path using OSA
            do {
                if let text {
                    if !text.contains("@"), !text.containsLink { // no mentions and no links
                        // skipping the deeplink and thread ID check is safe since we're simply clearing the textfield.
                        // there are two possible scenarios:
                        // A. [expected] we're in the correct chat (same thread ID as the one we're sending a message to using OSA). we can safely clear the textfield since we've sent the message and we don't need to show a typing indicator.
                        // B. [unexpected] we're in a different chat than the one we're sending the message in, in which case we should clear the textfield anyway since we don't want to send a typing indicator.
                        // in both cases, it is necessary to clear the typing indicator.
                        try? await clearTypingStatus()
                        try OSA.send(threadID: threadID, text: text)
                        return
                    }
                } else if let filePath {
                    // we don't always use OSA for files bc send file is randomly unreliable
                    if !isMontereyOrUp { // messages.app in big sur doesn't correctly paste the file
                        // safe for the same reasons as the message above
                        try? await clearTypingStatus()
                        try OSA.send(threadID: threadID, filePath: filePath)
                        return
                    }
                }
            } catch {
                reportErrorMessage?("osa err: \(error)")
                // fall back to regular send
            }
        }

        let deepLink: MessagesDeepLink
        if let quotedMessage, let threadID {
            deepLink = MessagesDeepLink.message(
                guid: quotedMessage.messageGUID,
                partIndex: quotedMessage.partIndex,
                overlay: quotedMessage.overlay,
                threadID: threadID
            )
        } else if let quotedMessage { // todo: this branch shouldn't exist, threadID can be fetched from message guid
            deepLink = MessagesDeepLink.message(
                guid: quotedMessage.messageGUID,
                partIndex: quotedMessage.partIndex,
                overlay: quotedMessage.overlay
            )
        } else if let threadID {
            deepLink = try MessagesDeepLink(threadID: threadID, body: text)
        } else if let addresses {
            deepLink = MessagesDeepLink.addresses(addresses, body: text)
        } else {
            throw ErrorMessage("not implemented")
        }

        try await withAutomation {
            // this isn't reliable so we use pasteFileInBodyFieldAndSend:
            // if let filePath {
            //     guard let address = threadIDToAddress(threadID) else { throw ErrorMessage("invalid threadID") }
            //     try withAllWindowsClosed {
            //         try DraftsManager.saveDraft(address: String(address), filePath: filePath)
            //     }
            // }
            if let quotedMessage, !quotedMessage.overlay, let threadID {
                try await sendReplyWithoutOverlay(threadID: threadID, quotedMessage: quotedMessage, text: text, filePath: filePath)
                return
            }

            if quotedMessage == nil { try? await closeReplyTranscriptViewAndWait() } // needed even when opening deep link

            try await withActivation(openBefore: deepLink) {
                if let threadID { try await assertSelectedThread(threadID: threadID) }

                if quotedMessage != nil {
                    try await waitUntilReplyTranscriptVisible()
                }
                if await isComposeThreadSelected() {
                    // since this is a new thread not in contacts, it may take a while for messages app to resolve that the address is imessage and not just sms
                    log.debug("waiting 3s for address to resolve")
                    try await Task.sleep(forTimeInterval: 3)
                }

                let messageField = try await elements.messageBodyField
                if let text {
                    if quotedMessage != nil { // text has to be manually assigned when quoted since ?body in deep link doesn't take any effect
                        try await assignToMessageField(messageField, text: text)
                    }
                    try await sendMessageInField(messageField)
                } else if let filePath {
                    try await pasteFileInBodyFieldAndSend(messageField, filePath: filePath)
                }
            }
        }
    }

    func closeAllNonMainWindows() throws {
        try elements.app.appWindows().forEach { window in
            if !elements.isMainWindow(window: window) {
                try window.closeWindow()
            }
        }
    }

    #if DEBUG
    func closeAllWindows() async throws {
        try await elements.mainWindow.closeWindow()
        try elements.app.appWindows().forEach { try $0.closeWindow() }
    }

    func withAllWindowsClosed(perform: () throws -> Void) async throws {
        try await closeAllWindows()
        try perform()
        _ = try await elements.mainWindow // accessing will open it
    }

    func assignFileToBodyField(filePath: String) async throws {
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url)
        print(data, url)

        let myString = "something"
        let myAttrString = NSAttributedString(string: myString, attributes: [:])
        let mas = NSMutableAttributedString()
        mas.append(myAttrString)

        let messageField = try await elements.messageBodyField
        try messageField.value(assign: url) // no op
        try messageField.value(assign: mas) // illegalArgument
        try messageField.value(assign: data) // cannotComplete

        try messageField.value(assign: "\u{fffc}") // obj replacement char
        try messageField.value(assign: url)
    }
    #endif

    func pasteFileInBodyFieldAndSend(_ messageField: Accessibility.Element, filePath: String) async throws {
        let fileURL = URL(fileURLWithPath: filePath)
        var messageField = messageField
        try? messageField.value(assign: "")
        try await focusMessageField(messageField) // focus is partially redundant, hitting ⌘ V without focus works too unless another text field is focused
        let pasteboard = NSPasteboard.general
        try await pasteboard.withRestoration {
            pasteboard.setString(fileURL.relativeString, forType: .fileURL)
            try keyPresser.commandV()
            try await retry(withTimeout: 2, interval: 0.05) { () async throws in
                let charCountResult = Result { try messageField.noOfChars() }
                guard case let .success(charCount) = charCountResult else {
                    messageField = try await elements.messageBodyField
                    throw ErrorMessage("cannot get char count: \(charCountResult)")
                }
                // 2 for <OBJ_REPLACEMENT_CHAR> and \n
                guard charCount == 2 else {
                    messageField = try await elements.messageBodyField
                    throw ErrorMessage("file was not pasted: \(charCountResult)")
                }
            }
            try await sendMessageInField(messageField)
        }
    }

    private struct ManualActivationState {
        var lastActivate: Date?
        var messagesIsManuallyActivated = false
    }

    private let manualActivationState = Protected(ManualActivationState())
    private var messagesIsManuallyActivated: Bool {
        manualActivationState.read().messagesIsManuallyActivated
    }
    // when the user manually cmd+tab's or clicks the Messages dock icon,
    // we want to actually show the app
    private func activateMessages() {
        guard !isDisposed.read(), !app.isTerminated else { return }
        // Let idle observation back off before waiting for the lane.
        manualActivationState.withLock {
            $0.lastActivate = Date()
            $0.messagesIsManuallyActivated = true
        }
        log.debug("activateMessages")
        // Keep consuming lifecycle events while window work waits for the lane.
        MessagesControllerAutomationLane.escapingTask { [weak self] in
            do {
                try await PlatformAPI.runOnMessagesControllerLane { [weak self] in
                    guard let self, !self.isDisposed.read(), !self.app.isTerminated else { return }
                    self.lastOpenedThreadID = nil
                    guard self.messagesIsManuallyActivated else {
                        log.debug("activateMessages: skipping stale activation (user already deactivated)")
                        return
                    }
                    // we use getMainWindow() instead of mainWindow to not reopen the window if it's not present
                    var oldType: String?
                    do {
                        oldType = try MessagesDockSuppression.applicationType(for: self.app.processIdentifier)
                        try await self.windowCoordinator.restoreDockPresence()
                    } catch {
                        log.error("failed to restore Messages Dock presence: \(error)")
                    }
                    if Defaults.shouldCoordinateWindow {
                        try await self.windowCoordinator.userManuallyActivated(self.app)
                        if let window = self.elements.getMainWindow() {
                            try await self.windowCoordinator.reset(window)
                        }
                    }
                    if oldType == "invalid" || oldType == "UIElement" {
                        await MainActor.run { self.app.activate(options: [.activateAllWindows]) }
                    }
                }
            } catch {
                log.error("couldn't unhide messages window caused by user activation: \(error)")
            }
        }
    }

    private func deactivateMessages() {
        guard !isDisposed.read(), !app.isTerminated else { return }
        let lastActivate = manualActivationState.withLock { state in
            let lastActivate = state.lastActivate
            state.messagesIsManuallyActivated = false
            return lastActivate
        }
        lastActivate.map { log.debug("used messages.app for \($0.timeIntervalSinceNow * -1)s") }
        log.debug("deactivateMessages")
        MessagesControllerAutomationLane.escapingTask { [weak self] in
            do {
                try await PlatformAPI.runOnMessagesControllerLane { [weak self] in
                    guard let self, !self.isDisposed.read(), !self.app.isTerminated else { return }
                    guard !self.messagesIsManuallyActivated else {
                        log.debug("deactivateMessages: skipping stale deactivation (user re-activated)")
                        return
                    }
                    // we use getMainWindow() instead of mainWindow to not reopen the window if it's not present
                    let window = self.elements.getMainWindow()
                    if Defaults.shouldCoordinateWindow {
                        try await self.windowCoordinator.userManuallyDeactivated(self.app)
                    }
                    try? self.closeAllNonMainWindows()
                    if window != nil {
                        await self.resetWindow()
                    }
                }
            } catch {
                log.error("couldn't hide messages window caused by user activation: \(error)")
            }
        }
    }

    func activityObservation() async -> ThreadActivityObservation {
        #if DEBUG
        let startTime = Date()
        defer { log.debug("activityObservation took \(startTime.timeIntervalSinceNow * -1000)ms") }
        #endif
        guard let transcript = try? await elements.transcriptView,
              let cellsToCheck = try? MessagesAppElements.threadActivityCells(in: transcript),
              !cellsToCheck.isEmpty else {
            return .unknown
        }
        // AXStaticText, localizedDescription="￼ Steve has notifications silenced"
        // AXButton, localizedDescription="Notify Anyway"
        let presenceStatus: PlatformSDK.UserPresenceStatus? = {
            guard isMontereyOrUp else { return nil }
            for elt in cellsToCheck.reversed() {
                guard let child = try? elt.children[0] else { continue }
                let childRole = try? child.role()
                let childDescription = try? child.localizedDescription()
                if childRole == Accessibility.Role.button,
                   childDescription == LocalizedStrings.notifyAnyway {
                    return .dndCanNotify
                }
                if childRole == Accessibility.Role.staticText,
                   childDescription?.hasSuffix(LocalizedStrings.hasNotificationsSilencedSuffix) == true {
                    return .dnd
                }
            }
            return nil
        }()
        let isTyping = cellsToCheck.contains { elt in
            let childCount = try? elt.children.count()
            // kabir: children can briefly be 0 for newly sent messages as well, so that by itself isn't a good enough heuristic
            if childCount != 0 { return false }
            let description = try? elt.localizedDescription()
            if description == LocalizedStrings.contactTyping { return true }
            if !LocalizedStrings.contactWithNameTypingSuffix.isEmpty,
               description?.hasSuffix(LocalizedStrings.contactWithNameTypingSuffix) == true { return true }
            // kb: the following return statement should probably be removed but i haven't tested on Big Sur to Ventura 13.2 so keeping just in case
            return (try? elt.roleDescription().isEmpty) != false
        }
        return ThreadActivityObservation(
            activityType: isTyping ? .typing : .none,
            presenceStatus: presenceStatus,
            didObservePresence: true
        )
    }

    func notifyAnyway(threadID: String) async throws {
        let deepLink = try MessagesDeepLink(threadID: threadID, body: nil)

        try await withAutomation {
            try await withActivation(openBefore: deepLink) {
                try await assertSelectedThread(threadID: threadID)
                try await elements.notifyAnywayButton.press()
            }
        }
    }

    func activityStatus(threadID: String) async throws -> ThreadActivityObservation {
        let deepLink = try MessagesDeepLink(threadID: threadID, body: nil)

        var observation = ThreadActivityObservation.unknown
        try await withAutomation {
            try await withActivation(openBefore: deepLink) {
                try await assertSelectedThread(threadID: threadID)
                observation = await activityObservation()
            }
        }
        return observation
    }

    private func waitForLayoutChange(timeout: TimeInterval) async throws {
        let beganWaiting = Date()

        while Date().timeIntervalSince(beganWaiting) < timeout {
            if let lastLayoutChange = lifecycleObserver.lastLayoutChange.read(), lastLayoutChange > beganWaiting {
                log.debug("observed layout change, exiting wait loop")
                return
            }
            try await Task.sleep(forTimeInterval: 0.05) // 50ms
        }

        log.error("didn't observe a layout change within \(timeout)s, continuing anyways")
    }

    /// Polls the selected thread while automation is idle.
    func observeIdleActivity(
        requestID: UUID,
        threadID: String,
        readActivity: Bool,
        statusSender: @escaping @Sendable (ThreadActivityObservation) -> Void
    ) async throws {
        guard readActivity else {
            #if DEBUG
            log.debug("not observing activity, thread doesn't support activity observation")
            #endif
            return
        }

        guard !Defaults.shouldCoordinateWindow else {
            log.debug("not observing activity, Messages window is being coordinated")
            return
        }

        guard !messagesIsManuallyActivated else {
            log.debug("not observing activity, Messages is manually activated")
            return
        }

        let deepLink = try MessagesDeepLink(threadID: threadID, body: nil)

        guard await isValid else {
            #if DEBUG
            log.debug("not observing activity, controller is invalid")
            #endif
            return
        }

        if lastOpenedThreadID != threadID {
            log.debug("activity: entered idle state or thread id changed, opening deep link")
            try await withAutomation {
                _ = try await self.openDeepLink(deepLink)
                log.debug("activity: opened deep link, waiting for layout change")
                try await self.waitForLayoutChange(timeout: 0.5)
            }
        }

        guard occlusionMonitor.visible else {
            #if DEBUG
            log.debug("not observing activity, window occluded")
            #endif
            return
        }

        let observationToSend = await activityObservation()
        guard activityObservationCache.shouldSend(observationToSend, requestID: requestID) else {
            #if DEBUG
            log.debug("activity: same activity or too recent, skipping activity update")
            #endif
            return
        }
        #if DEBUG
        log.debug("activity: sending: \(observationToSend)")
        #endif
        statusSender(observationToSend)
    }

    private let isDisposed = Protected(false)

    func dispose(terminateApp: Bool = true) {
        log.info("disposing MessagesController")
        guard isDisposed.withLock({ disposed in
            guard !disposed else { return false }
            disposed = true
            return true
        }) else { return }
        NotificationCenter.default.removeObserver(self, name: .CNContactStoreDidChange, object: nil)
        cancelReplyTranscriptViewTask?.cancel()
        lifecycleConveyor?.cancel()
        lifecycleEventsTask?.cancel()

        if terminateApp {
            // Restoring a parked window can order it onscreen even while AX
            // reports the app hidden. Let Messages close its windows in the
            // unknown Space before releasing coordination ownership.
            app.terminate()
            let deadline = Date().addingTimeInterval(2)
            let pid = app.processIdentifier
            while kill(pid, 0) == 0 || errno != ESRCH {
                guard Date() < deadline else {
                    // Preserve the existing recovery path if Messages refuses
                    // to quit: restore its windows instead of stranding them.
                    log.warning("Messages did not exit before window restoration")
                    break
                }
                if Thread.isMainThread {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                } else {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }

        do { try windowCoordinator.dispose() }
        catch { log.error("Failed to clean up window coordination: \(error)") }
    }

    deinit {
        log.info("MessagesController deinit")
        dispose()
    }
}

extension MessagesController {
    class OcclusionMonitor {
        var visible: Bool = true
        private var ncToken: NSObjectProtocol?

        init() {
            ncToken = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: nil) { notification in
                log.trace("didChangeOcclusionStateNotification \(notification)")
                guard let window = notification.object as? NSWindow else { return }

                let className = NSStringFromClass(type(of: window))

                guard className == "ElectronNSWindow" || className == "TextsSwift.CustomWindow" else {
                    return
                }

                self.visible = window.occlusionState.contains(.visible)
            }
        }

        deinit {
            ncToken.map { NotificationCenter.default.removeObserver($0) }
        }
    }
}
