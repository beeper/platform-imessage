import AccessibilityControl
import ApplicationServices

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
