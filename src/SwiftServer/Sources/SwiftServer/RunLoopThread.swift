import Foundation
import Logging
import SwiftServerFoundation
import Collections

private let log = Logger(swiftServerLabel: "runloop")

// we need a run loop for polling (and for any future AX observers) since Node
// doesn't offer us one (since it uses its own uv loop which is incompatible
// with NS/CFRunLoop). therefore we create a background thread with a run loop.
// note that doing so on a DispatchQueue would be very inefficient and so we
// create our own thread for it; see https://stackoverflow.com/a/38001438/3769927 and
// https://forums.swift.org/t/runloop-main-or-dispatchqueue-main-when-using-combine-scheduler/26635/4

final class RunLoopThread<WorkItem>: Thread {
    typealias Initializer = (_ rlt: RunLoopThread<WorkItem>) -> Void
    typealias WorkItemHandler = @Sendable (_ item: WorkItem) -> Void

    private var source: RunLoopSource<WorkItem>
    private var sourceLock = UnfairLock()
    private var initializer: Initializer?
    private var handler: WorkItemHandler

    init(
        name: String? = nil,
        oneTimeInitialization initializer: @escaping Initializer,
        handlingWorkItemsWithinRunLoop handler: sending @escaping WorkItemHandler
    ) {
        // safe to retain self inside initialize because it's nil'd out
        // once main() is called
        self.initializer = initializer
        source = RunLoopSource()
        self.handler = handler

        super.init()
        self.name = name ?? "SwiftServer RunLoopThread"
    }

    override func main() {
        source.addToRunLoop(.current)
        log.debug("performing one time initialization for run loop thread")
        initializer?(self)
        initializer = nil

        while !isCancelled {
            for workItem in source.drain() {
                handler(workItem)
            }

            // run the loop for a finite period of time, otherwise once the
            // source is removed we'll be stuck here and never get to the next
            // `isCancelled` check
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1))
        }
    }
}

extension RunLoopThread {
    func enqueue(_ item: WorkItem) {
        sourceLock.withLock { source.enqueue(item) }
    }
}

// this class is _NOT_ thread-safe, the assumption is that this is only touched
// by a single thread at a time (that is, the thread with a valid `RunLoop`)
// https://gist.github.com/thomsmed/28164a6052fba8eb389ab25507011138
final class RunLoopSource<WorkItem> {
    private var guts: CFRunLoopSource
    private weak var associatedRunLoop: RunLoop?
    private var pendingWorkItems = Deque<WorkItem>()

    init() {
        var context = CFRunLoopSourceContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil,
            equal: nil,
            hash: nil,
            schedule: { _, runLoop, mode in },
            cancel: { _, runLoop, mode in },
            perform: { _ in }
        )

        log.debug("creating run loop source")
        guts = CFRunLoopSourceCreate(nil, 0, &context)
    }

    func drain() -> some Sequence<WorkItem> {
        guard !pendingWorkItems.isEmpty else { return Deque() }
        defer { pendingWorkItems = [] }
        return pendingWorkItems
    }

    func addToRunLoop(_ runLoop: RunLoop = .current) {
        log.debug("run loop source is being added to run loop \(runLoop), associating")
        associatedRunLoop = runLoop
        CFRunLoopAddSource(runLoop.getCFRunLoop(), guts, .defaultMode)
    }

    func enqueue(_ item: WorkItem) {
#if DEBUG
        log.debug("adding work item \(item) to run loop source")
#endif
        pendingWorkItems.append(item)
        signalAndWakeUpRunLoop()
    }

    private func signalAndWakeUpRunLoop() {
#if DEBUG
        log.debug("signalling run loop source")
#endif
        CFRunLoopSourceSignal(guts)

        if let associatedRunLoop {
#if DEBUG
            log.debug("run loop source is going to wake up associated run loop")
#endif
            CFRunLoopWakeUp(associatedRunLoop.getCFRunLoop())
        }
    }

    deinit {
        log.debug("invalidating run loop source")
        CFRunLoopSourceInvalidate(guts)
    }
}
