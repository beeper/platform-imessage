import AppKit
import Darwin
import SwiftServerFoundation
import SwiftUI

private enum PermissionsAppName {
    static let current: String = {
        responsibleApplicationName()
            ?? bundleDisplayName()
            ?? NSRunningApplication.current.localizedName?.nonEmpty
            ?? "Beeper Desktop"
    }()

    private static func responsibleApplicationName() -> String? {
        // TCC lists the responsible GUI app, which can be Terminal in dev launches.
        var pid = getppid()
        var visited = Set<pid_t>()

        while pid > 1, visited.insert(pid).inserted {
            if let name = bundledApplicationName(for: pid) {
                return name
            }

            guard let parentPID = parentProcessID(of: pid), parentPID != pid else {
                break
            }

            pid = parentPID
        }

        return nil
    }

    private static func bundledApplicationName(for pid: pid_t) -> String? {
        guard let runningApp = NSRunningApplication(processIdentifier: pid),
              runningApp.bundleIdentifier != nil || runningApp.bundleURL != nil else {
            return nil
        }

        return runningApp.localizedName?.nonEmpty
    }

    private static func parentProcessID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))

        guard result == Int32(size), info.pbi_ppid > 0 else {
            return nil
        }

        return pid_t(info.pbi_ppid)
    }

    private static func bundleDisplayName() -> String? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?.nonEmpty
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)?.nonEmpty
    }
}

@available(macOS 10.15, *)
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

@available(macOS 10.15, *)
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

@available(macOS 10.15, *)
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
