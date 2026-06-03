import AccessibilityControl
import AppKit

extension MessagesApplication {
    final class Window {
        let application: MessagesApplication
        let element: Accessibility.Element

        init(parent application: MessagesApplication, element: Accessibility.Element) {
            self.application = application
            self.element = element
        }

        var processIdentifier: pid_t {
            application.processIdentifier
        }
    }
}
