import AppKit
import SwiftUI

struct HelpButton: NSViewRepresentable {
    final class Coordinator: NSObject {
        var helpButton: HelpButton

        init(_ helpButton: HelpButton) {
            self.helpButton = helpButton
        }

        @objc func action() {
            helpButton.action()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    var action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func updateNSView(_ nsView: NSButton, context: Context) {}

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.target = context.coordinator
        button.title = ""
        button.action = #selector(Coordinator.action)
        button.bezelStyle = .helpButton
        return button
    }
}
