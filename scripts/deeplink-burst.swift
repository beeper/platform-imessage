#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Foundation

enum SendMode: String {
    case noReply = "noReply"
    case queueReply = "queueReply"
    case waitForReply = "waitForReply"
}

struct Config {
    var mode: SendMode = .queueReply
    var urls: [URL] = []
    var count: Int = 20
    var delayMs: Int = 20
    var timeout: TimeInterval = 5
    var waitSeconds: TimeInterval = 5
    var bundleID: String = "com.apple.MobileSMS"
    var pid: pid_t?
    var shuffle: Bool = false
    var queueReplySerial: Bool = true
}

func printUsageAndExit(_ message: String? = nil) -> Never {
    if let message {
        fputs("error: \(message)\n\n", stderr)
    }
    let usage = """
    Usage:
      scripts/deeplink-burst.swift [options]

    Options:
      --mode <noReply|queueReply|waitForReply>   Default: queueReply
      --url <imessage:...>                       May be specified multiple times
      --urls-file <path>                         Read URLs (one per line)
      --count <n>                                Default: 20
      --delay-ms <n>                             Default: 20
      --timeout <seconds>                        Default: 5
      --wait-seconds <seconds>                   Default: 5 (queueReply only)
      --bundle-id <bundle>                       Default: com.apple.MobileSMS
      --pid <pid>                                Target specific Messages instance
      --shuffle                                  Shuffle URL order
      --queue-reply-batch                        For queueReply, send all events then wait for replies
      --help

    Examples:
      swift scripts/deeplink-burst.swift --mode queueReply --count 50 --delay-ms 5 --url "imessage:open?address=foo@bar.com&body=hi"
      swift scripts/deeplink-burst.swift --mode noReply --pid 12345 --url "imessage:open?address=foo@bar.com&body=hi"
      swift scripts/deeplink-burst.swift --mode queueReply --urls-file /path/to/urls.txt --shuffle
    """
    print(usage)
    exit(1)
}

func loadUrlsFile(_ path: String) throws -> [URL] {
    let data = try String(contentsOfFile: path, encoding: .utf8)
    var urls: [URL] = []
    for rawLine in data.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        if line.hasPrefix("#") { continue }
        guard let url = URL(string: line) else {
            throw NSError(domain: "deeplink-burst", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid URL in file: \(line)"])
        }
        urls.append(url)
    }
    return urls
}

func parseArgs() -> Config {
    var config = Config()
    var args = Array(CommandLine.arguments.dropFirst())

    func popValue(_ name: String) -> String {
        guard !args.isEmpty else { printUsageAndExit("missing value for \(name)") }
        return args.removeFirst()
    }

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--mode":
            let value = popValue(arg)
            guard let mode = SendMode(rawValue: value) else {
                printUsageAndExit("invalid mode: \(value)")
            }
            config.mode = mode
        case "--url":
            let value = popValue(arg)
            guard let url = URL(string: value) else {
                printUsageAndExit("invalid url: \(value)")
            }
            config.urls.append(url)
        case "--urls-file":
            let value = popValue(arg)
            do {
                let fileUrls = try loadUrlsFile(value)
                config.urls.append(contentsOf: fileUrls)
            } catch {
                printUsageAndExit("failed to read urls file: \(error)")
            }
        case "--count":
            let value = popValue(arg)
            guard let count = Int(value), count > 0 else {
                printUsageAndExit("invalid count: \(value)")
            }
            config.count = count
        case "--delay-ms":
            let value = popValue(arg)
            guard let delayMs = Int(value), delayMs >= 0 else {
                printUsageAndExit("invalid delay-ms: \(value)")
            }
            config.delayMs = delayMs
        case "--timeout":
            let value = popValue(arg)
            guard let timeout = Double(value), timeout > 0 else {
                printUsageAndExit("invalid timeout: \(value)")
            }
            config.timeout = timeout
        case "--wait-seconds":
            let value = popValue(arg)
            guard let wait = Double(value), wait >= 0 else {
                printUsageAndExit("invalid wait-seconds: \(value)")
            }
            config.waitSeconds = wait
        case "--bundle-id":
            config.bundleID = popValue(arg)
        case "--pid":
            let value = popValue(arg)
            guard let pid = Int32(value) else {
                printUsageAndExit("invalid pid: \(value)")
            }
            config.pid = pid
        case "--shuffle":
            config.shuffle = true
        case "--queue-reply-batch":
            config.queueReplySerial = false
        case "--help", "-h":
            printUsageAndExit()
        default:
            printUsageAndExit("unknown argument: \(arg)")
        }
    }

    if config.urls.isEmpty {
        printUsageAndExit("no URLs provided; use --url or --urls-file")
    }

    return config
}

func resolveTargetApp(bundleID: String, pid: pid_t?) -> NSRunningApplication? {
    if let pid {
        return NSRunningApplication(processIdentifier: pid)
    }
    let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    return instances.first
}

func makeAppleEvent(url: URL, pid: pid_t, returnID: Int16) -> NSAppleEventDescriptor {
    let event = NSAppleEventDescriptor(
        eventClass: AEEventClass(kInternetEventClass),
        eventID: AEEventID(kAEGetURL),
        targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
        returnID: AEReturnID(returnID),
        transactionID: AETransactionID(kAnyTransactionID)
    )
    
    event.setParam(
        NSAppleEventDescriptor(string: url.absoluteString),
        forKeyword: AEKeyword(keyDirectObject)
    )
    
    return event
}

struct ReplyInfo {
    let receivedAt: Date
    let returnID: Int?
    let transactionID: Int?
    let errorNumber: Int?
    let errorString: String?
    let descriptorType: FourCharCode
}

enum ReplyError: Error, CustomStringConvertible {
    case timeout(Int)

    var description: String {
        switch self {
        case let .timeout(returnID):
            return "timed out waiting for reply (returnID=\(returnID))"
        }
    }
}

actor ReplyAwaiter {
    private var continuations: [Int: CheckedContinuation<ReplyInfo, Error>] = [:]
    private var replies: [ReplyInfo] = []
    private var pendingOrder: [Int] = []

    func awaitReply(returnID: Int, timeout: TimeInterval) async throws -> ReplyInfo {
        if let existing = replies.last(where: { $0.returnID == returnID }) {
            return existing
        }

        return try await withCheckedThrowingContinuation { cont in
            continuations[returnID] = cont
            pendingOrder.append(returnID)
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self.timeout(returnID: returnID)
            }
        }
    }

    func deliver(_ reply: ReplyInfo) {
        replies.append(reply)
        if let id = reply.returnID, let cont = continuations.removeValue(forKey: id) {
            pendingOrder.removeAll(where: { $0 == id })
            cont.resume(returning: reply)
            return
        }

        // Fallback: if no returnID (or no matching continuation), resume the oldest pending
        if let oldest = pendingOrder.first, let cont = continuations.removeValue(forKey: oldest) {
            pendingOrder.removeFirst()
            cont.resume(returning: reply)
        }
    }

    private func timeout(returnID: Int) async {
        if let cont = continuations.removeValue(forKey: returnID) {
            pendingOrder.removeAll(where: { $0 == returnID })
            cont.resume(throwing: ReplyError.timeout(returnID))
        }
    }

    func allReplies() -> [ReplyInfo] {
        replies
    }
}

final class ReplyHandler: NSObject {
    private let awaiter: ReplyAwaiter

    init(awaiter: ReplyAwaiter) {
        self.awaiter = awaiter
    }

    func install() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleReply(event:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEAnswer)
        )
    }

    func uninstall() {
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEAnswer)
        )
    }

    @objc private func handleReply(event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        dumpDescriptorKeys(event, label: "kAEAnswer event")
        dumpDescriptorKeys(replyEvent, label: "kAEAnswer replyEvent")
        let returnID = event.attributeDescriptor(forKeyword: AEKeyword(keyReturnIDAttr))?.int32Value
        let transactionID = event.attributeDescriptor(forKeyword: AEKeyword(keyTransactionIDAttr))?.int32Value
        let errorNumber = event.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value
        let errorString = event.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue

        let eventType = formatFourChar(event.descriptorType)
        let replyType = formatFourChar(replyEvent.descriptorType)
        print(
            "kAEAnswer received: eventType=\(eventType) replyType=\(replyType) " +
            "returnID=\(returnID.map(String.init) ?? "nil") " +
            "txID=\(transactionID.map(String.init) ?? "nil") " +
            "err=\(errorNumber.map(String.init) ?? "nil") " +
            "errStr=\(errorString ?? "nil")"
        )
        let info = ReplyInfo(
            receivedAt: Date(),
            returnID: returnID.map(Int.init),
            transactionID: transactionID.map(Int.init),
            errorNumber: errorNumber.map(Int.init),
            errorString: errorString,
            descriptorType: event.descriptorType
        )
        Task {
            await awaiter.deliver(info)
        }
    }
}

final class AppleEventSender {
    private let awaiter: ReplyAwaiter?

    init(awaiter: ReplyAwaiter?) {
        self.awaiter = awaiter
    }

    func send(event: NSAppleEventDescriptor, mode: SendMode, timeout: TimeInterval, returnID: Int) async throws -> ReplyInfo? {
        switch mode {
        case .noReply:
            _ = try await sendEventOnMain(event, options: [.neverInteract, .noReply], timeout: timeout)
            return nil
        case .waitForReply:
            let reply = try await sendEventOnMain(event, options: [.neverInteract, .waitForReply], timeout: timeout)
            return parseReplyDescriptor(reply, fallbackReturnID: Int16(returnID))
        case .queueReply:
            _ = try await sendEventOnMain(event, options: [.neverInteract, .queueReply], timeout: timeout)
            guard let awaiter else { return nil }
            return try await awaiter.awaitReply(returnID: returnID, timeout: timeout)
        }
    }
    
    func sendQueueReplyNoWait(event: NSAppleEventDescriptor, timeout: TimeInterval) async throws {
        _ = try await sendEventOnMain(event, options: [.neverInteract, .queueReply], timeout: timeout)
    }

    private func sendEventOnMain(
        _ event: NSAppleEventDescriptor,
        options: NSAppleEventDescriptor.SendOptions,
        timeout: TimeInterval
    ) async throws -> NSAppleEventDescriptor {
        try await MainActor.run {
            try event.sendEvent(options: options, timeout: timeout)
        }
    }
}

func formatFourChar(_ code: FourCharCode) -> String {
    var be = code.bigEndian
    let data = Data(bytes: &be, count: 4)
    return String(data: data, encoding: .macOSRoman) ?? "0x\(String(code, radix: 16))"
}

func truncateString(_ value: String, maxLength: Int = 200) -> String {
    if value.count <= maxLength {
        return value
    }
    let idx = value.index(value.startIndex, offsetBy: maxLength)
    return "\(value[..<idx])..."
}

func describeDescriptorValue(_ descriptor: NSAppleEventDescriptor) -> String {
    switch descriptor.descriptorType {
    case typeNull:
        return "null"
    case typeBoolean:
        return "bool=\(descriptor.booleanValue)"
    case typeSInt32:
        return "int32=\(descriptor.int32Value)"
    case typeEnumerated:
        return "enum=\(formatFourChar(descriptor.enumCodeValue))"
    case typeType:
        return "typeCode=\(formatFourChar(descriptor.typeCodeValue))"
    case typeChar, typeUnicodeText, typeUTF8Text:
        if let str = descriptor.stringValue {
            return "string=\(truncateString(str))"
        }
    case typeAEList:
        return "list(count=\(descriptor.numberOfItems))"
    case typeAERecord:
        return "record(count=\(descriptor.numberOfItems))"
    case typeAppleEvent:
        return "appleEvent"
    default:
        break
    }

    if let str = descriptor.stringValue {
        return "string=\(truncateString(str))"
    }
    return "dataLen=\(descriptor.data.count)"
}

func dumpDescriptorItems(
    _ descriptor: NSAppleEventDescriptor,
    indent: String,
    depth: Int,
    maxDepth: Int
) {
    guard descriptor.numberOfItems > 0 else { return }
    let count = descriptor.numberOfItems
    for index in 1...count {
        guard let item = descriptor.atIndex(index) else { continue }
        let keyLabel: String
        if descriptor.isRecordDescriptor {
            let keyword = descriptor.keywordForDescriptor(at: index)
            keyLabel = formatFourChar(keyword)
        } else {
            keyLabel = "#\(index)"
        }
        let typeLabel = formatFourChar(item.descriptorType)
        print("\(indent)\(keyLabel) type=\(typeLabel) \(describeDescriptorValue(item))")
        if (item.isRecordDescriptor || item.numberOfItems > 0), depth + 1 < maxDepth {
            dumpDescriptorItems(item, indent: indent + "  ", depth: depth + 1, maxDepth: maxDepth)
        }
    }
}

func dumpKnownAttributes(_ descriptor: NSAppleEventDescriptor, indent: String) {
    let attributes: [(String, AEKeyword)] = [
        ("keyEventClassAttr", AEKeyword(keyEventClassAttr)),
        ("keyEventIDAttr", AEKeyword(keyEventIDAttr)),
        ("keyReturnIDAttr", AEKeyword(keyReturnIDAttr)),
        ("keyTransactionIDAttr", AEKeyword(keyTransactionIDAttr)),
        ("keyAddressAttr", AEKeyword(keyAddressAttr)),
        ("keyOriginalAddressAttr", AEKeyword(keyOriginalAddressAttr)),
        ("keyTimeoutAttr", AEKeyword(keyTimeoutAttr))
    ]

    for (name, keyword) in attributes {
        guard let value = descriptor.attributeDescriptor(forKeyword: keyword) else { continue }
        let typeLabel = formatFourChar(value.descriptorType)
        print("\(indent)@\(name) type=\(typeLabel) \(describeDescriptorValue(value))")
    }
}

func dumpDescriptorKeys(
    _ descriptor: NSAppleEventDescriptor,
    label: String,
    maxDepth: Int = 2
) {
    let typeLabel = formatFourChar(descriptor.descriptorType)
    print("dump[\(label)] type=\(typeLabel) isRecord=\(descriptor.isRecordDescriptor) items=\(descriptor.numberOfItems)")
    if descriptor.descriptorType == typeAppleEvent {
        print(
            "  eventClass=\(formatFourChar(descriptor.eventClass)) " +
            "eventID=\(formatFourChar(descriptor.eventID)) " +
            "returnID=\(descriptor.returnID) " +
            "txID=\(descriptor.transactionID)"
        )
    }
    dumpDescriptorItems(descriptor, indent: "  ", depth: 0, maxDepth: maxDepth)
    dumpKnownAttributes(descriptor, indent: "  ")
}

func parseReplyDescriptor(_ reply: NSAppleEventDescriptor, fallbackReturnID: Int16) -> ReplyInfo {
    dumpDescriptorKeys(reply, label: "waitForReply reply")
    let returnID = reply.attributeDescriptor(forKeyword: AEKeyword(keyReturnIDAttr))?.int32Value
    let transactionID = reply.attributeDescriptor(forKeyword: AEKeyword(keyTransactionIDAttr))?.int32Value
    let errorNumber = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value
    let errorString = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
    let resolvedReturnID = Int(returnID ?? Int32(fallbackReturnID))
    return ReplyInfo(
        receivedAt: Date(),
        returnID: resolvedReturnID,
        transactionID: transactionID.map(Int.init),
        errorNumber: errorNumber.map(Int.init),
        errorString: errorString,
        descriptorType: reply.descriptorType
    )
}

func run(config: Config) async {
    var urls = config.urls
    if config.shuffle {
        urls.shuffle()
    }

    guard let app = resolveTargetApp(bundleID: config.bundleID, pid: config.pid) else {
        print("No running app found for bundleID=\(config.bundleID) pid=\(config.pid.map(String.init) ?? "nil")")
        exit(1)
    }

    print("Target PID: \(app.processIdentifier) bundleID: \(config.bundleID)")
    print("Mode: \(config.mode.rawValue) count: \(config.count) delayMs: \(config.delayMs) timeout: \(config.timeout)s")
    print("URLs: \(urls.map { $0.absoluteString }.joined(separator: " | "))")

    let awaiter = ReplyAwaiter()
    let handler = ReplyHandler(awaiter: awaiter)
    if config.mode == .queueReply {
        await MainActor.run {
            handler.install()
        }
    }

    let sender = AppleEventSender(awaiter: config.mode == .queueReply ? awaiter : nil)

    var success = 0
    var failures = 0

    if config.mode == .queueReply && !config.queueReplySerial {
        var returnIDs: [Int] = []
        for i in 0..<config.count {
            let url = urls[i % urls.count]
            let returnID = Int16((i + 1) & 0x7FFF)
            let event = makeAppleEvent(url: url, pid: app.processIdentifier, returnID: returnID)
            let start = CFAbsoluteTimeGetCurrent()
            do {
                try await sender.sendQueueReplyNoWait(event: event, timeout: config.timeout)
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                print("send[\(i + 1)] ok returnID=\(returnID) elapsed=\(String(format: "%.1f", elapsedMs))ms")
                success += 1
                returnIDs.append(Int(returnID))
            } catch {
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                print("send[\(i + 1)] FAIL returnID=\(returnID) elapsed=\(String(format: "%.1f", elapsedMs))ms error=\(error)")
                failures += 1
            }
            if config.delayMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(config.delayMs) * 1_000_000)
            }
        }

        await withTaskGroup(of: (Int, Result<ReplyInfo, Error>).self) { group in
            for rid in returnIDs {
                group.addTask {
                    do {
                        let reply = try await awaiter.awaitReply(returnID: rid, timeout: config.waitSeconds)
                        return (rid, .success(reply))
                    } catch {
                        return (rid, .failure(error))
                    }
                }
            }

            for await (rid, result) in group {
                switch result {
                case let .success(reply):
                    let typeStr = formatFourChar(reply.descriptorType)
                    print(
                        "  reply returnID=\(reply.returnID.map(String.init) ?? "nil") " +
                        "txID=\(reply.transactionID.map(String.init) ?? "nil") " +
                        "err=\(reply.errorNumber.map(String.init) ?? "nil") " +
                        "errStr=\(reply.errorString ?? "nil") " +
                        "type=\(typeStr)"
                    )
                case let .failure(error):
                    print("  reply FAIL returnID=\(rid) error=\(error)")
                }
            }
        }
    } else {
        for i in 0..<config.count {
            let url = urls[i % urls.count]
            let returnID = Int16((i + 1) & 0x7FFF)
            let event = makeAppleEvent(url: url, pid: app.processIdentifier, returnID: returnID)

            let start = CFAbsoluteTimeGetCurrent()
            do {
                let reply = try await sender.send(event: event, mode: config.mode, timeout: config.timeout, returnID: Int(returnID))
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                print("send[\(i + 1)] ok returnID=\(returnID) elapsed=\(String(format: "%.1f", elapsedMs))ms")
                success += 1
                if let reply {
                    let typeStr = formatFourChar(reply.descriptorType)
                    print(
                        "  reply returnID=\(reply.returnID.map(String.init) ?? "nil") " +
                        "txID=\(reply.transactionID.map(String.init) ?? "nil") " +
                        "err=\(reply.errorNumber.map(String.init) ?? "nil") " +
                        "errStr=\(reply.errorString ?? "nil") " +
                        "type=\(typeStr)"
                    )
                }
            } catch {
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                print("send[\(i + 1)] FAIL returnID=\(returnID) elapsed=\(String(format: "%.1f", elapsedMs))ms error=\(error)")
                failures += 1
            }

            if config.delayMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(config.delayMs) * 1_000_000)
            }
        }
    }

    if config.mode == .queueReply {
        await MainActor.run {
            handler.uninstall()
        }
    }

    let replies = await awaiter.allReplies()
    if config.mode == .queueReply {
        print("queueReply replies: \(replies.count)")
    }
    print("Done. success=\(success) failures=\(failures)")
}

let config = parseArgs()
Task {
    await run(config: config)
    DispatchQueue.main.async {
        CFRunLoopStop(CFRunLoopGetMain())
    }
}
RunLoop.main.run()
