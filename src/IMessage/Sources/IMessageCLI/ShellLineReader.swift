import Darwin
import EditLine.readline
import Foundation

private let historyFileName = ".cli.history.json"
private let terminalNewline = "\r\n"

// libedit's readline API is a set of C globals with C-function callbacks that can't capture context, so the
// state those callbacks need lives here. The shell only ever runs one ShellLineReader at a time.
private enum LineEvent {
    case line(String)
    case endOfInput
}

private var lineEvent: LineEvent?
private var completionProvider: ((_ precedingWords: [String]) -> [String])?
/// Remaining matches for the word being completed, in reverse so the generator can pop them in order.
private var pendingCompletions: [String] = []

private let lineHandler: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void = { line in
    guard let line else {
        lineEvent = .endOfInput
        return
    }
    lineEvent = .line(String(cString: line))
    free(line)
}

private let completionGenerator: @convention(c) (UnsafePointer<CChar>?, Int32) -> UnsafeMutablePointer<CChar>? = { _, _ in
    pendingCompletions.popLast().map { strdup($0) }
}

private let attemptedCompletion: @convention(c) (UnsafePointer<CChar>?, Int32, Int32) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = { text, start, _ in
    // Never fall back to filename completion.
    rl_attempted_completion_over = 1

    let precedingText = rl_line_buffer.map { String(String(cString: $0).utf8.prefix(Int(start))) ?? "" } ?? ""
    let precedingWords = precedingText.split(separator: " ").map(String.init)
    let prefix = text.map { String(cString: $0) } ?? ""
    let candidates = completionProvider?(precedingWords) ?? []
    pendingCompletions = candidates.filter { $0.hasPrefix(prefix) }.sorted().reversed()
    guard !pendingCompletions.isEmpty else { return nil }
    return rl_completion_matches(text, completionGenerator)
}

final class ShellLineReader {
    private let prompt: String
    private let history: CLIHistory
    private let terminalLock = NSLock()
    private var isReadingInteractively = false
    private let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())

    /// - Parameter completions: given the words before the cursor, returns the words tab completion may offer.
    init(prompt: String, completions: @escaping (_ precedingWords: [String]) -> [String]) {
        self.prompt = prompt
        self.history = CLIHistory(fileURL: defaultHistoryFileURL())

        completionProvider = completions
        rl_readline_name = strdup("imessage-cli")
        rl_attempted_completion_function = attemptedCompletion
        rl_initialize()
        // libedit's emacs keymap leaves Ctrl-R as redisplay; make it reverse history search like readline.
        rl_parse_and_bind("bind ^R em-inc-search-prev")

        // Ctrl-C arrives as SIGINT (libedit keeps ISIG on). While a line is being read it should only discard
        // that line; `readInteractiveLine` ignores SIGINT for that window so this source sees it instead.
        interruptSource.setEventHandler { [weak self] in self?.interruptLine() }
        interruptSource.resume()
        for entry in history.entries.reversed() {
            add_history(entry)
        }
    }

    func readLine() -> String? {
        let isInteractive = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        guard let line = isInteractive ? readInteractiveLine() : readLineFallback() else { return nil }
        recordHistory(line)
        return line
    }

    private func readLineFallback() -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        return Swift.readLine()
    }

    /// Prints a line above the prompt without clobbering whatever the user is typing.
    func printConsoleLine(_ line: String) {
        terminalLock.lock()
        defer { terminalLock.unlock() }

        guard isReadingInteractively else {
            print(line)
            return
        }

        writeTerminal("\r\u{1B}[K\(terminalOutput(line))\(terminalNewline)")
        rl_forced_update_display()
    }

    private func terminalOutput(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: terminalNewline)
    }

    /// Uses libedit's callback interface instead of the blocking `readline()` so that `printConsoleLine` can
    /// safely interleave output from other threads: libedit is only ever touched while holding `terminalLock`.
    private func readInteractiveLine() -> String? {
        terminalLock.lock()
        lineEvent = nil
        // Before installing the handler: libedit saves the current SIGINT disposition and re-raises to it.
        let previousInterruptHandler = signal(SIGINT, SIG_IGN)
        rl_callback_handler_install(prompt, lineHandler)
        isReadingInteractively = true
        terminalLock.unlock()

        defer {
            terminalLock.lock()
            isReadingInteractively = false
            rl_callback_handler_remove()
            signal(SIGINT, previousInterruptHandler)
            terminalLock.unlock()
        }

        while true {
            guard waitForInput() else {
                writeTerminal(terminalNewline)
                return nil
            }

            terminalLock.lock()
            rl_callback_read_char()
            let event = lineEvent
            terminalLock.unlock()

            switch event {
            case let .line(line):
                return line
            case .endOfInput:
                writeTerminal(terminalNewline)
                return nil
            case nil:
                continue
            }
        }
    }

    private func interruptLine() {
        terminalLock.lock()
        defer { terminalLock.unlock() }
        guard isReadingInteractively else { return }

        writeTerminal("^C\(terminalNewline)")
        // Reinstalling the handler makes libedit start a new, empty line and redraw the prompt.
        rl_callback_handler_remove()
        rl_callback_handler_install(prompt, lineHandler)
    }

    private func recordHistory(_ line: String) {
        let previous = history.entries.first
        guard let entry = history.record(line) else { return }
        if entry != previous {
            add_history(entry)
        }
    }

    /// Blocks until stdin is readable. Returns false on EOF/error.
    private func waitForInput() -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while true {
            let result = poll(&descriptor, 1, -1)
            if result > 0 {
                return descriptor.revents & Int16(POLLIN) != 0
            }
            if result == -1 && (errno == EINTR || errno == EAGAIN) {
                continue
            }
            return false
        }
    }

    private func writeTerminal(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}

private final class CLIHistory {
    private static let maxEntries = 1000

    private let fileURL: URL?
    private(set) var entries: [String]

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL {
            self.entries = Self.readEntries(from: fileURL)
        } else {
            self.entries = []
        }
    }

    /// Returns the trimmed entry that was recorded, or nil if the input was blank.
    @discardableResult
    func record(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        entries.insert(trimmed, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        writeEntries()
        return trimmed
    }

    private func writeEntries() {
        guard let fileURL else { return }

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

private func defaultHistoryFileURL() -> URL? {
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

    return nil
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
