import SwiftUI

private var visualizationLifetime: TimeInterval {
    return Defaults.swiftServer.double(forKey: DefaultsKeys.eclipsingDebugVisualizationFadeOutDelay)
}

private var visualizationFadeOutDuration: TimeInterval {
    return Defaults.swiftServer.double(forKey: DefaultsKeys.eclipsingDebugVisualizationFadeOutDuration)
}

extension Animation {
    static var debuggerVisualization: Self {
        .linear(duration: visualizationFadeOutDuration).delay(visualizationLifetime)
    }
}

@available(macOS 14, *)
struct EclipsingPoint: Identifiable {
    var id = UUID()
    var position: CGPoint
    var label: String = ""
    var color: CGColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)

    func reoriented(displayingOn screen: NSScreen) -> CGPoint {
        var origin = screen.frame.origin
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
        point.reoriented(displayingOn: (NSApp.largestElectronWindow?.screen)!)
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
                // flip because coords are in cocoa space
                y: proxy.size.height - position.y,
            )
            .onAppear {
                withAnimation(.debuggerVisualization) { hidden = true }
            }
        }
    }
}

@available(macOS 14, *)
struct EclipsingRect: Identifiable {
    var id = UUID()
    var rect: CGRect
    var label: String = ""
    var color: CGColor = CGColor(red: 0, green: 1, blue: 0, alpha: 1)

    func reoriented(displayingOn screen: NSScreen) -> CGRect {
        let position = rect.origin
        var screenOrigin = screen.frame.origin
        let newOrigin = CGPoint(x: position.x - screenOrigin.x, y: position.y - screenOrigin.y)
        return CGRect(origin: newOrigin, size: rect.size)
    }
}

@available(macOS 14, *)
struct EclipsingRectView: View {
    var rect: EclipsingRect
    @State private var hidden = false

    private var fontSize: CGFloat {
        8
    }

    @ViewBuilder
    private var labelView: some View {
        Text(verbatim: rect.label)
            .font(.system(size: fontSize))
            .opacity(hidden ? 0 : 0.6)
            .fixedSize()
    }

    var body: some View {
        let color = Color(rect.color)
        let rect = rect.reoriented(displayingOn: (NSApp.largestElectronWindow?.screen)!)

        GeometryReader { proxy in
            Rectangle()
                .fill(color.opacity(0.2))
                // stroke goes inside, doesn't grow outside boundaries
                .strokeBorder(color, lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .overlay { labelView }
                // `.position` adjusts the center but the coords are in
                // cocoa space (relative to bottom left)
                .position(
                    x: rect.origin.x + rect.width / 2,
                    // flip because coords are in cocoa space
                    y: proxy.size.height - rect.origin.y - rect.height / 2,
                )
                .opacity(hidden ? 0 : 1)
                .onAppear {
                    withAnimation(.debuggerVisualization) { hidden = true }
                }
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
        EclipsingPoint(position: CGPoint(x: 100, y: 100), label: "bottomleft"),
        EclipsingPoint(position: CGPoint(x: 100 + 150, y: 100 + 75), label: "topright"),
    ], rectangles: [
        EclipsingRect(rect: CGRect(x: 100, y: 100, width: 150, height: 75), label: "rectangle"),
    ])

    EclipsingDebuggerView(state: state)
        .frame(width: 1920/4, height: 1080/4)
}
