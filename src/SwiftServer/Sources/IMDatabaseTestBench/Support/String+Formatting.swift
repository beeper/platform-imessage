import Foundation

extension String {
    var shortenedPath: String {
        replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    func padEnd(to length: Int) -> String {
        self + String(repeating: " ", count: max(0, length - count))
    }
}
