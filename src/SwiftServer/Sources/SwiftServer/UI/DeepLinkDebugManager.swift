import AppKit
import Combine
import Foundation

/// Represents a single deep link event for charting
@available(macOS 14, *)
public struct DeepLinkEvent: Identifiable, Sendable {
    public let id = UUID()
    public let instancePID: pid_t
    public let startTime: Date
    public var endTime: Date?
    public let url: URL?

    public var duration: TimeInterval {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }

    public var isActive: Bool {
        endTime == nil
    }
}

/// Manages deep link debug state and events for visualization
@available(macOS 14, *)
@MainActor
public final class DeepLinkDebugManager: ObservableObject {
    public static let shared = DeepLinkDebugManager()

    /// All recorded deep link events
    @Published public var events: [DeepLinkEvent] = []

    /// Currently active (unsuppressed) events by instance PID
    @Published public var activeEvents: [pid_t: UUID] = [:]

    /// Flash state for each instance (true = currently flashing)
    @Published public var flashingInstances: Set<pid_t> = []

    /// Number of Messages instances currently tracked
    @Published public var instanceCount: Int = 0

    /// Public instance PID (if available)
    @Published public var publicInstancePID: pid_t?

    /// Puppet instance PID (if available)
    @Published public var puppetInstancePID: pid_t?

    /// Time window to display (in seconds)
    @Published public var timeWindowSeconds: Double = 30

    /// Whether the view is currently visible (controls event recording)
    @Published public var isActive: Bool = false

    /// Maximum duration seen across all events (for stable Y-axis)
    @Published public var maxDurationMs: Double = 50

    private var flashTimers: [pid_t: Timer] = [:]
    private var cancellables = Set<AnyCancellable>()

    private init() {
        startObservingInstances()
    }

    /// Start observing NSWorkspace for running application changes
    private func startObservingInstances() {
        NSWorkspace.shared.publisher(for: \.runningApplications)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] runningApps in
                self?.updateInstancesFromWorkspace(runningApps)
            }
            .store(in: &cancellables)

        // Initial update
        updateInstancesFromWorkspace(NSWorkspace.shared.runningApplications)
    }

    /// Update instance tracking from workspace running applications
    private func updateInstancesFromWorkspace(_ runningApps: [NSRunningApplication]) {
        let messagesApps = runningApps.filter { $0.bundleIdentifier == "com.apple.MobileSMS" }
        instanceCount = messagesApps.count
    }

    /// Record a new deep link being opened
    public func recordDeepLinkOpened(instancePID: pid_t, url: URL?) {
        guard isActive else { return }

        let event = DeepLinkEvent(
            instancePID: instancePID,
            startTime: Date(),
            endTime: nil,
            url: url
        )

        events.append(event)
        activeEvents[instancePID] = event.id

        // Trigger flash animation
        triggerFlash(for: instancePID)

        // Trim old events to prevent memory growth
        trimOldEvents()
    }

    /// Record that an instance was suppressed (ends the active event)
    public func recordSuppression(instancePID: pid_t) {
        guard isActive else { return }

        if let activeEventID = activeEvents[instancePID],
           let index = events.firstIndex(where: { $0.id == activeEventID }) {
            events[index].endTime = Date()
            activeEvents.removeValue(forKey: instancePID)

            // Update max duration for stable Y-axis scaling
            let durationMs = events[index].duration * 1000
            if durationMs > maxDurationMs {
                maxDurationMs = durationMs
            }
        }
    }

    /// Update instance tracking info
    public func updateInstances(publicPID: pid_t?, puppetPID: pid_t?, totalCount: Int) {
        publicInstancePID = publicPID
        puppetInstancePID = puppetPID
        instanceCount = totalCount
    }

    /// Clear all recorded events
    public func clearEvents() {
        events.removeAll()
        activeEvents.removeAll()
        maxDurationMs = 50  // Reset to default minimum
    }

    /// Get events within the current time window for display
    public var visibleEvents: [DeepLinkEvent] {
        let cutoff = Date().addingTimeInterval(-timeWindowSeconds)
        return events.filter { event in
            event.startTime >= cutoff || (event.endTime ?? Date()) >= cutoff
        }
    }

    /// Get the time range for the chart
    public var timeRange: ClosedRange<Date> {
        let now = Date()
        let start = now.addingTimeInterval(-timeWindowSeconds)
        return start...now
    }


    private func triggerFlash(for pid: pid_t) {
        // Cancel existing flash timer
        flashTimers[pid]?.invalidate()

        // Set flashing state
        flashingInstances.insert(pid)

        // Clear flash after 300ms
        flashTimers[pid] = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flashingInstances.remove(pid)
            }
        }
    }

    private func trimOldEvents() {
        // Keep events from the last 5 minutes max
        let cutoff = Date().addingTimeInterval(-300)
        events.removeAll { event in
            guard let endTime = event.endTime else { return false }
            return endTime < cutoff
        }
    }
}
