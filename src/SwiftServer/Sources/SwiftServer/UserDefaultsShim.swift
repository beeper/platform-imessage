import Foundation

protocol UserDefaultsProtocol {
    // func object(forKey key: String) -> Any?
    // func url(forKey key: String) -> URL?
    // func array(forKey key: String) -> [Any]?
    func dictionary(forKey key: String) -> [String: Any]?
    func string(forKey key: String) -> String?
    // func stringArray(forKey key: String) -> [String]?
    // func data(forKey key: String) -> Data?
    func bool(forKey key: String) -> Bool
    // func integer(forKey key: String) -> Int
    // func float(forKey key: String) -> Float
    // func double(forKey key: String) -> Double

    // func set(_ value: Any?, forKey key: String)
    func set(_ value: Float, forKey key: String)
    // func set(_ value: Double, forKey key: String)
    func set(_ value: Int, forKey key: String)
    func set(_ value: Bool, forKey key: String)
    // func set(_ url: URL?, forKey key: String)
}

extension UserDefaults: UserDefaultsProtocol {}

final class UserDefaultsShim: UserDefaultsProtocol {
    private let suiteName: String

    init?(suiteName: String) {
        self.suiteName = suiteName
    }

    func string(forKey key: String) -> String? {
        read(key: key)
    }

    func bool(forKey key: String) -> Bool {
        read(key: key) == "1"
    }

    func set(_ value: Float, forKey key: String) {
        set(String(value), type: "float", forKey: key)
    }

    func set(_ value: Int, forKey key: String) {
        set(String(value), type: "int", forKey: key)
    }

    func set(_ value: Bool, forKey key: String) {
        set(value ? "true" : "false", type: "bool", forKey: key)
    }

    func dictionary(forKey key: String) -> [String: Any]? {
        return nil
    }

    private func read(key: String) -> String? {
        Self.runProcess(["read", suiteName, key])
    }

    private func set(_ value: String, type: String, forKey key: String) {
        _ = Self.runProcess(["write", suiteName, key, "-\(type)", value])
    }

    private static func runProcess(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            debugLog("UserDefaults shim failed to run process: \(error)")
            return nil
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            return output
        }
        return nil
    }
}
