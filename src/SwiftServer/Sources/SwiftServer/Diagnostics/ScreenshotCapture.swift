import CoreGraphics
import Foundation
import ImageIO

enum ScreenshotCapture {
    /// Captures the Messages.app window as a PNG file.
    /// Returns the file path on success, or nil if the capture failed.
    /// Requires Screen Recording TCC permission; if not granted the image will be blank.
    static func captureMessagesWindow(processIdentifier pid: pid_t, dumpID: String, logsDirectory: URL) -> URL? {
        guard let windowID = findMessagesWindowID(pid: pid) else {
            return nil
        }

        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming]
        ) else {
            return nil
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "reply-diag-\(dumpID)-\(timestamp).png"
        let fileURL = logsDirectory.appendingPathComponent(filename)

        guard savePNG(image: image, to: fileURL) else {
            return nil
        }

        return fileURL
    }

    private static func findMessagesWindowID(pid: pid_t) -> CGWindowID? {
        guard let windowInfos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [NSDictionary] else {
            return nil
        }

        for info in windowInfos {
            guard let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer] as? Int,
                  layer == 0,
                  let windowID = info[kCGWindowNumber] as? CGWindowID else {
                continue
            }
            return windowID
        }

        // fallback: try off-screen windows too
        guard let allInfos = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [NSDictionary] else {
            return nil
        }

        for info in allInfos {
            guard let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer] as? Int,
                  layer == 0,
                  let windowID = info[kCGWindowNumber] as? CGWindowID else {
                continue
            }
            return windowID
        }

        return nil
    }

    private static func savePNG(image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
