import SwiftUI

@available(macOS 14, *)
struct EclipsingPoint: Identifiable {
    var id = UUID()
    var position: CGPoint
    var label: String = ""
    var color: CGColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)

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

    @ViewBuilder
    func view(in proxy: GeometryProxy) -> some View {
        let color = Color(color)
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
        .opacity(0.8)
        .overlay(alignment: .bottom) {
            Text("\(position.x.formatted()), \(position.y.formatted())\n\(label)")
                .multilineTextAlignment(.center)
                .font(.system(size: fontSize))
                .fixedSize()
                .monospacedDigit()
                .background(.background, in: Capsule())
                .opacity(0.6)
                .offset(y: pointSize * 2)
        }
        .position(
            x: position.x,
            // flip because coords are in cocoa space
            y: proxy.size.height - position.y,
        )
    }
}

@available(macOS 14, *)
struct EclipsingRect: Identifiable {
    var id = UUID()
    var rect: CGRect
    var label: String = ""
    var color: CGColor = CGColor(red: 0, green: 1, blue: 0, alpha: 1)

    private var fontSize: CGFloat {
        8
    }

    @ViewBuilder
    private var labelView: some View {
        Text(verbatim: label)
            .font(.system(size: fontSize))
            .opacity(0.6)
            .fixedSize()
    }

    @ViewBuilder
    func view(in proxy: GeometryProxy) -> some View {
        let color = Color(color)

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
                    point.view(in: proxy)
                }

                ForEach(state.rectangles) { rect in
                    rect.view(in: proxy)
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
