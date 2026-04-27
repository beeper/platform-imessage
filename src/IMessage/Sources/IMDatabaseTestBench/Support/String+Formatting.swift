import Foundation

extension String {
    var shortenedPath: String {
        replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
