import AppKit
import Darwin
import Logging
import SwiftServerFoundation
import SwiftUI

private let log = Logger(swiftServerLabel: "permissions-app-name")

private enum PermissionsAppName {
    private struct AncestorProcess {
        let parentPID: pid_t
        let application: AncestorApplication?
    }

    private struct AncestorApplication {
        let runningApplication: NSRunningApplication?
        let bundle: Bundle?
        let bundleURL: URL?
        let executableURL: URL?
    }

    static let current: String = {
        responsibleApplicationName()
            ?? bundleDisplayName(for: .main)
            ?? NSRunningApplication.current.localizedName?.nonEmpty
            ?? "Beeper Desktop"
    }()

    private static func responsibleApplicationName() -> String? {
        // TCC uses the user-facing app responsible for the launch, not always this process.
        var pid = getppid()
        var visited = Set<pid_t>()
        var ancestors: [AncestorProcess] = []

        while pid > 1, visited.insert(pid).inserted {
            guard let process = ancestorProcess(for: pid) else {
                break
            }

            ancestors.append(process)

            guard process.parentPID != pid else {
                break
            }

            pid = process.parentPID
        }

        for application in ancestors.compactMap(\.application).reversed() {
            guard let appName = displayName(for: application) else { continue }
            log.debug("selected permissions app name: \(appName) (\(application.bundleURL?.path ?? application.executableURL?.path ?? "<unknown path>"))")
            return appName
        }

        log.debug("selected permissions app name: <none>")
        return nil
    }

    private static func ancestorProcess(for pid: pid_t) -> AncestorProcess? {
        guard let parentPID = parentProcessID(for: pid), parentPID > 0 else {
            return nil
        }

        let path = processPath(for: pid)
        return AncestorProcess(
            parentPID: parentPID,
            application: ancestorApplication(for: pid, path: path)
        )
    }

    private static func parentProcessID(for pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))

        if result == Int32(size), info.pbi_ppid > 0 {
            return pid_t(info.pbi_ppid)
        }

        return parentProcessIDFromSysctl(for: pid)
    }

    private static func parentProcessIDFromSysctl(for pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)

        guard result == 0, size >= MemoryLayout<kinfo_proc>.stride, info.kp_eproc.e_ppid > 0 else {
            return nil
        }

        return pid_t(info.kp_eproc.e_ppid)
    }

    private static func ancestorApplication(for pid: pid_t, path: String?) -> AncestorApplication? {
        let runningApplication = NSRunningApplication(processIdentifier: pid)
        let executableURL = runningApplication?.executableURL ?? path.map(URL.init(fileURLWithPath:))
        let bundleURL = runningApplication?.bundleURL ?? executableURL.flatMap(appBundleURL)
        let bundle = bundleURL.flatMap(Bundle.init(url:))

        guard runningApplication != nil || bundle != nil || bundleURL != nil else {
            return nil
        }

        return AncestorApplication(
            runningApplication: runningApplication,
            bundle: bundle,
            bundleURL: bundleURL,
            executableURL: executableURL
        )
    }

    private static func processPath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer).nonEmpty
    }

    private static func appBundleURL(for executableURL: URL) -> URL? {
        var url = executableURL.standardizedFileURL

        while !url.pathComponents.isEmpty {
            if url.pathExtension == "app" {
                return url
            }

            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else {
                return nil
            }
            url = parent
        }

        return nil
    }

    private static func displayName(for application: AncestorApplication) -> String? {
        application.bundleURL?.lastPathComponent.nonEmpty
            ?? bundleDisplayName(for: application.bundle)
            ?? application.runningApplication?.localizedName?.nonEmpty
    }

    private static func bundleDisplayName(for bundle: Bundle?) -> String? {
        guard let bundle else { return nil }

        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?.nonEmpty
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)?.nonEmpty
    }
}

struct RoundedCorners: Shape {
    var tl: CGFloat = 0.0
    var tr: CGFloat = 0.0
    var bl: CGFloat = 0.0
    var br: CGFloat = 0.0

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let w = rect.size.width
        let h = rect.size.height

        // Make sure we do not exceed the size of the rectangle
        let tr = min(min(self.tr, h / 2), w / 2)
        let tl = min(min(self.tl, h / 2), w / 2)
        let bl = min(min(self.bl, h / 2), w / 2)
        let br = min(min(self.br, h / 2), w / 2)

        path.move(to: CGPoint(x: w / 2.0, y: 0))
        path.addLine(to: CGPoint(x: w - tr, y: 0))
        path.addArc(center: CGPoint(x: w - tr, y: tr), radius: tr,
                    startAngle: Angle(degrees: -90), endAngle: Angle(degrees: 0), clockwise: false)

        path.addLine(to: CGPoint(x: w, y: h - br))
        path.addArc(center: CGPoint(x: w - br, y: h - br), radius: br,
                    startAngle: Angle(degrees: 0), endAngle: Angle(degrees: 90), clockwise: false)

        path.addLine(to: CGPoint(x: bl, y: h))
        path.addArc(center: CGPoint(x: bl, y: h - bl), radius: bl,
                    startAngle: Angle(degrees: 90), endAngle: Angle(degrees: 180), clockwise: false)

        path.addLine(to: CGPoint(x: 0, y: tl))
        path.addArc(center: CGPoint(x: tl, y: tl), radius: tl,
                    startAngle: Angle(degrees: 180), endAngle: Angle(degrees: 270), clockwise: false)
        path.closeSubpath()

        return path
    }
}

struct MessageBubble: View {
    var text: String

    var tl: CGFloat
    var tr: CGFloat
    var bl: CGFloat
    var br: CGFloat

    var body: some View {
        VStack {
            Spacer()

            HStack {
                Text(text)
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedCorners(tl: tl, tr: tr, bl: bl, br: br)
                            .fill(LinearGradient(colors: [Color(red: 0.21, green: 0.59, blue: 1.00), Color(red: 0.04, green: 0.50, blue: 1.00)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
            }
        }
    }
}

struct OnboardingView: View {
    var body: some View {
        HStack(spacing: 0) {
            if #available(macOS 13.0, *) {
                MessageBubble(text: "Turn on \(PermissionsAppName.current) in the list", tl: 16, tr: 16, bl: 8, br: 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding()
            } else {
                MessageBubble(text: "1. Click the lock icon", tl: 16, tr: 16, bl: 8, br: 16)
                    .padding(.bottom, 64)
                    .padding(.leading, 42)

                Spacer()

                MessageBubble(text: "2. Check \(PermissionsAppName.current) in the list", tl: 8, tr: 16, bl: 16, br: 16)
                    .padding(.bottom, 195)
                    .padding(.trailing, 60)
            }
        }
    }
}
