@testable import IMessage
import Testing

@Test(arguments: [
    ("Name:Hide Alerts", false),
    ("Name:Show Alerts", true),
    ("Name:Hide Alerts, On", true),
    ("Name:Show Alerts, On", false),
])
func threadAlertsActionLabelInfersMuteState(actionName: String, expectedMuted: Bool) throws {
    let label = try #require(parseThreadAlertsActionLabel(
        actionName,
        hideAlertsLabel: "Hide Alerts",
        showAlertsLabel: "Show Alerts"
    ))

    #expect(label.isMuted == expectedMuted)
}

@Test
func threadAlertsActionLabelRejectsUnknownSuffixesAndActions() {
    #expect(parseThreadAlertsActionLabel(
        "Name:Hide Alerts, Off",
        hideAlertsLabel: "Hide Alerts",
        showAlertsLabel: "Show Alerts"
    ) == nil)
    #expect(parseThreadAlertsActionLabel(
        "Name:Show Alerts, Only",
        hideAlertsLabel: "Hide Alerts",
        showAlertsLabel: "Show Alerts"
    ) == nil)
    #expect(parseThreadAlertsActionLabel(
        "Name:Delete",
        hideAlertsLabel: "Hide Alerts",
        showAlertsLabel: "Show Alerts"
    ) == nil)
}
