import AccessibilityControl
import AppKit
import Foundation
import Logging
import SwiftServerFoundation

/// Writes diagnostic logs for `withMessageCell` to a dedicated directory.
///
/// For each invocation, creates a session directory containing:
/// - `trace.log` — a plain-text trace of every step, with assumptions and outcomes
/// - `ax-<id>.xml` — AX tree dumps referenced by ID in the trace
/// - `screenshot-<label>.png` — screenshots taken before/after actions
///
/// Directory structure:
///   ~/Library/Application Support/BeeperTexts{-profile}/logs/withMessageCell/
///     <timestamp>-<guid-prefix>/
///       trace.log
///       ax-01.xml
///       screenshot-01-before-deep-link.png
///       ...
@available(macOS 11, *)
final class WithMessageCellDiagnostics {
    private let dir: URL
    private let traceFile: URL
    private var axCounter = 0
    private var screenshotCounter = 0
    private let startTime = Date()
    private let windowID: CGWindowID?

    init(messageCell: MessageCell) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let timestamp = dateFormatter.string(from: Date())
        let guidPrefix = String(messageCell.messageGUID.prefix(8))
        let sessionName = "\(timestamp)_\(guidPrefix)"

        let logsDir: URL
        if let base = Log.file?.deletingLastPathComponent() {
            logsDir = base
        } else {
            logsDir = FileManager.default.temporaryDirectory
        }

        dir = logsDir
            .appendingPathComponent("withMessageCell", isDirectory: true)
            .appendingPathComponent(sessionName, isDirectory: true)
        traceFile = dir.appendingPathComponent("trace.log")

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // try to get the Messages window ID for screenshots
        windowID = Self.getMessagesWindowID()

        write("=== withMessageCell diagnostic session ===")
        write("time: \(Date())")
        write("messageGUID: \(messageCell.messageGUID)")
        write("offset: \(messageCell.offset)")
        write("cellID: \(messageCell.cellID ?? "(nil)")")
        write("cellRole: \(messageCell.cellRole ?? "(nil)")")
        write("overlay: \(messageCell.overlay)")
        write("dir: \(dir.path)")
        write("")
    }

    // MARK: - Logging

    func step(_ description: String) {
        let elapsed = String(format: "%.0fms", -startTime.timeIntervalSinceNow * 1000)
        write("[\(elapsed)] \(description)")
    }

    func assumption(_ text: String) {
        write("  ASSUMPTION: \(text)")
    }

    func violation(_ text: String) {
        write("  *** VIOLATION: \(text) ***")
    }

    func detail(_ text: String) {
        write("  \(text)")
    }

    func outcome(_ text: String) {
        write("  -> \(text)")
    }

    // MARK: - AX tree dumps

    /// Dumps an AX tree to a file and returns the ID for cross-referencing.
    @discardableResult
    func dumpAXTree(_ element: Accessibility.Element, label: String) -> String {
        axCounter += 1
        let id = String(format: "ax-%02d", axCounter)
        let file = dir.appendingPathComponent("\(id)_\(sanitize(label)).xml")

        var buffer = ""
        do {
            try element.dumpXML(
                to: &buffer,
                maxDepth: 12,
                excludingPII: false,
                includeActions: true,
                includeSections: true
            )
            try buffer.write(to: file, atomically: true, encoding: .utf8)
            step("dumped AX tree -> \(id) (\(label))")
        } catch {
            step("failed to dump AX tree for \(label): \(error)")
        }

        return id
    }

    // MARK: - Screenshots

    func screenshot(_ label: String) {
        screenshotCounter += 1
        let name = String(format: "screenshot-%02d-%@.png", screenshotCounter, sanitize(label))
        let file = dir.appendingPathComponent(name)

        guard let image = captureMessagesWindow() else {
            step("screenshot FAILED for \(label) (no image)")
            return
        }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            step("screenshot FAILED for \(label) (PNG encoding)")
            return
        }

        do {
            try data.write(to: file)
            step("screenshot -> \(name)")
        } catch {
            step("screenshot FAILED for \(label): \(error)")
        }
    }

    // MARK: - Private

    private func write(_ text: String) {
        let line = text + "\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: traceFile.path) {
                if let handle = try? FileHandle(forWritingTo: traceFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: traceFile)
            }
        }
    }

    private func sanitize(_ label: String) -> String {
        label.replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func captureMessagesWindow() -> CGImage? {
        if let wid = windowID {
            return CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                wid,
                [.boundsIgnoreFraming, .nominalResolution]
            )
        }
        // fallback: capture nothing rather than the whole screen
        return nil
    }

    private static func getMessagesWindowID() -> CGWindowID? {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return infos.first(where: { ($0[kCGWindowOwnerName as String] as? String) == "Messages" })
            .flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }
}
