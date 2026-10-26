import AppKit
import AccessibilityControl
import ApplicationServices
import Darwin
import IMessagePrivateSPI
import ObjectiveC.runtime
import Testing
import WindowControl
@testable import IMessage

/// Experimental only: controls a newly launched secondary Messages process and
/// creates one intrinsically unknown Space. No message is sent or selected.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMESSAGE_RUN_UNKNOWN_SPACE_RESEARCH"] == "1"))
@MainActor
func secondaryMessagesUnknownSpaceResearchSmoke() throws {
    try #require(AXIsProcessTrusted(), "Unknown-Space research requires Accessibility permission")
    Defaults.registerDefaults()
    let spi = try UnknownSpaceResearchSPI()
    let bridge = try #require(IMPrivateSPISpaceBridgeCreate())
    let desktop = IMPrivateSPIActiveSpace()
    let baselineManaged = try unknownResearchManagedSpaceIDs()
    let existingApps = NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID)
    let previousFrontmost = NSWorkspace.shared.frontmostApplication
    defer {
        if let previousFrontmost {
            NSRunningApplication(processIdentifier: previousFrontmost.processIdentifier)?.activate(options: [.activateAllWindows])
        }
    }
    let app = try runSmokeWorker {
        try MessagesInstanceTarget.launchSecondaryInstance(initialDeepLink: MessagesDeepLink.compose.url())
    }
    try #require(!existingApps.contains { $0.processIdentifier == app.processIdentifier })
    var unknown: UInt64 = 0
    var targetWindow: UInt32?
    var originalSpaces: [UInt64] = []
    var restored = false
    var terminated = false
    defer {
        // This also handles partial failures after adding unknown membership but
        // before removing the original desktop. Never touch any other process.
        if !restored, let targetWindow, let original = originalSpaces.first {
            unknownResearchCleanup("restore the secondary window") {
                app.hide()
                try #require(IMPrivateSPISpaceBridgeMoveWindow(bridge, targetWindow, original))
                if unknown != 0 { try spi.remove(window: targetWindow, from: [unknown], bridge: bridge) }
                try unknownResearchWait("restored window membership") {
                    try spi.spaces(for: targetWindow, mask: 15).sorted() == originalSpaces.sorted()
                }
            }
        }
        if !terminated {
            app.terminate()
            unknownResearchCleanup("terminate the secondary Messages process") {
                try unknownResearchWait("secondary process exit") { !unknownResearchProcessExists(app.processIdentifier) }
            }
        }
        if unknown != 0 {
            unknownResearchCleanup("destroy the research Space") {
                try #require(IMPrivateSPIActiveSpace() != unknown, "Do not destroy an active Space")
                _ = IMPrivateSPISpaceBridgeDestroySpace(bridge, unknown)
                try unknownResearchWait("research Space destruction") { try !spi.allSpaces().contains(unknown) }
            }
        }
    }

    // Launch is hidden. CG discovery must precede unhide; AX validates this exact
    // main-window ID later so an internal CG surface cannot produce a false pass.
    try unknownResearchWait("initial hidden Messages window") {
        targetWindow = try Window.listDescriptions(.all).filter {
            $0.owner == app.processIdentifier && $0.layer == 0 &&
                $0.bounds.width > 300 && $0.bounds.height > 200
        }.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }?.window.raw
        return targetWindow != nil
    }
    let window = try #require(targetWindow)
    originalSpaces = try spi.spaces(for: window, mask: 15)
    if originalSpaces.isEmpty {
        // A newly launched, hidden Messages window can be unassigned, just as
        // the production coordinator handles with originalSpaceIfUnassigned.
        try #require(baselineManaged.contains(desktop), "Start research from an ordinary desktop")
        originalSpaces = [desktop]
    }
    try #require(originalSpaces.count == 1, "Do not change a sticky or multi-Space window")
    let original = try #require(originalSpaces.first)
    unknown = try spi.createUnknown(bridge: bridge)
    try #require(unknown != 0 && unknown != original)
    try unknownResearchAssertClassification(spi: spi, unknown: unknown)
    try spi.add(window: window, to: unknown, bridge: bridge)
    try unknownResearchWait("unknown membership added") { try spi.spaces(for: window, mask: 15).contains(unknown) }
    try spi.remove(window: window, from: originalSpaces, bridge: bridge)
    try unknownResearchWait("exclusive unknown membership") { try spi.spaces(for: window, mask: 15) == [unknown] }
    #expect(try spi.spaces(for: window, mask: 7).isEmpty, "The existing mask-7 helper must not be used to verify unknown Spaces")
    #expect(IMPrivateSPIActiveSpace() == desktop)
    #expect(try !unknownResearchOnscreen(window))

    // The only unhide occurs after membership has been independently verified.
    app.unhide()
    let elements = MessagesAppElements(runningApp: app)
    try unknownResearchWait("AX main window in unknown Space") {
        (try? elements.getMainWindow()?.window().raw) == window
    }
    #expect(try elements.mainWindow.window().raw == window)
    try unknownResearchExerciseSearch(elements: elements)
    #expect(try !unknownResearchOnscreen(window))
    #expect(try spi.spaces(for: window, mask: 15) == [unknown])
    #expect(IMPrivateSPIActiveSpace() == desktop)

    if ProcessInfo.processInfo.environment["IMESSAGE_RESEARCH_RESTART_DOCK"] == "1" {
        let previousDock = Dock.pid
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        try unknownResearchWait("Dock restart") { Dock.pid != nil && Dock.pid != previousDock }
        try unknownResearchAssertClassification(spi: spi, unknown: unknown)
        #expect(IMPrivateSPIActiveSpace() == desktop)
        #expect(try spi.spaces(for: window, mask: 15) == [unknown])
        #expect(try elements.mainWindow.window().raw == window)
        try unknownResearchExerciseSearch(elements: elements)
        #expect(try !unknownResearchOnscreen(window))
    }

    let holdSeconds = max(0, min(30, Int(ProcessInfo.processInfo.environment["IMESSAGE_RESEARCH_HOLD_SECONDS"] ?? "0") ?? 0))
    print("UNKNOWN_SPACE_RESEARCH_READY space=\(unknown) window=\(window) pid=\(app.processIdentifier) desktop=\(desktop) holdSeconds=\(holdSeconds)")
    fflush(nil)
    if holdSeconds > 0 { pumpSmokeRunLoop(for: TimeInterval(holdSeconds)) }

    // A genuine unknown Space can remain parked while idle. Exercise native
    // activation before the explicit reveal rather than carrying over the user-
    // Space coordinator's hide-and-return-idle workaround.
    try MessagesDockSuppression.restore(app)
    try #require(app.activate(options: [.activateAllWindows]))
    pumpSmokeRunLoop(for: 0.5)
    #expect(IMPrivateSPIActiveSpace() == desktop, "Native activation must not switch to the unknown Space")
    print("UNKNOWN_SPACE_NATIVE_ACTIVATION desktop=\(IMPrivateSPIActiveSpace()) membership=\(try spi.spaces(for: window, mask: 15))")
    try #require(IMPrivateSPISpaceBridgeMoveWindow(bridge, window, original))
    try spi.remove(window: window, from: [unknown], bridge: bridge)
    try unknownResearchWait("exact original membership") {
        try spi.spaces(for: window, mask: 15).sorted() == originalSpaces.sorted()
    }
    restored = true
    #expect(try elements.mainWindow.window().raw == window)
    #expect(IMPrivateSPIActiveSpace() == desktop)
    app.terminate()
    try unknownResearchWait("secondary process termination") { !unknownResearchProcessExists(app.processIdentifier) }
    terminated = true
    try #require(IMPrivateSPISpaceBridgeDestroySpace(bridge, unknown))
    try unknownResearchWait("unknown Space destruction") { try !spi.allSpaces().contains(unknown) }
    unknown = 0
    #expect(try unknownResearchManagedSpaceIDs() == baselineManaged)
    #expect(IMPrivateSPIActiveSpace() == desktop)
    #expect(existingApps.allSatisfy { unknownResearchProcessExists($0.processIdentifier) })
}

@MainActor
private func unknownResearchExerciseSearch(elements: MessagesAppElements) throws {
    let search = try elements.searchField
    let previous = try #require(try search.value() as? String)
    defer { try? search.value(assign: previous) }
    let query = "Beeper unknown Space research \(UUID().uuidString)"
    try search.value(assign: query)
    try unknownResearchWait("AX search value write/read") { try search.value() as? String == query }
    try search.value(assign: previous)
    #expect(try search.value() as? String == previous)
}

@MainActor
private func unknownResearchAssertClassification(spi: UnknownSpaceResearchSPI, unknown: UInt64) throws {
    try #require(spi.spaceType(unknown) == 3)
    let values = try spi.values(unknown)
    try #require(values["ManagedSpaceID"] == nil)
    try #require(try !unknownResearchManagedSpaceIDs().contains(unknown))
}

private func unknownResearchManagedSpaceIDs() throws -> Set<UInt64> {
    let displays = try #require(IMPrivateSPICopyManagedDisplaySpaces())
    try #require(!displays.isEmpty)
    return Set(displays.flatMap { record -> [UInt64] in
        let spaces = (record["Spaces"] as? [[String: Any]] ?? []) +
            ((record["Current Space"] as? [String: Any]).map { [$0] } ?? [])
        return spaces.compactMap {
            ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? ($0["id64"] as? NSNumber)?.uint64Value
        }
    })
}

@MainActor
private func unknownResearchWait(_ description: String, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if try condition() { return }
        pumpSmokeRunLoop(for: 0.02)
    }
    try #require(try condition(), Comment(rawValue: "Timed out waiting for \(description)"))
}

private func unknownResearchOnscreen(_ window: UInt32) throws -> Bool {
    try Window.listDescriptions(.onScreen).contains { $0.window.raw == window }
}

private func unknownResearchProcessExists(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}

@MainActor
private func unknownResearchCleanup(_ description: String, _ action: () throws -> Void) {
    do { try action() }
    catch { Issue.record(Comment(rawValue: "Could not \(description): \(error)")) }
}

/// Runtime bindings stay in this opt-in research test, not the production SPI.
private struct UnknownSpaceResearchSPI {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias WindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopySpaces = @convention(c) (Int32, Int32) -> Unmanaged<CFArray>?
    private typealias GetType = @convention(c) (Int32, UInt64) -> Int32
    private typealias CopyValues = @convention(c) (Int32, UInt64) -> Unmanaged<CFDictionary>?
    private let connection: Int32
    private let windowSpaces: WindowSpaces
    private let copySpaces: CopySpaces
    private let getType: GetType
    private let copyValues: CopyValues

    init() throws {
        let image = try #require(dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL))
        func bind<T>(_ name: String, as type: T.Type) throws -> T {
            unsafeBitCast(try #require(dlsym(image, name), Comment(rawValue: "Missing \(name)")), to: T.self)
        }
        connection = try bind("SLSMainConnectionID", as: MainConnection.self)()
        try #require(connection != 0)
        windowSpaces = try bind("SLSCopySpacesForWindows", as: WindowSpaces.self)
        copySpaces = try bind("SLSCopySpaces", as: CopySpaces.self)
        getType = try bind("SLSSpaceGetType", as: GetType.self)
        copyValues = try bind("SLSSpaceCopyValues", as: CopyValues.self)
    }

    func spaces(for window: UInt32, mask: Int32) throws -> [UInt64] {
        let result = try #require(windowSpaces(connection, mask, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber])
        return result.map(\.uint64Value)
    }

    func allSpaces() throws -> Set<UInt64> {
        let result = try #require(copySpaces(connection, 15)?.takeRetainedValue() as? [NSNumber])
        return Set(result.map(\.uint64Value))
    }

    func spaceType(_ space: UInt64) -> Int32 { getType(connection, space) }

    func values(_ space: UInt64) throws -> NSDictionary {
        let dictionary: CFDictionary = try #require(copyValues(connection, space)?.takeRetainedValue())
        return dictionary as NSDictionary
    }

    func createUnknown(bridge: NSObject) throws -> UInt64 {
        let allocated = try allocate("SLSBridgedSpaceCreateOperation")
        let object = allocated.takeUnretainedValue()
        let selector = NSSelectorFromString("initWithOptions:values:")
        typealias Initialize = @convention(c) (NSObject, Selector, UInt32, NSDictionary) -> Unmanaged<NSObject>?
        let initialize: Initialize = try implementation(object, selector: selector)
        let values: NSDictionary = ["type": 3, "uuid": "Beeper-Unknown-Research-\(UUID().uuidString)"]
        let operation = try #require(initialize(object, selector, 1, values)?.takeRetainedValue())
        let perform = NSSelectorFromString("performSynchronousBridgedWindowManagementOperation:")
        typealias Perform = @convention(c) (NSObject, Selector, NSObject) -> Unmanaged<NSObject>?
        let invoke: Perform = try implementation(bridge, selector: perform)
        let result = try #require(invoke(bridge, perform, operation)?.takeUnretainedValue())
        let getter = NSSelectorFromString("spaceID")
        typealias GetSpace = @convention(c) (NSObject, Selector) -> UInt64
        let getSpace: GetSpace = try implementation(result, selector: getter)
        return getSpace(result, getter)
    }

    func add(window: UInt32, to space: UInt64, bridge: NSObject) throws {
        let allocated = try allocate("SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation")
        let object = allocated.takeUnretainedValue()
        let selector = NSSelectorFromString("initWithSpaceID:windows:options:")
        typealias Initialize = @convention(c) (NSObject, Selector, UInt64, NSArray, UInt32) -> Unmanaged<NSObject>?
        let initialize: Initialize = try implementation(object, selector: selector)
        let operation = try #require(initialize(object, selector, space, [NSNumber(value: window)] as NSArray, 0)?.takeRetainedValue())
        try submit(operation, bridge: bridge)
    }

    func remove(window: UInt32, from spaces: [UInt64], bridge: NSObject) throws {
        let allocated = try allocate("SLSBridgedRemoveWindowsFromSpacesOperation")
        let object = allocated.takeUnretainedValue()
        let selector = NSSelectorFromString("initWithWindows:spaces:")
        typealias Initialize = @convention(c) (NSObject, Selector, NSArray, NSArray) -> Unmanaged<NSObject>?
        let initialize: Initialize = try implementation(object, selector: selector)
        let operation = try #require(initialize(object, selector, [NSNumber(value: window)] as NSArray,
                                              spaces.map { NSNumber(value: $0) } as NSArray)?.takeRetainedValue())
        try submit(operation, bridge: bridge)
    }

    private func submit(_ operation: NSObject, bridge: NSObject) throws {
        let selector = NSSelectorFromString("performAsynchronousBridgedWindowManagementOperation:")
        typealias Submit = @convention(c) (NSObject, Selector, NSObject) -> Void
        let invoke: Submit = try implementation(bridge, selector: selector)
        invoke(bridge, selector, operation)
    }

    private func allocate(_ name: String) throws -> Unmanaged<NSObject> {
        let cls: AnyClass = try #require(NSClassFromString(name))
        let selector = NSSelectorFromString("alloc")
        let method = try #require(class_getClassMethod(cls, selector))
        typealias Allocate = @convention(c) (AnyClass, Selector) -> Unmanaged<NSObject>
        return unsafeBitCast(method_getImplementation(method), to: Allocate.self)(cls, selector)
    }

    private func implementation<T>(_ object: NSObject, selector: Selector) throws -> T {
        let cls: AnyClass = try #require(object_getClass(object))
        let method = try #require(class_getInstanceMethod(cls, selector))
        return unsafeBitCast(method_getImplementation(method), to: T.self)
    }
}
