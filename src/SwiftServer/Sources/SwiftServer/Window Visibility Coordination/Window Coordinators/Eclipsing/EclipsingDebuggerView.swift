import SwiftUI

private var visualizationLifetime: TimeInterval {
    return Defaults.swiftServer.double(forKey: DefaultsKeys.eclipsingDebugVisualizationFadeOutDelay)
}

private var visualizationFadeOutDuration: TimeInterval {
    return Defaults.swiftServer.double(forKey: DefaultsKeys.eclipsingDebugVisualizationFadeOutDuration)
}

private var beingPreviewed: Bool {
    ProcessInfo().environment["XCODE_RUNNING_FOR_PREVIEWS"] != nil
}

extension Animation {
    static var debuggerVisualization: Self {
        .linear(duration: visualizationFadeOutDuration).delay(visualizationLifetime)
    }
}

@available(macOS 14, *)
public struct EclipsingPoint: Identifiable {
    public var id = UUID()
    var position: CGPoint
    var label: String = ""
    var color: CGColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)

    func reoriented(displayingOn screen: NSScreen) -> CGPoint {
        let origin = screen.frame.origin
        return CGPoint(x: position.x - origin.x, y: position.y - origin.y)
    }
}

@available(macOS 14, *)
struct EclipsingPointView: View {
    var point: EclipsingPoint
    @State private var hidden = false

    var pointSize: CGFloat {
        8
    }

    var lineSize: CGFloat {
        pointSize * 3
    }

    var lineThickness: CGFloat {
        1
    }

    var lineCornerRadius: CGFloat {
        0
    }

    var fontSize: CGFloat {
        8
    }

    var position: CGPoint {
        if let screen = NSApp.largestElectronWindow?.screen {
            point.reoriented(displayingOn: screen)
        } else {
            point.position
        }
    }

    var body: some View {
        let color = Color(point.color)

        GeometryReader { proxy in
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: pointSize, height: pointSize)
                // vertical line
                Rectangle()
                    .fill(color)
                    .clipShape(RoundedRectangle(cornerRadius: lineCornerRadius))
                    .frame(width: lineThickness, height: lineSize)
                // horizontal line
                Rectangle()
                    .fill(color)
                    .clipShape(RoundedRectangle(cornerRadius: lineCornerRadius))
                    .frame(width: lineSize, height: lineThickness)
            }
            .compositingGroup()
            .opacity(hidden ? 0 : 0.8)
            .overlay(alignment: .bottom) {
                Text("\(position.x.formatted()), \(position.y.formatted())\n\(point.label)")
                    .multilineTextAlignment(.center)
                    .font(.system(size: fontSize))
                    .fixedSize()
                    .monospacedDigit()
                    .background(.background, in: Capsule())
                    .opacity(hidden ? 0 : 0.6)
                    .offset(y: pointSize * 2)
            }
            .position(
                x: position.x,
                y: position.y,
            )
            .onAppear {
                guard !beingPreviewed else { return }
                withAnimation(.debuggerVisualization) { hidden = true }
            }
        }
    }
}

@available(macOS 14, *)
public struct EclipsingRect: Identifiable {
    public var id = UUID()
    var rect: CGRect
    var label: String = ""
    var color: CGColor = CGColor(red: 0, green: 1, blue: 0, alpha: 1)

    public init(at source: CGRect, label: String, color: CGColor) {
        self.rect = source
        self.label = label
        self.color = color
    }

    func reoriented(displayingOn screen: NSScreen) -> CGRect {
        let position = rect.origin
        let screenOrigin = screen.frame.origin
        let newOrigin = CGPoint(x: position.x - screenOrigin.x, y: position.y - screenOrigin.y)
        return CGRect(origin: newOrigin, size: rect.size)
    }
}

@available(macOS 14, *)
struct EclipsingRectView: View {
    var rect: EclipsingRect
    @State private var hidden = false

    private var fontSize: CGFloat {
        32
    }

    @ViewBuilder
    private var labelView: some View {
        Text(verbatim: rect.label)
            .font(.system(size: fontSize, weight: .bold))
            .opacity(hidden ? 0 : 0.8)
            .fixedSize()
    }

    var body: some View {
        let color = Color(rect.color)
        let rect = if let screen = NSApp.largestElectronWindow?.screen {
            rect.reoriented(displayingOn: screen)
        } else {
            rect.rect
        }

        Rectangle()
            .fill(color.opacity(0.2))
            // stroke goes inside, doesn't grow outside boundaries
            .strokeBorder(color, lineWidth: 1)
            .frame(width: rect.width, height: rect.height)
            .overlay(alignment: .bottomLeading) { labelView.padding() }
            // `.position` adjusts the center but the coords are in
            // cocoa space (relative to bottom left)
            .position(
                x: rect.origin.x + rect.width / 2,
                y: rect.origin.y + rect.height / 2,
            )
            .opacity(hidden ? 0 : 1)
            .onAppear {
                guard !beingPreviewed else { return }
                withAnimation(.debuggerVisualization) { hidden = true }
            }
    }
}

@available(macOS 14, *)
@Observable
final class EclipsingDebuggerState {
    var points = [EclipsingPoint]()
    var rectangles = [EclipsingRect]()

    init(points: [EclipsingPoint] = [], rectangles: [EclipsingRect] = []) {
        self.points = points
        self.rectangles = rectangles
    }
}

@available(macOS 14, *)
struct EclipsingDebuggerView: View {
    var state: EclipsingDebuggerState

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(state.points) { point in
                    EclipsingPointView(point: point)
                }

                ForEach(state.rectangles) { rect in
                    EclipsingRectView(rect: rect)
                }
            }
        }
    }
}

@available(macOS 14, *)
#Preview {
    @Previewable var state = EclipsingDebuggerState(points: [
        EclipsingPoint(position: CGPoint(x: 200, y: 100), label: "topleft"),
        EclipsingPoint(position: CGPoint(x: 200 + 150, y: 100 + 75), label: "bottomright"),
    ], rectangles: [
        EclipsingRect(at: CGRect(x: 200, y: 100, width: 150, height: 75), label: "rectangle", color: NSColor.green.cgColor),
    ])

    EclipsingDebuggerView(state: state)
        .frame(width: 1920/4, height: 1080/4)
}
