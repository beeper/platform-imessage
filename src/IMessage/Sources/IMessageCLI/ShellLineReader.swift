import Darwin
import Foundation

private let historyFileName = ".cli.history.json"

private enum TerminalByte {
    static let maxUTF8SequenceLength = 4

    static let controlC: UInt8 = 0x03
    static let controlD: UInt8 = 0x04
    static let backspace: UInt8 = 0x08
    static let tab = UInt8(ascii: "\t")
    static let lineFeed = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let escape: UInt8 = 0x1B
    static let firstPrintableASCII = UInt8(ascii: " ")
    static let delete: UInt8 = 0x7F

    static let controlSequenceIntroducer = UInt8(ascii: "[")
    static let singleShiftSelect = UInt8(ascii: "O")
    static let deleteSequencePrefix = UInt8(ascii: "3")
    static let arrowUp = UInt8(ascii: "A")
    static let arrowDown = UInt8(ascii: "B")
    static let arrowRight = UInt8(ascii: "C")
    static let arrowLeft = UInt8(ascii: "D")
}

private final class CLIHistory {
    private static let maxEntries = 1_000

    private let fileURL: URL
    private(set) var entries: [String]

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.entries = Self.readEntries(from: fileURL)
    }

    func record(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        entries.insert(trimmed, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        writeEntries()
    }

    private func writeEntries() {
        do {
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            fputs("warning: failed to write CLI history: \(error)\n", stderr)
        }
    }

    private static func readEntries(from fileURL: URL) -> [String] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [String]
        else {
            return []
        }
        return entries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxEntries)
            .map { $0 }
    }
}

final class ShellLineReader {
    private let prompt: String
    private let history: CLIHistory

    init(prompt: String) {
        self.prompt = prompt
        self.history = CLIHistory(fileURL: defaultHistoryFileURL())
    }

    func readLine() -> String? {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            return readLineFallback()
        }

        var originalTermios = termios()
        guard tcgetattr(STDIN_FILENO, &originalTermios) == 0 else {
            return readLineFallback()
        }

        var rawTermios = originalTermios
        rawTermios.c_lflag &= ~UInt(ECHO | ICANON | IEXTEN | ISIG)
        rawTermios.c_iflag &= ~UInt(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
        rawTermios.c_cflag |= UInt(CS8)
        rawTermios.c_oflag &= ~UInt(OPOST)
        withUnsafeMutableBytes(of: &rawTermios.c_cc) { bytes in
            bytes[Int(VMIN)] = 1
            bytes[Int(VTIME)] = 0
        }

        guard tcsetattr(STDIN_FILENO, TCSANOW, &rawTermios) == 0 else {
            return readLineFallback()
        }
        defer {
            var restored = originalTermios
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &restored)
        }

        return readInteractiveLine()
    }

    private func readLineFallback() -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        guard let line = Swift.readLine() else { return nil }
        history.record(line)
        return line
    }

    private func readInteractiveLine() -> String? {
        var line = ""
        var cursorIndex = line.endIndex
        var historyIndex: Int?
        var draftBeforeHistory = ""
        var pendingUTF8: [UInt8] = []

        writeTerminal(prompt)

        while true {
            guard let byte = readByte() else { return nil }

            switch byte {
            case TerminalByte.controlC:
                writeTerminal("^C\n")
                return ""
            case TerminalByte.controlD:
                if line.isEmpty {
                    writeTerminal("\n")
                    return nil
                }
            case TerminalByte.lineFeed, TerminalByte.carriageReturn:
                writeTerminal("\n")
                history.record(line)
                return line
            case TerminalByte.backspace, TerminalByte.delete:
                historyIndex = nil
                draftBeforeHistory = ""
                removeCharacterBeforeCursor(from: &line, cursorIndex: &cursorIndex)
                refreshLine(line, cursorIndex: cursorIndex)
            case TerminalByte.escape:
                handleEscapeSequence(
                    line: &line,
                    cursorIndex: &cursorIndex,
                    historyIndex: &historyIndex,
                    draftBeforeHistory: &draftBeforeHistory
                )
            default:
                guard byte >= TerminalByte.firstPrintableASCII || byte == TerminalByte.tab else { continue }
                pendingUTF8.append(byte)
                guard let text = String(bytes: pendingUTF8, encoding: .utf8) else {
                    if pendingUTF8.count >= TerminalByte.maxUTF8SequenceLength {
                        pendingUTF8.removeAll()
                    }
                    continue
                }

                pendingUTF8.removeAll()
                historyIndex = nil
                draftBeforeHistory = ""
                line.insert(contentsOf: text, at: cursorIndex)
                cursorIndex = line.index(cursorIndex, offsetBy: text.count)
                refreshLine(line, cursorIndex: cursorIndex)
            }
        }
    }

    private func handleEscapeSequence(
        line: inout String,
        cursorIndex: inout String.Index,
        historyIndex: inout Int?,
        draftBeforeHistory: inout String
    ) {
        guard let first = readByte() else { return }
        guard first == TerminalByte.controlSequenceIntroducer || first == TerminalByte.singleShiftSelect else { return }
        guard let second = readByte() else { return }

        switch second {
        case TerminalByte.arrowUp:
            showPreviousHistory(
                line: &line,
                cursorIndex: &cursorIndex,
                historyIndex: &historyIndex,
                draftBeforeHistory: &draftBeforeHistory
            )
        case TerminalByte.arrowDown:
            showNextHistory(
                line: &line,
                cursorIndex: &cursorIndex,
                historyIndex: &historyIndex,
                draftBeforeHistory: &draftBeforeHistory
            )
        case TerminalByte.arrowRight:
            if cursorIndex < line.endIndex {
                cursorIndex = line.index(after: cursorIndex)
                refreshLine(line, cursorIndex: cursorIndex)
            }
        case TerminalByte.arrowLeft:
            if cursorIndex > line.startIndex {
                cursorIndex = line.index(before: cursorIndex)
                refreshLine(line, cursorIndex: cursorIndex)
            }
        case TerminalByte.deleteSequencePrefix:
            _ = readByte()
            removeCharacterAtCursor(from: &line, cursorIndex: &cursorIndex)
            refreshLine(line, cursorIndex: cursorIndex)
        default:
            break
        }
    }

    private func showPreviousHistory(
        line: inout String,
        cursorIndex: inout String.Index,
        historyIndex: inout Int?,
        draftBeforeHistory: inout String
    ) {
        guard !history.entries.isEmpty else { return }
        let nextIndex: Int
        if let index = historyIndex {
            let candidateIndex = history.entries.index(after: index)
            guard candidateIndex < history.entries.endIndex else { return }
            nextIndex = candidateIndex
        } else {
            draftBeforeHistory = line
            nextIndex = history.entries.startIndex
        }

        historyIndex = nextIndex
        line = history.entries[nextIndex]
        cursorIndex = line.endIndex
        refreshLine(line, cursorIndex: cursorIndex)
    }

    private func showNextHistory(
        line: inout String,
        cursorIndex: inout String.Index,
        historyIndex: inout Int?,
        draftBeforeHistory: inout String
    ) {
        guard let index = historyIndex else { return }
        if index > history.entries.startIndex {
            let nextIndex = history.entries.index(before: index)
            historyIndex = nextIndex
            line = history.entries[nextIndex]
        } else {
            historyIndex = nil
            line = draftBeforeHistory
            draftBeforeHistory = ""
        }

        cursorIndex = line.endIndex
        refreshLine(line, cursorIndex: cursorIndex)
    }

    private func removeCharacterBeforeCursor(from line: inout String, cursorIndex: inout String.Index) {
        guard cursorIndex > line.startIndex else { return }
        let previous = line.index(before: cursorIndex)
        line.removeSubrange(previous..<cursorIndex)
        cursorIndex = previous
    }

    private func removeCharacterAtCursor(from line: inout String, cursorIndex: inout String.Index) {
        guard cursorIndex < line.endIndex else { return }
        let next = line.index(after: cursorIndex)
        line.removeSubrange(cursorIndex..<next)
    }

    private func refreshLine(_ line: String, cursorIndex: String.Index) {
        writeTerminal("\r\(prompt)\(line)\u{1B}[K")
        if cursorIndex < line.endIndex {
            let trailingCharacters = line.distance(from: cursorIndex, to: line.endIndex)
            writeTerminal("\u{1B}[\(trailingCharacters)D")
        }
    }

    private func readByte() -> UInt8? {
        var byte = UInt8.zero
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        guard count == 1 else { return nil }
        return byte
    }

    private func writeTerminal(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}

private func defaultHistoryFileURL() -> URL {
    let fileManager = FileManager.default
    let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)

    let historyOverride = ProcessInfo.processInfo.environment["IMESSAGE_CLI_HISTORY_FILE"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let override = historyOverride, !override.isEmpty {
        return absoluteFileURL(for: override, relativeTo: currentDirectory)
    }

    if let packageManifest = findUp(fileName: "Package.swift", from: currentDirectory) {
        return packageManifest.deletingLastPathComponent().appendingPathComponent(historyFileName)
    }

    let currentDirectoryHistory = currentDirectory.appendingPathComponent(historyFileName)
    if fileManager.fileExists(atPath: currentDirectoryHistory.path) {
        return currentDirectoryHistory
    }

    if let executableURL = Bundle.main.executableURL {
        return executableURL.deletingLastPathComponent().appendingPathComponent(historyFileName)
    }

    return currentDirectory.appendingPathComponent(historyFileName)
}

private func absoluteFileURL(for path: String, relativeTo directory: URL) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path)
    }
    return directory.appendingPathComponent(path)
}

private func findUp(fileName: String, from directory: URL) -> URL? {
    let fileManager = FileManager.default
    var current = directory.standardizedFileURL

    while true {
        let candidate = current.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        let parent = current.deletingLastPathComponent()
        if parent.path == current.path {
            return nil
        }
        current = parent
    }
}
