import Sentry
import Logging

private let log = Logger(swiftServerLabel: "sentry")

public func breadcrumb(
    _ message: String,
    category: String,
    type: String = "default",
    level: SentryLevel = .info,
    data: [String: Any]? = nil,
) {
    let crumb = Breadcrumb()
    crumb.level = level
    crumb.category = category
    crumb.type = type
    crumb.data = data
    crumb.message = message
    crumb.origin = "platform-imessage"
    
    switch level {
    case .none:
        log.notice("[bc] [none] [\(category)] \(message)")
    case .debug:
        log.debug("[bc] [debug] [\(category)] \(message)")
    case .info:
        log.info("[bc] [info] [\(category)] \(message)")
    case .warning:
        log.warning("[bc] [warning] [\(category)] \(message)")
    case .error:
        log.error("[bc] [error] [\(category)] \(message)")
    case .fatal:
        log.error("[bc] [fatal] [\(category)] \(message)")
    @unknown default:
        log.info("[bc] [?] [\(category)] \(message)")
    }
    
    SentrySDK.addBreadcrumb(crumb)
}

// shouldn't actually be public, but we want @inlinable at use sites
@TaskLocal
public var _currentParentSpan: (any Span)?

@inlinable
public var currentlyActiveSpan: (any Span)? {
    _currentParentSpan ?? SentrySDK.span
}

// create a really tiny span
//
// purely so it can appear interleaved with other trace output, instead of
// breadcrumbs which are off to the side
public func landmark(
    op: String,
    description: String,
    status: SentrySpanStatus = .ok,
    tags: [String: String] = [:],
    data: [String: Any] = [:],
) {
    guard let span = currentlyActiveSpan else {
        return
    }
   
    let child = span.startChild(operation: op, description: description)
    for (key, value) in tags {
        child.setTag(value: value, key: key)
    }
    for (key, value) in data {
        child.setData(value: value, key: key)
    }
    child.finish(status: status)
}

public func captureMessage(_ message: String, level: SentryLevel = .debug) {
    // doesn't forcibly capture stack trace of the current thread because we aren't calling `capture(error:)`
    // (desired for perf, as we'll call this frequently so it can appear in traces)
    let event = Event()
    event.level = level
    event.message = SentryMessage(formatted: message)
    SentrySDK.capture(event: event)
}

public struct SentryTags {}

extension SentryTags {
    public static var misfireStrategy: String { "misfire.strategy" }
    public static var misfireWaiterType: String { "misfire.waiter.type" }
    public static var misfireWaiterBegan: String { "misfire.waiter.began" }
    public static var misfireDefaultComposeThread: String { "misfire.default.compose_thread" }
    public static var misfireChatType: String { "misfire.chat.type" }
    public static var sendHasOverlay: String { "send.has_overlay" }
    public static var sendHasQuotedMessage: String { "send.has_quoted_message" }
    public static var sendHasFilePath: String { "send.has_file_path" }
}

public extension Sentry.Span {
    subscript(tag: KeyPath<SentryTags.Type, String>) -> String? {
        get {
            let key = SentryTags.self[keyPath: tag]
            return self.tags[key]
        }
        
        set(newValue) {
            let key = SentryTags.self[keyPath: tag]
            if let newValue {
                setTag(value: newValue, key: key)
            } else {
                removeTag(key: key)
            }
        }
    }
}

public extension Sentry.Span? {
    @inlinable
    func around<T>(_ work: () throws -> T) rethrows -> T {
        do {
            if let self {
                return try $_currentParentSpan.withValue(self) {
                    let result = try work()
                    self.finish()
                    return result
                }
            } else {
                return try work()
            }
        } catch {
            // always capture the error, even if we didn't actually have a span to work with
            SentrySDK.capture(error: error)
            self?.finish(status: .internalError)
            throw error
        }
    }
}

@inlinable
public func withSpan<T>(
    op: String,
    description: String? = nil,
    _ work: () throws -> T,
    function: StaticString = #function,
    fileID: StaticString = #fileID,
    line: UInt = #line,
) rethrows -> T {
    let span = currentlyActiveSpan?.startChild(operation: op, description: description)
    span?.setData(value: "\(function)", key: "source.function")
    span?.setData(value: "\(fileID):\(line)", key: "source.file")

    return try span.around {
        try work()
    }
}

public func startSentry(deviceID: String?) {
    SentrySDK.start { options in
        options.dsn = "https://bbec929e3efac3317cc8b3b10802db83@o248881.ingest.us.sentry.io/4507211628216320"
        options.debug = false
        options.sendDefaultPii = false
        options.enableCaptureFailedRequests = false
        options.tracesSampleRate = 1
        options.add(inAppInclude: "SwiftServer")
        options.add(inAppInclude: "NodeAPI")
        options.enableSwizzling = false
        options.configureProfiling = {
            $0.lifecycle = .trace
            $0.sessionSampleRate = 1
        }
        options.initialScope = { scope in
#if DEBUG
            scope.setEnvironment("development")
#else
            scope.setEnvironment("production")
#endif
            scope.setTag(value: "imessage", key: "realm")
            if let deviceID {
                scope.setTag(value: deviceID, key: "device_id")
            }
            return scope
        }
        
        // avoid sampling stacks when sending messages, so we can send events to appear
        // within traces without them being expensive. exceptions and errors always get
        // stack traces regardless of this option
        //
        // https://github.com/getsentry/sentry-cocoa/blob/4a7a0054530b77ddc31ad8b69861c15d53746bf5/Sources/Sentry/SentryClient.m#L233
        options.attachStacktrace = false
    }
}
