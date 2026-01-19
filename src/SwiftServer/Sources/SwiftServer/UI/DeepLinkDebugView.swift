import Charts
import SwiftUI

@available(macOS 14, *)
struct DeepLinkDebugView: View {
    @ObservedObject var manager = DeepLinkDebugManager.shared
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            instancesSection
            chartSection
            controlsSection
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            manager.isActive = true
            startRefreshTimer()
        }
        .onDisappear {
            manager.isActive = false
            stopRefreshTimer()
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        HStack {
            Text("Deep Link Debug")
                .font(.headline)
            Spacer()
            Button("Clear") {
                manager.clearEvents()
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var instancesSection: some View {
        HStack(spacing: 16) {
            instanceBadge(
                label: "Public",
                pid: manager.publicInstancePID,
                color: .green,
                isFlashing: manager.publicInstancePID.map { manager.flashingInstances.contains($0) } ?? false
            )

            instanceBadge(
                label: "Puppet",
                pid: manager.puppetInstancePID,
                color: .blue,
                isFlashing: manager.puppetInstancePID.map { manager.flashingInstances.contains($0) } ?? false
            )

            Spacer()

            Text("Instances: \(manager.instanceCount)")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func instanceBadge(label: String, pid: pid_t?, color: Color, isFlashing: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(pid != nil ? color : .gray.opacity(0.3))
                .frame(width: 10, height: 10)
                .overlay {
                    if isFlashing {
                        Circle()
                            .stroke(color, lineWidth: 2)
                            .scaleEffect(1.5)
                            .opacity(0)
                            .animation(.easeOut(duration: 0.3), value: isFlashing)
                    }
                }
                .scaleEffect(isFlashing ? 1.3 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isFlashing)

            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                if let pid {
                    Text("PID: \(pid)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isFlashing ? color.opacity(0.2) : Color.clear)
                .animation(.easeInOut(duration: 0.15), value: isFlashing)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.3), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Deep Link Timeline")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Chart {
                ForEach(manager.visibleEvents) { event in
                    let durationMs = event.duration * 1000

                    BarMark(
                        x: .value("Time", event.startTime),
                        y: .value("Duration (ms)", durationMs)
                    )
                    .foregroundStyle(instanceColor(for: event.instancePID).opacity(event.isActive ? 0.9 : 0.6))
                    .annotation(position: .top, spacing: 2) {
                        if event.isActive {
                            Circle()
                                .fill(instanceColor(for: event.instancePID))
                                .frame(width: 6, height: 6)
                        } else {
                            Text("\(Int(durationMs))ms")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .chartXScale(domain: manager.timeRange)
            .chartYScale(domain: 0...(manager.maxDurationMs * 1.2))
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let ms = value.as(Double.self) {
                            Text("\(Int(ms))ms")
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .second, count: max(1, Int(manager.timeWindowSeconds / 5)))) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.minute().second())
                }
            }
            .frame(height: 180)
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Time Window:")
                    .font(.subheadline)
                Slider(value: $manager.timeWindowSeconds, in: 10...120, step: 5) {
                    Text("Time Window")
                }
                Text("\(Int(manager.timeWindowSeconds))s")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
            }

            // Event log
            eventLogSection
        }
    }

    @ViewBuilder
    private var eventLogSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Events")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(manager.visibleEvents.suffix(50).reversed()) { event in
                            eventRow(event)
                                .id(event.id)
                        }
                    }
                    .padding(4)
                }
                .frame(height: 100)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                }
                .onChange(of: manager.events.count) {
                    if let lastEvent = manager.events.last {
                        withAnimation {
                            proxy.scrollTo(lastEvent.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ event: DeepLinkEvent) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(instanceColor(for: event.instancePID))
                .frame(width: 6, height: 6)

            Text(formatTime(event.startTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)

            Text(instanceLabel(for: event.instancePID))
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)

            if let endTime = event.endTime {
                Text("→")
                    .foregroundColor(.secondary)
                Text(formatTime(endTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("(\(String(format: "%.0fms", event.duration * 1000)))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.orange)
            } else {
                Text("active")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.green)
            }

            Spacer()
        }
        .padding(.vertical, 1)
    }

    private func instanceLabel(for pid: pid_t) -> String {
        if pid == manager.publicInstancePID {
            return "Public"
        } else if pid == manager.puppetInstancePID {
            return "Puppet"
        } else {
            return "PID:\(pid)"
        }
    }

    private func instanceColor(for pid: pid_t) -> Color {
        if pid == manager.publicInstancePID {
            return .green
        } else if pid == manager.puppetInstancePID {
            return .blue
        } else {
            return .orange
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private func startRefreshTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            // Force view refresh for active events and time window updates
            manager.objectWillChange.send()
        }
    }

    private func stopRefreshTimer() {
        timer?.invalidate()
        timer = nil
    }
}

@available(macOS 14, *)
#Preview {
    DeepLinkDebugView()
        .frame(width: 600, height: 500)
}
