import AppKit
import AccessibilityControl
import WindowControl

struct CharacterPickerPopover {
    static let expectedSize = CGSize(width: 346, height: 470)
    static let searchFieldTopInset: CGFloat = 38
    static let windowWidthRange: ClosedRange<CGFloat> = 300...420
    static let windowHeightRange: ClosedRange<CGFloat> = 420...560

    let app: Accessibility.Element
    let ownerPID: pid_t

    func detachedPopover() throws -> Accessibility.Element? {
        try windowCandidates()
            .lazy
            .compactMap(popover(forWindow:))
            .first
    }

    func searchField(in popover: Accessibility.Element) -> Accessibility.Element? {
        if let childrenInNavigationOrder = try? popover.childrenInNavigationOrder(),
           let searchField = childrenInNavigationOrder.first(where: Self.isSearchTextField) {
            return searchField
        }

        if let searchField = try? popover.children().first(where: Self.isSearchTextField) {
            return searchField
        }

        return popover.recursiveChildren().lazy.first(where: Self.isSearchTextField)
    }

    static func isPopover(_ element: Accessibility.Element) -> Bool {
        (try? element.role()) == Accessibility.Role.popover ||
            (try? element.roleDescription()) == "popover"
    }

    private func popover(forWindow window: Window.Description) -> Accessibility.Element? {
        let searchPoint = CGPoint(x: window.bounds.midX, y: window.bounds.minY + Self.searchFieldTopInset)
        guard let hit = app.elementAtScreenPoint(searchPoint),
              Self.isSearchTextField(hit),
              let popover = try? hit.parent(),
              Self.isPopover(popover)
        else { return nil }

        return popover
    }

    private func windowCandidates() throws -> [Window.Description] {
        try Window.listDescriptions(.all, excludeDesktopElements: true)
            .filter(isCandidateWindow)
            .sorted { score($0) < score($1) }
    }

    private func isCandidateWindow(_ description: Window.Description) -> Bool {
        description.owner == ownerPID &&
            description.isOnscreen == true &&
            description.alpha > 0 &&
            Self.windowWidthRange.contains(description.bounds.width) &&
            Self.windowHeightRange.contains(description.bounds.height)
    }

    private func score(_ description: Window.Description) -> CGFloat {
        abs(description.bounds.width - Self.expectedSize.width) +
            abs(description.bounds.height - Self.expectedSize.height)
    }

    private static func isSearchTextField(_ element: Accessibility.Element) -> Bool {
        (try? element.subrole()) == Accessibility.Subrole.searchField ||
            (try? element.roleDescription()) == "search text field"
    }
}
