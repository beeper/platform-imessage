import AccessibilityControl
import AppKit
import BetterSwiftAXAdditions
import Carbon.HIToolbox.Events
import Combine
import Contacts
import EmojiSPI
import IMDatabase
import Logging
import PHTClient
import SwiftServerFoundation
import WindowControl

private let log = Logger(swiftServerLabel: "messages-controller")
private let lifecycleLog = Logger(swiftServerLabel: "lifecycle")

let messagesBundleID = "com.apple.MobileSMS"

// external API is thread safe
@available(macOS 11, *)
final class MessagesController {
    public let application: MessagesApplication
    
    //     legacy stub
    //    public var app: NSRunningApplication {
    //        // FIXME: (@pmanot) - remove force unwrap even though this is okay to use right now (because we ensure `controlledRunningApplication` is non-nil after initializing `MessagesApplication`)
    //        application.controlledRunningApplication!
    //    }
    
    let elements: MessagesAppElements
    
    private var pollingConveyor: RunLoopConveyor<ConveyorEvent>?
    
    var cachedDatabase: IMDatabase?
    private var lifecycleObserver: LifecycleObserver
    private var lastThreadIDOpenedForObservation = Protected<String?>()
    private var lastSentActivityStatus: [ActivityStatus]?
    private var lastSentActivityStatusTime: Date?
    
    private var windowCoordinator: WindowCoordinator
    private var phtConnection: PHTConnection?
    private let keyPresser: LegacyKeyPresser
    let contacts = Contacts()
    private var reportToSentry: ((_ txt: String) -> Void)?
    
    let occlusionMonitor = OcclusionMonitor()
    
    init(reportToSentry: @escaping (_ txt: String) -> Void) throws {
        self.reportToSentry = reportToSentry
        guard Accessibility.isTrusted() else {
            throw ErrorMessage("Beeper does not have Accessibility permissions")
        }
        
        windowCoordinator = try getBestWindowCoordinator()
        
        if Preferences.isPHTEnabled, Defaults.swiftServer.bool(forKey: DefaultsKeys.phtAllowConnection) {
            do {
                let allowInstall = Defaults.swiftServer.bool(forKey: DefaultsKeys.phtAllowInstallation)
                phtConnection = try PHTConnection.create(allowInstall: allowInstall)
            } catch {
                log.error("failed to create PHT connection: \(String(reflecting: error))")
            }
        }
        
        var messagesApps = Self.getRunningMessagesApps()
        if messagesApps.count > 1 { // if there's more than one instance of messages app something weird happened, terminate all to be safe
            log.info("found \(messagesApps.count) instances of messages.app, terminating all to be safe")
            try messagesApps.forEach { message in
                try unsafeBlockCurrentThreadUntilComplete {
                    _ = await message.terminateAndWaitForTermination()
                }
            }
            messagesApps.removeAll()
        }
        
        let shouldUseExtantInstance: Bool = windowCoordinator.canReuseExtantInstance || !Defaults.shouldCoordinateWindow
        
        if shouldUseExtantInstance {
            log.info("reusing existing messages...")
        } else {
            log.info("terminating messages...")
        }
        
        self.application = try unsafeBlockCurrentThreadUntilComplete {
            try await MessagesApplication(strategy: .puppetInstance, useExtantInstanceIfPossible: shouldUseExtantInstance)
        }
        
        // FIXME: (@pmanot) - remove force unwrap even though this is okay to use right now (because we ensure `controlledRunningApplication` is non-nil after initializing `MessagesApplication`)
        windowCoordinator.app = application.controlledRunningApplication
        
        elements = application.controlledRunningApplication.elements
        elements.openDeepLink = { [application] url in
            try application.openDeepLink(url)
        }
        keyPresser = LegacyKeyPresser(pid: application.controlledRunningApplication.processIdentifier)
        
        // if app.isHidden {
        //     debugLog("Unhiding Messages...")
        //     try retry(withTimeout: 1, interval: 0.1) { [app] in
        //         app.unhide()
        //         if app.isHidden {
        //             throw ErrorMessage("Could not launch Messages")
        //         }
        //     }
        // }
        let observer = LifecycleObserver()
        lifecycleObserver = observer
        setUpPollingConveyor(with: lifecycleObserver)
        
        guard isValid else {
            dispose() // since deinit isn't called when init throws
            throw ErrorMessage(
                """
                Initialized MessagesController in an invalid state:
                appTerminated=\(application.controlledRunningApplication.isTerminated)
                mwFrameValid=\(Result { try elements.mainWindow.isFrameValid })
                isMessagesAppResponsive=\(isMessagesAppResponsive)
                """
            )
        }
        resetWindow()
    }
    
    // this increases the viewport height so that mark as read works more reliably
    static func resizeWindowToMaxHeight(_ window: Accessibility.Element) throws {
        var frame = try window.frame()
        frame.origin.y = 0
        frame.size.height = Double.infinity
        try window.setFrame(frame)
    }
    
    // without expanding splitter, thread cells will not have custom ax actions (on monterey at least)
    private func expandSplitter() throws {
        if try elements.conversationsList.size().width < 99 { // width is 94 when in compact mode
            try elements.splitter.increment()
        }
    }
    
    private func resetWindow() {
        try? elements.searchField.cancel()
        try? expandSplitter()
        try? closeReplyTranscriptView(wait: false)
    }
    
    func isSameContact(_ a: String?, _ b: String?) -> Bool {
        guard let contacts = contacts, let a = a, let b = b else { return false }
        return contacts.fetchID(for: a) == contacts.fetchID(for: b)
    }
    
    private func getToFieldAddresses() -> LazyMapSequence<ReversedCollection<LazySequence<[Substring]>>, String>? {
        let desc = try? elements.toFieldPopupButton.localizedDescription()
        // unknown if other locales also use , as a separator
        let elements = desc?.split(separator: ",").lazy.reversed().map { String($0).trimmingCharacters(in: .whitespaces) }
        return elements
    }
    
    // ignores the service (SMS or iMessage) and matches contact identifiers since it's merged in the UI
    // TODO: rename to `assertSelectedThread`, which better describes its behavior
    private func ensureSelectedThread(threadID: String) throws {
        let hashedThreadID = Hasher.thread.tokenizeRemembering(pii: threadID)
        guard Defaults.swiftServer.bool(forKey: DefaultsKeys.misfirePrevention) else {
            log.debug("NOT ensuring selected thread, misfire prevention is off: \(hashedThreadID)")
            return
        }
        
        let (_, type, addressToMatch) = try splitThreadID(threadID).orThrow(ErrorMessage("invalid threadID"))
        
        if Defaults.misfirePreventionTracing {
            log.debug("ensuring selected thread: \(hashedThreadID)")
        }
        
        func ensureSelectedThreadViaDefault(value selectedThreadID: String) throws {
            guard selectedThreadID != "CKConversationListNewMessageCellIdentifier" else {
                throw ErrorMessage("misfire prevention: compose thread is selected")
            }
            
            let selectedAddress = try threadIDToAddress(selectedThreadID)
                .orThrow(ErrorMessage("misfire prevention: cannot extract address from selected thread id"))
            
            guard selectedAddress == addressToMatch ||
                    (type == singleThreadType && isSameContact(selectedAddress, addressToMatch))
            else {
                log.error("ensureSelectedThread: failed to select thread")
                throw ErrorMessage("misfire prevention: desired thread is not selected")
            }
        }
        
        func ensureSelectedThreadViaLastChange(of date: Protected<Date?>, type: String, emoji: String) throws {
            guard let lastChange = date.read() else {
                throw ErrorMessage("misfire prevention: \(type) hasn't changed at all")
            }
            
            let waitingTime = "\((Date().timeIntervalSince(beganEnsuringThreadSelection) * 1_000).rounded())ms"
            guard lastChange > beganEnsuringThreadSelection else {
                throw ErrorMessage("misfire prevention: \(type) hasn't changed yet since we started (\(beganEnsuringThreadSelection.iso8601Formatted)) (waited \(waitingTime) so far)")
            }
            
            log.debug("misfire prevention: \(emoji) \(type) changed \(lastChange.iso8601Formatted) (waited \(waitingTime) overall)")
        }
        
        var attempt = 0
        let beganEnsuringThreadSelection = Date()
        var hasLoggedAboutFallback = false
        
        try retry(withTimeout: 1.2, interval: 0.05) {
            attempt += 1
            do {
                // always prefer reading the default if we can (impossible on recent macOS; see DESK-10725)
                if !SwiftServerDefaults[\.misfirePreventionAlwaysFallback], let selectedThreadID = Defaults.getSelectedThreadID() {
                    return try ensureSelectedThreadViaDefault(value: selectedThreadID)
                }
                
                let strategy = Defaults.swiftServer.string(forKey: DefaultsKeys.misfirePreventionFallbackStrategy)
                if Defaults.misfirePreventionTracing, !hasLoggedAboutFallback {
                    log.debug("misfire prevention: no access to Messages defaults, falling back (strategy: \"\(strategy ?? "<nil>")\")")
                    hasLoggedAboutFallback = true
                }
                // we can't read the default, fall back to a designated strategy to ensure that
                // Messages is focused to our desired chat:
                
                switch strategy {
                    case "title-prediction":
                        // TODO: when contacts details change, iMessage might not update the window title immediately.
                        // TODO: to resolve this, perhaps try jiggling the selection around if the title doesn't match
                        guard let windowTitle = try? elements.mainWindow.title() else {
                            throw ErrorMessage("misfire prevention: couldn't read window title")
                        }
                        
                        return try assertSelectedThreadByPredictingWindowTitle(desiredChatGUID: threadID, currentWindowTitle: windowTitle)
                    case "focus-waiter":
                        // wait until Accessibility posts a notification staging that the focused element has changed.
                        try ensureSelectedThreadViaLastChange(of: lifecycleObserver.lastFocusedUIElementChange, type: "focus", emoji: "👆")
                    case "layout-waiter":
                        // wait until Accessibility posts a notification stating that the layout has changed.
                        // this happens very frequently, for example after changing the active chat (what we specifically want to know about)
                        // or even scrolling the chat list
                        try ensureSelectedThreadViaLastChange(of: lifecycleObserver.lastLayoutChange, type: "layout", emoji: "📐")
                    default:
                        var sleepInterval = Defaults.swiftServer.double(forKey: DefaultsKeys.misfirePreventionSleepInterval)
                        if sleepInterval <= 0.0 { sleepInterval = 0.5 }
                        log.warning("misfire prevention: no fallback strategy specified; sleeping for \(sleepInterval)s instead")
                        Thread.sleep(forTimeInterval: sleepInterval)
                }
            } catch {
                if attempt > 5 { // 250ms
                    if let addresses = getToFieldAddresses(), addresses.contains(where: { isSameContact($0, addressToMatch) }) {
                        log.error("ensureSelectedThread: resorted to fallback in order to assert selection")
                        return
                    }
                }
                throw error
            }
        }
    }
    
    private func openThread(_ threadID: String) throws {
        try application.openDeepLink(try MessagesDeepLink(threadID: threadID, body: nil).url())
        try ensureSelectedThread(threadID: threadID)
    }
    
    private static func getRunningMessagesApps() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)
    }
    
    func setUpPollingConveyor(with observer: LifecycleObserver) {
        let thread = RunLoopConveyor<ConveyorEvent>(name: "SwiftServer Polling RunLoop", oneTimeInitialization: { rlt in
            do {
                try observer.beginObserving(app: self.elements.app)
            } catch {
                log.error("unable to perform initial observation of app: \(error)")
            }
            do {
                try observer.beginObserving(window: try self.elements.mainWindow)
            } catch {
                log.error("unable to perform initial observation of main window: \(error)")
            }
            
            // this task doesn't run on the thread with the run loop
            Task {
                func debuggingStatus() -> String {
                    // grab the running application again in case it has quit
                    // and relaunched since we last observed an event
                    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).first else { return "<no app>" }
                    
                    do {
                        let window = try self.elements.mainWindow
                        let frame = try window.frame()
                        let position = try window.position()
                        return "finishedLaunching=\(app.isFinishedLaunching), active=\(app.isActive), hidden=\(app.isHidden), terminated=\(app.isTerminated), AXframe=\(frame), AXpos=\(position)"
                    } catch {
                        return "<failed to query: \(error)>"
                    }
                }
                
                for await event in observer.events.subscribe() {
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
                            printLifecycle(event: "WINDOW created")
                            // for now, reset our window-local observations whenever we
                            // see that a window was created (even if it was just e.g.
                            // the settings window).
                            rlt.enqueue(.observeWindow(window: try self.elements.mainWindow))
                    }
                }
            }
        }, handlingWorkItemsWithinRunLoop: { event in
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
        self.pollingConveyor = thread
    }
    
    var isMessagesAppResponsive: Bool {
        (try? Process.isUnresponsive(application.controlledRunningApplication.processIdentifier)) == false
    }
    
    var isValid: Bool {
        !application.controlledRunningApplication.isTerminated && (try? elements.mainWindow.isFrameValid) != nil && isMessagesAppResponsive
    }
    
    @inlinable func prepareForAutomation() throws {
        log.info("prepareForAutomation")
        afterAutomationTask?.cancel()
        elements.clearCachedElements()
        log.debug("prepareForAutomation: making the app automatable")
        do {
            try phtConnection?.setMessagesHidden(true)
        } catch {
            log.error("failed to hide messages app via pht: \(error)")
        }
        if Defaults.shouldCoordinateWindow, let mainWindow = elements.getMainWindow() {
            try windowCoordinator.makeAutomatable(mainWindow)
        }
        activityLock.lock()
    }
    
    @inlinable func finishedAutomation() {
        log.info("finishedAutomation")
        activityLock.unlock()
        // this isn't propagated to make finishedAutomation callable inside of defer { … }
        if Defaults.shouldCoordinateWindow, let mainWindow = elements.getMainWindow() {
            do {
                try windowCoordinator.automationDidComplete(mainWindow)
            } catch {
                log.error("failed to call automationDidComplete on window coordinator: \(String(reflecting: error))")
            }
        }
        // todo: this can be optimized by scheduling only after we trigger open the rtv instead of after each automation
        scheduleCancelReplyTranscriptView()
    }
    
    private var afterAutomationTask: DispatchWorkItem?
    
    private static let queue = DispatchQueue(label: "messages-controller-queue")
    
    private func scheduleCancelReplyTranscriptView() {
        afterAutomationTask = DispatchWorkItem { [self] in
            activityLock.lock()
            defer { activityLock.unlock() }
            try? closeReplyTranscriptView(wait: false)
        }
        afterAutomationTask.map { Self.queue.asyncAfter(deadline: .now() + 1.5, execute: $0) }
    }
    
    private func messageAction(messageCell: Accessibility.Element, action: MessageAction) throws -> Accessibility.Action {
        // [press, AXScrollToVisible, show menu, Escape, scroll left by a page, scroll right by a page, React, Reply, Copy]
        // ["AXPress", "AXScrollToVisible", "AXShowMenu", "AXCancel", "AXScrollLeftByPage", "AXScrollRightByPage", "Name:React\nTarget:0x0\nSelector:(null)", "Name:Reply\nTarget:0x0\nSelector:(null)", "Name:Copy\nTarget:0x0\nSelector:(null)"]
        // non-AX actions are [React, Reply, Copy, Pin]
        // Pin is missing for non-links / Big Sur
        let allActions = try messageCell.supportedActions()
        let action = try allActions.first(where: { $0.name.value.hasPrefix("Name:\(action.localized)") })
            .orThrow(ErrorMessage("MessageAction.\(action) not found"))
        return action
    }
    
    private func triggerThreadCellAction(threadCell: Accessibility.Element, action: ThreadAction) throws {
        let action = try threadCell.supportedActions().first(where: { $0.name.value.hasPrefix("Name:\(action.localized)") })
            .orThrow(ErrorMessage("ThreadAction.\(action) not found"))
        try action()
    }
    
    private func triggerThreadCellAction(threadID: String, action: ThreadAction) throws {
        let threadCell = try scrollAndGetSelectedThreadCell(threadID: threadID)
        try triggerThreadCellAction(threadCell: threadCell, action: action)
    }
    
    private func selectNextThreadAndScroll() throws {
        let threadID = Defaults.getSelectedThreadID()
        // ctrlTab() acts differently, has no effect?
        try keyPresser.commandRightBracket() // scrolls to next thread cell, rare edge case: won't work for the last item
        try retry(withTimeout: 0.5, interval: 0.05) { // wait for hotkey to switch threads
            guard Defaults.getSelectedThreadID() != threadID else { throw ErrorMessage("diff thread not selected") }
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
    private func scrollAndGetSelectedThreadCell(threadID: String) throws -> Accessibility.Element {
#if DEBUG
        let startTime = Date()
        defer { log.debug("scrollAndGetSelectedThreadCell took \(startTime.timeIntervalSinceNow * -1000)ms") }
#endif
        
        // we assume thread is already selected
        
        let selectedCell = try elements.selectedThreadCell.orThrow(ErrorMessage("selectedThreadCell nil"))
        if selectedCell.isInViewport { return selectedCell }
        
        try selectNextThreadAndScroll()
        try openThread(threadID)
        
        let selectedCellAfterScroll = try elements.selectedThreadCell.orThrow(ErrorMessage("selectedThreadCell nil"))
        if selectedCellAfterScroll.isInViewport { return selectedCellAfterScroll }
        throw ErrorMessage("threadCell not found")
    }
    
    // performs `perform` while the Messages window is unhidden
    private func withActivation(
        openBefore: URL?, openAfter: URL? = nil,
        perform: () throws -> Void
    ) throws {
        if let openBefore {
#if DEBUG
            log.debug("withActivation: opening before performing: \(openBefore)")
#endif
            try application.openDeepLink(openBefore)
        }
        
        try perform()
        
        if let openAfter {
            if openAfter != openBefore {
#if DEBUG
                debugLog("withActivation: opening after performing: \(openAfter)")
#endif
                try application.openDeepLink(openAfter)
            }
        }
    }
    
    private func revealReplyTranscriptViaMenu() throws {
        do {
            let window = NSApp.largestElectronWindow
            let previousLevel = window?.level
            if let window {
                DispatchQueue.main.sync {
                    let higherLevel = NSWindow.Level(Int(CGWindowLevelForKey(.draggingWindow)))
                    log.debug("reveal: elevating window to level \(higherLevel) (currently: \(window.level))")
                    window.level = higherLevel
                }
            }
            defer {
                if let window, let previousLevel {
                    DispatchQueue.main.sync {
                        log.debug("reveal: lowering window to previous level \(previousLevel)")
                        window.level = previousLevel
                    }
                }
            }
            
            try Self.queue.sync {
                guard let cell = try? MessagesAppElements.firstSelectedMessageCell(in: elements.transcriptView) else {
                    throw ErrorMessage("reveal: couldn't find selected message cell to show overlay with")
                }
                
                Thread.sleep(forTimeInterval: 1.0)
                log.debug("reveal: 1/5 showing the cell's menu")
                try cell.showMenu()
                Thread.sleep(forTimeInterval: 0.1)
                
                let targetTitle = LocalizedStrings.inlineReplyMenu
                log.debug("reveal: 2/5 locating reply menu item (with title \"\(targetTitle)\")")
                
                guard let menuItems = try? elements.menu.children() else {
                    throw ErrorMessage("reveal: couldn't query menu item children")
                }
                guard let replyMenuItem = menuItems.first(where: { menuItem in
                    guard let title = try? menuItem.title() else {
                        return false
                    }
                    
                    let idIfPossible = ((try? menuItem.identifier()).map { " [ID: \"\($0)\"]" }) ?? ""
                    log.debug("reveal: 2/5   witnessed: \"\(title)\"\(idIfPossible)")
                    return title == targetTitle
                }) else {
                    throw ErrorMessage("reveal: couldn't find reply menu item")
                }
                
                log.debug("reveal: 3/5 found, pressing")
                try replyMenuItem.press()
                
            }
            
        }
        
        log.debug("reveal: 4/5 sleeping for a bit")
        Thread.sleep(forTimeInterval: 0.4)
        
        log.debug("reveal: 5/5 done, proceeding with grabbing the cell")
    }
    
    private func withMessageCell(threadID: String, messageCell: MessageCell, action: (_ cell: Accessibility.Element) throws -> Void) throws {
        log.debug("withMessageCell (messageCell=\(messageCell))")
        
        let url = try MessagesDeepLink.message(guid: messageCell.messageGUID, overlay: messageCell.overlay).url()
        
        // without closing reply transcript, non-overlay deep link won't select the message
        if !messageCell.overlay {
            try? closeReplyTranscriptView(wait: false)
        }
        
        try withActivation(openBefore: url) {
            try ensureSelectedThread(threadID: threadID)
            
            // we don't close transcript view here because when reacting, closing it will undo the reaction
            // defer {
            //     if messageCell.overlay {
            //         // alt: try? sendKeyPress(key: CGKeyCode(kVK_Escape))
            //         closeReplyTranscriptView(wait: true)
            //     }
            // }
            if messageCell.overlay {
                if #available(macOS 26, *) {
                    try revealReplyTranscriptViaMenu()
                }
                try waitUntilReplyTranscriptVisible()
            }
            guard let selected = (try retry(withTimeout: 1, interval: 0.2) { () -> Accessibility.Element? in
                guard let cell = try messageCell.overlay
                        ? MessagesAppElements.firstMessageCell(in: elements.replyTranscriptView)
                        : MessagesAppElements.firstSelectedMessageCell(in: elements.transcriptView)
                else {
                    throw ErrorMessage("message cell nil")
                }
                guard cell.isInViewport else { throw ErrorMessage("message cell not in viewport") }
                return cell
            }) else {
                throw ErrorMessage("Could not find message cell")
            }
            let targetCell: Accessibility.Element
            if messageCell.offset == 0 {
                targetCell = selected
            } else {
                let containerCell = try selected.parent()
                let containerFrame = try containerCell.frame()
                let containerCells = try MessagesAppElements.messageContainerCells(in: messageCell.overlay ? elements.replyTranscriptView : elements.transcriptView)
                guard let idx = containerCells.firstIndex(where: { (try? $0.frame()) == containerFrame }) else {
                    throw ErrorMessage("Could not find target message cell")
                }
                let target = idx - messageCell.offset
                log.debug("Index: \(idx) - \(messageCell.offset) = \(target)")
                guard containerCells.indices.contains(target) else {
                    throw ErrorMessage("Desired index out of bounds")
                }
                targetCell = try containerCells[target].children[0]
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
            try action(targetCell)
        }
    }
    
    func setReaction(threadID: String, messageCell: MessageCell, reaction: Reaction, on: Bool) throws {
        let startTime = Date()
        defer { log.debug("setReaction took \(startTime.timeIntervalSinceNow * -1000)ms") }
        
        try prepareForAutomation()
        defer { finishedAutomation() }
        
        try withMessageCell(threadID: threadID, messageCell: messageCell) {
            let reactAction = try messageAction(messageCell: $0, action: .react)
            try reactAction() // performing this 2x will close reaction view
            
            if MacOSVersion.isAtLeast(.sequoia) { // wait for animation
                Thread.sleep(forTimeInterval: 0.75)
            }
            
            if case let .custom(emoji) = reaction, on {
                guard MacOSVersion.isAtLeast(.sequoia) else { throw ErrorMessage("Custom emoji reactions are only supported on macOS 15 or later") }
                // to react with a custom emoji, find the smile button and wrangle the character picker popover
                // TODO: support being able to pick a skin tone
                try elements.addCustomEmojiReactionButton.press()
                Thread.sleep(forTimeInterval: 1.0) // wait for animation
                let search: CharacterPickerSearch
                do {
                    search = try CharacterPickerSearch(finding: emoji)
                } catch {
                    throw ErrorMessage("Can't react with \"\(emoji)\": \(String(describing: error))")
                }
                try elements.searchFieldWithinPopover.value(assign: search.query)
                Thread.sleep(forTimeInterval: 0.75) // wait for search
                // focus the matrix (tab also seems to work for this? full keyboard access needed maybe?)
                try keyPresser.downArrow()
                // 6 columns in the character picker matrix
                let (downArrows, rightArrows) = search.position.quotientAndRemainder(dividingBy: 6)
                // navigate to the emoji
                for _ in 0..<downArrows { try keyPresser.downArrow(); Thread.sleep(forTimeInterval: 0.05) }
                for _ in 0..<rightArrows { try keyPresser.rightArrow(); Thread.sleep(forTimeInterval: 0.05) }
                Thread.sleep(forTimeInterval: 0.1) // wait for selection
                try keyPresser.return() // select
                if try EMFEmojiToken(character: emoji).supportsSkinToneVariants == true {
                    Thread.sleep(forTimeInterval: 0.2) // wait for skin tone picker to appear
                    try keyPresser.return() // always select default skin tone
                }
                return
            }
            
            let btn = try {
                if MacOSVersion.isAtLeast(.sequoia) {
                    return try elements.tapbackPickerCollectionView.children()
                        .first {
                            // standard: "ha", "thumbsUp", etc. custom: emoji string
                            let identifier = try? $0.identifier()
                            return identifier == reaction.idOrEmoji
                        }
                        .orThrow(ErrorMessage("Could not find \(on ? "react" : "unreact") button"))
                }
                
                let idx = reaction.index!
                let buttons = try elements.reactButtons
                guard buttons.count > idx else {
                    throw ErrorMessage("reactButtons count=\(buttons.count)")
                }
                
                return buttons[idx]
            }()
            
            try retry(withTimeout: 1.2, interval: 0.1) {
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
    
    // @available(macOS 13, *)
    func undoSend(threadID: String, messageCell: MessageCell) throws {
        guard MacOSVersion.isAtLeast(.ventura) else {
            throw ErrorMessage("!isVenturaOrUp")
        }
        
        let startTime = Date()
        defer { log.debug("undoSend took \(startTime.timeIntervalSinceNow * -1000)ms") }
        
        try prepareForAutomation()
        defer { finishedAutomation() }
        
        try withMessageCell(threadID: threadID, messageCell: messageCell) {
            let undoSendAction = try messageAction(messageCell: $0, action: .undoSend)
            try undoSendAction()
        }
    }
    
    // @available(macOS 13, *)
    // NOTE: message editing works even when the window is ordered out
    func editMessage(threadID: String, messageCell: MessageCell, newText: String) throws {
        guard MacOSVersion.isAtLeast(.ventura) else {
            throw ErrorMessage("!isVenturaOrUp")
        }
        
        let startTime = Date()
        defer { log.debug("editMessage took \(startTime.timeIntervalSinceNow * -1000)ms") }
        
        try prepareForAutomation()
        defer { finishedAutomation() }
        
        func tryPressingCancelEditButton() {
            if let cancelEditButton = try? elements.cancelEditButton {
                // this is seemingly always available, even when you're not editing
                log.debug("pressing cancel edit button")
                
                do {
                    try cancelEditButton.press()
                    Thread.sleep(forTimeInterval: 0.5)
                } catch {
                    log.error("failed to press cancel edit button, continuing anyway: \(error)")
                }
            } else {
                log.debug("(no cancel edit button was found)")
            }
        }
        
        func assignAndCommitEdit() throws {
            Thread.sleep(forTimeInterval: Defaults.swiftServer.double(forKey: DefaultsKeys.editingDelayBeforeReplacing))
            let editableMessageField = try elements.editableMessageField
            try assignToMessageField(editableMessageField, text: newText)
            
            Thread.sleep(forTimeInterval: Defaults.swiftServer.double(forKey: DefaultsKeys.editingDelayBeforeFocusing))
            focusMessageField(editableMessageField)
            
            Thread.sleep(forTimeInterval: Defaults.swiftServer.double(forKey: DefaultsKeys.editingDelayBeforePressingMenuItem))
            try keyPresser.return() // elements.editConfirmButton.press() works only after a 0.2s+ delay
            // todo: wait for it to disappear
        }
        
        let onError = { (attempt: Int, error: (any Error)?) in
            let errorDescription = String(describing: error)
            log.warning("failed to edit (attempt \(attempt)), pressing cancel edit button and retrying: \(errorDescription)")
            tryPressingCancelEditButton()
        }
        
        tryPressingCancelEditButton()
        try withMessageCell(threadID: threadID, messageCell: messageCell) { messageCell in
            if let editAction = try? messageAction(messageCell: messageCell, action: .edit) {
                log.debug("found \"Edit\" message action")
                
                try retry(withTimeout: 6.0, interval: 2.0, {
                    try editAction()
                    try assignAndCommitEdit()
                }, onError: onError)
                
                return
            }
            
            // this doesn't work reliably:
            // try $0.press(); $0.isFocused(assign: true); $0.isSelected(assign: true); keyPresser.commandE()
            try messageCell.showMenu()
            // retrying this too rapidly can cause the floating editor to appear more than once?
            try retry(withTimeout: 6.0, interval: 2.0, {
                Thread.sleep(forTimeInterval: Defaults.swiftServer.double(forKey: DefaultsKeys.editingDelayBeforePressingMenuItem))
                try elements.menuEditItem.press()
                
                try assignAndCommitEdit()
            }, onError: onError)
        }
    }
    
#if false
    // this is unusable because showing menu makes it first responder
    // keep this code as documentation
    func markAsReadWithMenu(threadID: String) throws {
        try prepareForAutomation()
        defer { finishedAutomation() }
        
        let url = try MessagesDeepLink(threadID: threadID, body: nil).url()
        try withActivation(openBefore: url) {
            try ensureSelectedThread(threadID: threadID)
            
            let threadCell = try scrollAndGetSelectedThreadCell(threadID: threadID)
            try threadCell.showMenu()
            
            let menu = try elements.menu
            /*
             AXMenuItem unpin
             AXMenuItem open_conversation_in_separate_window
             AXMenuItem delete_conversation…
             AXMenuItem
             AXMenuItem details…
             AXMenuItem hide_alerts
             AXMenuItem mark_as_read
             AXMenuItem
             AXMenuItem
             */
            guard let markAsReadMenuItem = (try retry(withTimeout: 0.5, interval: 0.1) { try menu.children().first(where: { (try? $0.identifier()) == "mark_as_read" }) }) else {
                throw ErrorMessage("markAsReadMenuItem not found")
            }
            try markAsReadMenuItem.press()
        }
    }
#endif
    
    // this only works when the messages.app window has been activated at least once
    // can randomly stop working. a reactivation of messages.app may fix (unhandled)
    private func markAsReadWithPressHack(threadID: String) throws {
#if DEBUG
        let startTime = Date()
        defer { log.debug("markAsReadWithPressHack took \(startTime.timeIntervalSinceNow * -1000)ms") }
#endif
        
        try openThread(threadID)
        let threadCell = try scrollAndGetSelectedThreadCell(threadID: threadID)
        // select any another cell and then come back
        try selectNextThreadAndScroll()
        // scrollToVisible is needed since sometimes the thread cell can be behind the search input field causing .press() to focus the input field instead
        try threadCell.scrollToVisible()
        try threadCell.press()
        try? ensureSelectedThread(threadID: threadID)
    }
    
    /*
     uses 5 methods:
     1. for ventura and up: hotkey                                           (reliable)
     lower than ventura:
     2. for pinned threads: mark-read action                                 (reliable)
     3. when less than 9 pinned threads: pin thread, #2, unpin               (reliable)
     4. threadCell.press() action hack                                       (unreliable)
     */
    func toggleThreadRead(threadID: String, read: Bool) throws {
        let startTime = Date()
        defer { log.debug("toggleThreadRead took \(startTime.timeIntervalSinceNow * -1000)ms") }
        
        let url = try MessagesDeepLink(threadID: threadID, body: nil).url()
        
        try prepareForAutomation()
        defer { finishedAutomation() }
        
        try withActivation(openBefore: url) {
            try ensureSelectedThread(threadID: threadID)
            if MacOSVersion.isAtLeast(.ventura) {
                return try keyPresser.commandShiftU()
            }
            let action = read ? ThreadAction.markAsRead : ThreadAction.markAsUnread
            if Defaults.isSelectedThreadCellPinned() {
                try triggerThreadCellAction(threadID: threadID, action: action)
            } else if let pinnedCount = Defaults.pinnedThreadsCount(), pinnedCount < 9 {
                defer {
                    if Defaults.pinnedThreadsCount() != pinnedCount {
                        try? retry(withTimeout: 0.3, interval: 0.05) {
                            log.debug("retrying unpin")
                            try triggerThreadCellAction(threadID: threadID, action: .unpin)
                        }
                    }
                    if Defaults.pinnedThreadsCount() != pinnedCount {
                        reportToSentry?("couldn't restore pins \(Defaults.pinnedThreadsCount() ?? -1) != \(pinnedCount)")
                    }
                }
                try triggerThreadCellAction(threadID: threadID, action: .pin)
                // after pin/unpin elements.selectedThreadCell is nil because no cells are selected
                // openThread ensures scroll logic isn't executed
                try openThread(threadID)
                let threadCell = try scrollAndGetSelectedThreadCell(threadID: threadID)
                defer { try? triggerThreadCellAction(threadCell: threadCell, action: .unpin) }
                try triggerThreadCellAction(threadCell: threadCell, action: action)
            } else {
                try markAsReadWithPressHack(threadID: threadID)
            }
        }
    }
    
    func muteThread(threadID: String, muted: Bool) throws {
#if DEBUG
        let startTime = Date()
        defer { log.debug("muteThread took \(startTime.timeIntervalSinceNow * -1000)ms") }
#endif
        
        let url = try MessagesDeepLink(threadID: threadID, body: nil).url()
        
        try prepareForAutomation()
        defer { finishedAutomation() }
        
        try withActivation(openBefore: url) {
            try ensureSelectedThread(threadID: threadID)
            // at least on Monterey: for pinned thread cells, this should be
            // Defaults.isSelectedThreadCellPinned() ? LocalizedStrings.hideAlerts : LocalizedStrings.hideAlerts + ", On"
            let action = muted || Defaults.isSelectedThreadCellPinned() ? ThreadAction.hideAlerts : ThreadAction.showAlerts
            try triggerThreadCellAction(threadID: threadID, action: action)
        }
    }
    
    func deleteThread(threadID: String) throws {
#if DEBUG
        let startTime = Date()
        defer { log.debug("deleteThread took \(startTime.timeIntervalSinceNow * -1000)ms") }
#endif
        
        let url = try MessagesDeepLink(threadID: threadID, body: nil).url()
        
        try prepareForAutomation()
        defer { finishedAutomation() }
        
        try withActivation(openBefore: url) {
            try ensureSelectedThread(threadID: threadID)
            try triggerThreadCellAction(threadID: threadID, action: .delete)
            try elements.alertSheetDeleteButton.press()
        }
    }
    
    func _sendTypingStatus(threadID: String, isTyping: Bool) throws {
        // a space is enough to send a typing indicator, while ensuring that
        // users can't accidentally hit return to send a single-char message
        // (since Messages special-cases space-only messages). The NUL byte
        // is another option that doesn't get sent to the server, but it
        // shows up client-side as a ghost message.
        let url = try MessagesDeepLink(threadID: threadID, body: isTyping ? " " : nil).url()
        
        try prepareForAutomation()
        defer { finishedAutomation() }
        
        try withActivation(openBefore: url) {
            if isTyping { return } // no further action required
            
            try ensureSelectedThread(threadID: threadID)
            
            try elements.messageBodyField.value(assign: "")
        }
    }
    
    func sendTypingStatus(threadID: String, isTyping: Bool) throws {
        if !isTyping {
            elideStopTyping = false
            Task {
                try await Task.sleep(nanoseconds: 100 * 1_000_000)
                if self.elideStopTyping {
                    log.debug("Stop typing elided")
                    self.elideStopTyping = false
                    return
                }
                try _sendTypingStatus(threadID: threadID, isTyping: isTyping)
            }
            return
        }
        try _sendTypingStatus(threadID: threadID, isTyping: isTyping)
    }
    
    private func focusMessageField(_ messageField: Accessibility.Element) {
        try? retry(withTimeout: 0.8, interval: 0.1) {
            // this doesn't ever focus in compose thread for some reason
            try messageField.isFocused(assign: true)
            if Defaults.isSelectedThreadCellCompose() { return }
            guard try messageField.isFocused() else {
                throw ErrorMessage("Could not focus message field")
            }
        }
    }
    
    private func messageFieldValue(_ messageField: Accessibility.Element) throws -> String {
        do {
            if MacOSVersion.isAtLeast(.ventura) {
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
    
    private func assignToMessageField(_ messageField: Accessibility.Element, text: String) throws {
        try retry(withTimeout: 1, interval: 0.1) {
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
    
    private func sendMessageInField(_ messageField: Accessibility.Element) throws {
        log.debug("\(#function): focusing field and pressing return")
        focusMessageField(messageField) // focus is partially redundant, hitting enter without focus works too unless another text field is focused
        try keyPresser.return() // in some random cases hitting enter will not send the message (even without automation), until the message input is clicked/focused
        log.debug("\(#function): completed initial attempt")
        
        do {
            log.debug("\(#function): will now attempt to verify the send")
            
            try retry(withTimeout: 1.5, interval: 0.1) {
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
                    
                    self.focusMessageField(messageField)
                    try? self.keyPresser.return()
                } else if attempt == 6 {
                    log.debug("\(#function): focusing and pressing enter again (alt. strategy)")
                    
                    try? messageField.press()
                    try? self.keyPresser.return()
                }
            }
            
            log.debug("\(#function): successfully verified the send")
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
    
    private func closeReplyTranscriptView(wait: Bool) throws {
        guard let rtv = try? elements.replyTranscriptView else { return }
        log.debug("calling replyTranscriptView.cancel()")
        try rtv.cancel()
        func waitForReplyTranscriptsClose() throws {
            try retry(withTimeout: 1.2, interval: 0.1) {
                guard let pValue = try? elements.messageBodyField.placeholderValue(),
                      pValue == LocalizedStrings.imessage || pValue == LocalizedStrings.textMessage else {
                    throw ErrorMessage("replyTranscriptView visible")
                }
            }
            Thread.sleep(forTimeInterval: 0.4) // wait for animation still
        }
        if wait { try waitForReplyTranscriptsClose() }
    }
    
    private func waitUntilReplyTranscriptVisible() throws {
        log.debug("waitUntilReplyTranscriptVisible")
        try retry(withTimeout: 1.2, interval: 0.1) {
            guard let pValue = try? elements.messageBodyField.placeholderValue(),
                  pValue != LocalizedStrings.imessage && pValue != LocalizedStrings.textMessage else {
                throw ErrorMessage("replyTranscriptView not visible")
            }
        }
    }
    
    private func sendReplyWithoutOverlay(threadID: String, quotedMessage: MessageCell, text: String?, filePath: String?) throws {
        try withMessageCell(threadID: threadID, messageCell: quotedMessage) {
            let replyAction = try messageAction(messageCell: $0, action: .reply)
            try replyAction()
            let messageField = try elements.messageBodyField
            if let text {
                try assignToMessageField(messageField, text: text)
                try sendMessageInField(messageField)
            } else if let filePath {
                try pasteFileInBodyFieldAndSend(messageField, filePath: filePath)
            }
        }
    }
    
    var elideStopTyping = false
    
    // this method has a lot of combinations, test carefully
    func sendMessage(threadID: String?, addresses: [String]?, text: String?, filePath: String?, quotedMessage: MessageCell?) throws {
        let startTime = Date()
        defer { log.debug("sendMessage took \(startTime.timeIntervalSinceNow * -1000)ms") }
        
        if let threadID, quotedMessage == nil { // fast path using OSA
            do {
                if let text {
                    if !text.contains("@"), !containsLink(text) { // no mentions and no links
                        try OSA.send(threadID: threadID, text: text)
                        return
                    }
                } else if let filePath {
                    // we don't always use OSA for files bc send file is randomly unreliable
                    if !MacOSVersion.isAtLeast(.monterey) { // messages.app in big sur doesn't correctly paste the file
                        try OSA.send(threadID: threadID, filePath: filePath)
                        return
                    }
                }
            } catch {
                reportToSentry?("osa err: \(error)")
                // fall back to regular send
            }
        }
        
        elideStopTyping = true
        
        let url: URL
        if let quotedMessage {
            url = try MessagesDeepLink.message(guid: quotedMessage.messageGUID, overlay: quotedMessage.overlay).url()
        } else if let threadID {
            url = try MessagesDeepLink(threadID: threadID, body: text).url()
        } else if let addresses {
            url = try MessagesDeepLink.addresses(addresses, body: text).url()
        } else {
            throw ErrorMessage("not implemented")
        }
        
        try prepareForAutomation()
        defer { finishedAutomation() }
        
        // this isn't reliable so we use pasteFileInBodyFieldAndSend:
        // if let filePath {
        //     guard let address = threadIDToAddress(threadID) else { throw ErrorMessage("invalid threadID") }
        //     try withAllWindowsClosed {
        //         try DraftsManager.saveDraft(address: String(address), filePath: filePath)
        //     }
        // }
        if let quotedMessage, !quotedMessage.overlay, let threadID = threadID {
            return try sendReplyWithoutOverlay(threadID: threadID, quotedMessage: quotedMessage, text: text, filePath: filePath)
        }
        
        if quotedMessage == nil { try? closeReplyTranscriptView(wait: true) } // needed even when opening deep link
        
        try withActivation(openBefore: url) {
            if let threadID { try ensureSelectedThread(threadID: threadID) }
            
            if quotedMessage != nil {
                if #available(macOS 26, *) {
                    try revealReplyTranscriptViaMenu()
                }
                try waitUntilReplyTranscriptVisible()
            }
            if Defaults.isSelectedThreadCellCompose() {
                // since this is a new thread not in contacts, it may take a while for messages app to resolve that the address is imessage and not just sms
                log.debug("waiting 3s for address to resolve")
                Thread.sleep(forTimeInterval: 3)
            }
            
            let messageField = try elements.messageBodyField
            if let text {
                if quotedMessage != nil { // text has to be manually assigned when quoted since ?body in deep link doesn't take any effect
                    try assignToMessageField(messageField, text: text)
                }
                try sendMessageInField(messageField)
            } else if let filePath {
                try pasteFileInBodyFieldAndSend(messageField, filePath: filePath)
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
    func closeAllWindows() throws {
        try elements.mainWindow.closeWindow()
        try elements.app.appWindows().forEach { try $0.closeWindow() }
    }
    
    func withAllWindowsClosed(perform: () throws -> Void) throws {
        try closeAllWindows()
        try perform()
        _ = try elements.mainWindow // accessing will open it
    }
    
    func assignFileToBodyField(filePath: String) throws {
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url)
        print(data, url)
        
        let myString = "something"
        let myAttrString = NSAttributedString(string: myString, attributes: [:])
        let mas = NSMutableAttributedString()
        mas.append(myAttrString)
        
        let messageField = try elements.messageBodyField
        try messageField.value(assign: url) // no op
        try messageField.value(assign: mas) // illegalArgument
        try messageField.value(assign: data) // cannotComplete
        
        try messageField.value(assign: "\u{fffc}") // obj replacement char
        try messageField.value(assign: url)
    }
#endif
    
    func pasteFileInBodyFieldAndSend(_ messageField: Accessibility.Element, filePath: String) throws {
        let fileURL = URL(fileURLWithPath: filePath)
        var messageField = messageField
        try? messageField.value(assign: "")
        focusMessageField(messageField) // focus is partially redundant, hitting ⌘ V without focus works too unless another text field is focused
        let pasteboard = NSPasteboard.general
        try pasteboard.withRestoration {
            pasteboard.setString(fileURL.relativeString, forType: .fileURL)
            try keyPresser.commandV()
            try retry(withTimeout: 2, interval: 0.05) {
                let charCountResult = Result { try messageField.noOfChars() }
                guard case let .success(charCount) = charCountResult else {
                    messageField = try elements.messageBodyField
                    throw ErrorMessage("cannot get char count: \(charCountResult)")
                }
                // 2 for <OBJ_REPLACEMENT_CHAR> and \n
                guard charCount == 2 else {
                    messageField = try elements.messageBodyField
                    throw ErrorMessage("file was not pasted: \(charCountResult)")
                }
            }
            try sendMessageInField(messageField)
        }
    }
    
    var lastActivate: Date?
    var messagesIsManuallyActivated = false
    // when the user manually cmd+tab's or clicks the Messages dock icon,
    // we want to actually show the app
    private func activateMessages() {
        do {
            lastActivate = Date()
            messagesIsManuallyActivated = true
            log.debug("activateMessages")
            // we use getMainWindow() instead of mainWindow to not reopen the window if it's not present
            if Defaults.shouldCoordinateWindow, let window = elements.getMainWindow() {
                try windowCoordinator.reset(window)
                try windowCoordinator.userManuallyActivated(application.controlledRunningApplication)
            }
        } catch {
            log.error("couldn't unhide messages window caused by user activation: \(error)")
        }
        do {
            try phtConnection?.setMessagesHidden(false)
        } catch {
            log.error("failed to show messages app via pht: \(error)")
        }
    }
    
    private func deactivateMessages() {
        do {
            lastActivate.map { log.debug("used messages.app for \($0.timeIntervalSinceNow * -1)s") }
            messagesIsManuallyActivated = false
            log.debug("deactivateMessages")
            // we use getMainWindow() instead of mainWindow to not reopen the window if it's not present
            let window = elements.getMainWindow()
            if Defaults.shouldCoordinateWindow {
                try windowCoordinator.userManuallyDeactivated(application.controlledRunningApplication)
            }
            try? closeAllNonMainWindows()
            if window != nil {
                resetWindow()
            }
        } catch {
            log.error("couldn't hide messages window caused by user activation: \(error)")
        }
    }
    
    func activityStatus() -> [ActivityStatus] {
#if DEBUG
        let startTime = Date()
        defer { log.debug("activityStatus took \(startTime.timeIntervalSinceNow * -1000)ms") }
#endif
        func getTV() -> Accessibility.Element? {
            if let cached = elements.cachedTranscriptView, cached.isInViewport {
                return cached
            }
            return try? elements.transcriptView
        }
        guard let transcript = getTV(),
              let count = try? transcript.children.count() else {
            return [.unknown]
        }
        let cellsToCheck: [Accessibility.Element]
        switch count {
            case 0:
                return [.unknown]
            case 1:
                guard let elt = try? transcript.children[0] else {
                    return [.unknown]
                }
                cellsToCheck = [elt]
            default:
                // pre-monterey, there can only be one <typing cell>
                // post-monterey, there can be <typing cell>, "...has notifications silenced", "Notify Anyway"
                let lastN = MacOSVersion.isAtLeast(.monterey) ? 3 : 1
                guard let elts = try? transcript.children(range: (count - lastN)..<count), elts.count == lastN else {
                    return [.unknown]
                }
                cellsToCheck = elts
        }
        // AXStaticText, localizedDescription="￼ Steve has notifications silenced"
        // AXButton, localizedDescription="Notify Anyway"
        let dndFlag: ActivityStatus? = {
            guard MacOSVersion.isAtLeast(.monterey) else { return nil }
            for elt in cellsToCheck.reversed() {
                guard let child = try? elt.children[0] else { continue }
                if (try? child.role()) == AXRole.button,
                   (try? child.localizedDescription()) == LocalizedStrings.notifyAnyway {
                    return .dndCanNotify
                } else if (try? child.role()) == AXRole.staticText,
                          (try? child.localizedDescription())?.hasSuffix(LocalizedStrings.hasNotificationsSilencedSuffix) == true {
                    return .dnd
                }
            }
            return nil
        }()
        let isTyping = cellsToCheck.contains { elt in
            let childCount = try? elt.children.count()
            // kabir: children can briefly be 0 for newly sent messages as well, so that by itself isn't a good enough heuristic
            if childCount != 0 { return false }
            if (try? elt.localizedDescription()) == LocalizedStrings.buddyTyping { return true }
            // kb: the following return statement should probably be removed but i haven't tested on Big Sur to Ventura 13.2 so keeping just in case
            return (try? elt.roleDescription().isEmpty) != false
        }
        let flags: [ActivityStatus] = (isTyping ? [.typing] : [.notTyping]) + (dndFlag.flatMap { [$0] } ?? [])
        return flags
    }
    
    func notifyAnyway(threadID: String) throws {
        let url = try MessagesDeepLink(threadID: threadID, body: nil).url()
        
        try prepareForAutomation()
        defer { finishedAutomation() }
        
        try withActivation(openBefore: url) {
            try ensureSelectedThread(threadID: threadID)
            try elements.notifyAnywayButton.press()
        }
    }
    
    /*
     activityLock.lock() called by:
     MessagesController.observe()
     MessagesController.sendMessage()
     MessagesController.setReaction()
     MessagesController.sendTypingStatus()
     MessagesController.notifyAnyway()
     MessagesController.toggleThreadRead()
     MessagesController.muteThread()
     MessagesController.deleteThread()
     */
    private let activityLock = UnfairLock()
    
    private func waitForLayoutChange(timeout: TimeInterval) {
        let beganWaiting = Date()
        
        while Date().timeIntervalSince(beganWaiting) < timeout {
            guard let lastLayoutChange = lifecycleObserver.lastLayoutChange.read() else {
                continue
            }
            if lastLayoutChange > beganWaiting {
                log.debug("observed layout change, exiting wait loop")
                return
            }
            Thread.sleep(forTimeInterval: 0.05) // 50ms
        }
        
        log.error("didn't observe a layout change within \(timeout)s, continuing anyways")
    }
    
    /// returns a callback meant to be assigned to a `PassivelyAwareDispatchQueue` that observes a single thread once
    /// the passively aware dispatch queue should call the returned callback repeatedly
    func idleCallback(observingThreadID threadID: String, statusSender: @escaping ([ActivityStatus]) -> Void) throws -> ((Quiescence) throws -> Void) {
        let url = try MessagesDeepLink(threadID: threadID, body: nil).url()
        
        return { [weak self] quiescence in
            guard let self else { return }
            
            guard !messagesIsManuallyActivated else {
                log.debug("not observing activity, Messages is manually activated")
                return
            }
            
            guard occlusionMonitor.visible else {
#if DEBUG
                log.debug("not observing activity, window occluded")
#endif
                return
            }
            
            guard isValid else {
#if DEBUG
                log.debug("not observing activity, controller is invalid")
#endif
                return
            }
            
            if quiescence == .began || lastThreadIDOpenedForObservation.read() != threadID {
                log.debug("activity: entered idle state or thread id changed, opening deep link")
                try prepareForAutomation()
                defer { finishedAutomation() }
                
                try application.openDeepLink(url)
                log.debug("activity: opened deep link, waiting for layout change")
                lastThreadIDOpenedForObservation.withLock { $0 = threadID }
                waitForLayoutChange(timeout: 0.5)
            }
            
            guard activityLock.tryLock() else { return }
            defer { activityLock.unlock() }
            
            let statusToSend = activityStatus()
            guard lastSentActivityStatus != statusToSend || (statusToSend.contains(.typing) && lastSentActivityStatusTime.map { $0.timeIntervalSinceNow * -1 > 30 } == true) else {
#if DEBUG
                log.debug("activity: same activity or too recent, skipping activity update")
#endif
                return
            }
            defer {
                lastSentActivityStatus = statusToSend
                lastSentActivityStatusTime = Date()
            }
#if DEBUG
            log.debug("activity: sending: \(statusToSend)")
#endif
            statusSender(statusToSend)
        }
    }
    
    private var isDisposed = false
    
    func dispose() {
        log.info("disposing MessagesController")
        guard !isDisposed else { return }
        isDisposed = true
        pollingConveyor?.cancel()
        application.controlledRunningApplication.terminate()
    }
    
    deinit {
        log.info("MessagesController deinit")
        dispose()
    }
}

@available(macOS 11, *)
extension MessagesController {
    class OcclusionMonitor {
        var visible: Bool = true
        
        private var cancellable: AnyCancellable?
        
        init() {
            cancellable = NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification, object: nil).sink { notification in
                log.trace("didChangeOcclusionStateNotification \(notification)")
                guard let window = notification.object as? NSWindow else { return }
                let className = NSStringFromClass(type(of: window))
                guard className == "ElectronNSWindow" || className == "TextsSwift.CustomWindow" else { return }
                self.visible = window.occlusionState.contains(.visible)
            }
        }
        
        deinit {
            cancellable?.cancel()
        }
    }
}

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

struct MessageCell: Codable {
    let messageGUID: String
    let offset: Int
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
