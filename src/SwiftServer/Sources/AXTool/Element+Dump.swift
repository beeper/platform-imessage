import AccessibilityControl
import ApplicationServices
import Foundation

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private func printAttribute(_ key: String, _ value: Any?, last: Bool = false) {
    guard let value else { return }
    let valueEscaped = if let struc = Accessibility.Struct(erased: value as AnyObject) {
        // this looks _much nicer_ compared to the default description
        "\(struc)".xmlEscaped
    } else {
        "\(value)".xmlEscaped
    }
    print("\(key)=\"\(valueEscaped)\"", terminator: last ? "" : " ")
}

extension Accessibility.Element {
    func axTool_dump(indent: Int = 0, shallow: Bool = false, preamble: String? = nil) throws {
        let ws = String(repeating: "  ", count: indent)
        guard let role = try? self.role() else {
            print("\(ws)<!-- ⚠️ couldn't obtain role, skipping (\(self)) -->")
            return
        }
        let preamble = if let preamble {
            "<!-- \(preamble) --> "
        } else {
            ""
        }
        print("\(ws)\(preamble)<\(role)", terminator: " ")
        var attributesPointingToElements = [String: [Accessibility.Element]]()

        if let supported = try? supportedAttributes() {
            let attributes = Dictionary(supported.filter { $0.name.value != kAXChildrenAttribute }.map { attribute in
                (attribute.name.value, try? attribute())
            }, uniquingKeysWith: { first, second in second })

            let lastNonNilIndex = Array(attributes.values).lastIndex(where: { $0 != nil })

            for (index, (name, value)) in attributes.enumerated() {
                if let array = value as? [Any] {
                    guard let first = array.first, CFGetTypeID(first as CFTypeRef) == AXUIElementGetTypeID() else {
                        continue
                    }
                    attributesPointingToElements[name, default: []].append(contentsOf: array.map {
                        Accessibility.Element(raw: $0 as! AXUIElement)
                    })
                    continue
                } else if let element = Accessibility.Element(erased: value as CFTypeRef) {
                    attributesPointingToElements[name, default: []].append(element)
                    continue
                }

                printAttribute(name, value, last: index == lastNonNilIndex)
            }
        }
        print(">")
        let ws2 = String(repeating: "  ", count: indent + 1)

        if !shallow {
            for (attributeContainingElementsName, containedElements) in attributesPointingToElements {
                print("\(ws2)<!-- attribute containing element(s) --> <\(attributeContainingElementsName)>")
                for element in containedElements {
                    try element.axTool_dump(indent: indent + 2, shallow: true)
                }
                print("\(ws2)</\(attributeContainingElementsName)>")
            }
        }

        defer { print("\(ws)</\(role)>") }

        if let actions = try? supportedActions(), !actions.isEmpty {
            for (index, action) in actions.enumerated() {
                print("\(ws2)<!-- actions[\(index)] --> <action", terminator: " ")
                printAttribute("name", action.name.value)
                printAttribute("description", action.description, last: true)
                print("></action>")
            }
        }

        guard !shallow else {
            // used to avoid following cycles endlessly
            print("\(ws2)<!-- omitting children, sections, etc. -->")
            return
        }

        if let sections = try? self.sections() as [[String: Any]] {
            for (index, section) in sections.enumerated() {
                print("\(ws2)<!-- [\(index)] --> <section", terminator: " ")
                printAttribute("uniqueID", section["SectionUniqueID"])
                printAttribute("description", section["SectionDescription"], last: true)
                if case let object = section["SectionObject"] as CFTypeRef, CFGetTypeID(object) == AXUIElementGetTypeID() {
                    let element = Accessibility.Element(axRaw: object)
                    print(">")
                    try element?.axTool_dump(indent: indent + 2)
                    print("\(ws2)</section>")
                } else {
                    print("></section>")
                }
            }
        }

        guard let children = try? self.children() else { return }
        for (index, child) in children.enumerated() {
            try child.axTool_dump(indent: indent + 1, preamble: "[\(index)]")
        }
    }
}

// MARK: - Copied from SwiftServer (but has more)

// refer to AXAttributeConstants.h
// https://gist.github.com/p6p/24fbac5d12891fcfffa2b53761f4343e
// https://developer.apple.com/documentation/applicationservices/axattributeconstants_h/miscellaneous_defines
// https://github.com/tmandry/AXSwift/blob/main/Sources/Constants.swift
public extension Accessibility.Names {
    var rows: AttributeName<[Accessibility.Element]> { .init(kAXRowsAttribute) }
    var children: AttributeName<[Accessibility.Element]> { .init(kAXChildrenAttribute) }
    var selectedChildren: AttributeName<[Accessibility.Element]> { .init(kAXSelectedChildrenAttribute) }
    var linkedElements: AttributeName<[Accessibility.Element]> { .init(kAXLinkedUIElementsAttribute) }
    // ["SectionObject": <AXUIElement 0x60000387e160> {pid=16768}, "SectionUniqueID": 11266711619528580561, "SectionDescription": Messages]
    var sections: AttributeName<[[String: CFTypeRef]]> { "AXSections" }
    var parent: AttributeName<Accessibility.Element> { .init(kAXParentAttribute) }
    var valueDescription: AttributeName<Any> { .init(kAXValueDescriptionAttribute) }

    var isExpanded: AttributeName<Bool> { .init(kAXExpandedAttribute) }
    var isHidden: AttributeName<Bool> { .init(kAXHiddenAttribute) }

    // this wont work without the com.apple.private.accessibility.inspection entitlement
    // https://stackoverflow.com/questions/45590888/how-to-get-the-objective-c-class-name-corresponding-to-an-axuielement
    var className: AttributeName<String> { "AXClassName" }

    var value: MutableAttributeName<Any> { .init(kAXValueAttribute) }
    var placeholderValue: AttributeName<String> { .init(kAXPlaceholderValueAttribute) }

    var position: MutableAttributeName<CGPoint> { .init(kAXPositionAttribute) }
    var size: MutableAttributeName<CGSize> { .init(kAXSizeAttribute) }
    var frame: AttributeName<CGRect> { "AXFrame" }

    var title: AttributeName<String> { .init(kAXTitleAttribute) }
    var titleUIElement: AttributeName<Accessibility.Element> { .init(kAXTitleUIElementAttribute) }
    var localizedDescription: AttributeName<String> { .init(kAXDescriptionAttribute) }
    var identifier: AttributeName<String> { .init(kAXIdentifierAttribute) }
    var role: AttributeName<String> { .init(kAXRoleAttribute) }
    var subrole: AttributeName<String> { .init(kAXSubroleAttribute) }
    var roleDescription: AttributeName<String> { .init(kAXRoleDescriptionAttribute) }
    var help: AttributeName<String> { .init(kAXHelpAttribute) }

    var noOfChars: AttributeName<Int> { .init(kAXNumberOfCharactersAttribute) }

    var isSelected: MutableAttributeName<Bool> { .init(kAXSelectedAttribute) }
    var isFocused: MutableAttributeName<Bool> { .init(kAXFocusedAttribute) }
    var isEnabled: AttributeName<Bool> { .init(kAXEnabledAttribute) }

    var selectedRows: AttributeName<[AXUIElement]> { .init(kAXSelectedRowsAttribute) }
    var selectedColumns: AttributeName<[AXUIElement]> { .init(kAXSelectedColumnsAttribute) }
    var selectedCells: AttributeName<[AXUIElement]> { .init(kAXSelectedCellsAttribute) }

    // https://developer.apple.com/documentation/applicationservices/axactionconstants_h/miscellaneous_defines
    var press: ActionName { .init(kAXPressAction) }
    var showMenu: ActionName { .init(kAXShowMenuAction) }
    var cancel: ActionName { .init(kAXCancelAction) }
    var scrollToVisible: ActionName { "AXScrollToVisible" }

    var increment: ActionName { .init(kAXIncrementAction) }

#if DEBUG
    var decrement: ActionName { .init(kAXDecrementAction) }

    var minValue: AttributeName<Any> { .init(kAXMinValueAttribute) }
    var maxValue: AttributeName<Any> { .init(kAXMaxValueAttribute) }
#endif

    // App-specific
    var appWindows: AttributeName<[Accessibility.Element]> { .init(kAXWindowsAttribute) }
    var appMainWindow: AttributeName<Accessibility.Element> { .init(kAXMainWindowAttribute) }
    var appFocusedWindow: AttributeName<Accessibility.Element> { .init(kAXFocusedWindowAttribute) }

    // Window-specific
    var windowIsMain: MutableAttributeName<Bool> { .init(kAXMainAttribute) }
    var windowIsModal: AttributeName<Bool> { .init(kAXModalAttribute) }
    var windowIsMinimized: MutableAttributeName<Bool> { .init(kAXMinimizedAttribute) }
    var windowIsFullScreen: MutableAttributeName<Bool> { "AXFullScreen" }
    var windowCloseButton: AttributeName<Accessibility.Element> { .init(kAXCloseButtonAttribute) }
    var windowDefaultButton: AttributeName<Accessibility.Element> { .init(kAXDefaultButtonAttribute) }
    var windowCancelButton: AttributeName<Accessibility.Element> { .init(kAXCancelButtonAttribute) }
}
