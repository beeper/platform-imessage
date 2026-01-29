import AccessibilityControl
import ApplicationServices
import Logging

private let log = Logger(swiftServerLabel: "hiservices")

private typealias AXUIElementCopyHierarchyFunc = @convention(c) (
    AXUIElement,                       // element to traverse
    CFArray,                           // attributes to prefetch (required, must be non-empty)
    CFArray?,                          // optional secondary array (purpose unknown)
    UnsafeMutablePointer<CFArray?>     // output: array of elements in hierarchy
) -> AXError

private let axUIElementCopyHierarchy: AXUIElementCopyHierarchyFunc? = {
    guard let hiServices = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        RTLD_NOW
    ) else {
        log.warning("Failed to load HIServices: \(String(cString: dlerror()))")
        return nil
    }
    guard let sym = dlsym(hiServices, "AXUIElementCopyHierarchy") else {
        log.warning("Failed to find AXUIElementCopyHierarchy: \(String(cString: dlerror()))")
        return nil
    }
    return unsafeBitCast(sym, to: AXUIElementCopyHierarchyFunc.self)
}()

// MARK: - Public API

public typealias AXAttribute = Accessibility.Attribute<Any>.Name

public extension AXAttribute {
    static let role = AXAttribute(kAXRoleAttribute)
    static let subrole = AXAttribute(kAXSubroleAttribute)
    static let roleDescription = AXAttribute(kAXRoleDescriptionAttribute)
    static let title = AXAttribute(kAXTitleAttribute)
    static let description = AXAttribute(kAXDescriptionAttribute)
    static let identifier = AXAttribute(kAXIdentifierAttribute)
    static let value = AXAttribute(kAXValueAttribute)
    static let enabled = AXAttribute(kAXEnabledAttribute)
    static let focused = AXAttribute(kAXFocusedAttribute)
    static let children = AXAttribute(kAXChildrenAttribute)
    static let frame = AXAttribute("AXFrame")
    static let position = AXAttribute(kAXPositionAttribute)
    static let size = AXAttribute(kAXSizeAttribute)
    static let parent = AXAttribute(kAXParentAttribute)
    static let selected = AXAttribute(kAXSelectedAttribute)
    static let help = AXAttribute(kAXHelpAttribute)
    static let placeholderValue = AXAttribute(kAXPlaceholderValueAttribute)
}

public extension Accessibility.Element {
    /// Default attributes fetched by `copyHierarchy`.
    static let defaultHierarchyAttributes: [AXAttribute] = [
        .role,
        .subrole,
        .roleDescription,
        .title,
        .description,
        .identifier,
        .value,
        .enabled,
        .focused,
        .children,
    ]

    /// Fetches the entire element hierarchy in a single call using private API `AXUIElementCopyHierarchy`.
    /// - Parameters:
    ///   - attributes: Attributes to prefetch for each element
    /// - Returns: Array of all elements in the hierarchy, or nil if the API is unavailable or call failed
    func copyHierarchy(
        attributes: [AXAttribute] = Accessibility.Element.defaultHierarchyAttributes
    ) -> [Accessibility.Element]? {
        guard let copyHierarchy = axUIElementCopyHierarchy else {
            return nil
        }

        let attributeStrings = attributes.map(\.value).map { $0 as CFString } as CFArray
        var hierarchy: CFArray?
        let result = copyHierarchy(raw, attributeStrings, nil, &hierarchy)

        guard result == .success, let hierarchy = hierarchy as? [AXUIElement] else {
            return nil
        }

        return hierarchy.map { Accessibility.Element(raw: $0) }
    }

    /// Experimental version of `recursiveChildren` using `AXUIElementCopyHierarchy`.
    /// Falls back to standard `recursiveChildren`
    func _recursiveChildren(
        attributes: [AXAttribute] = Accessibility.Element.defaultHierarchyAttributes
    ) -> AnySequence<Accessibility.Element> {
        if let hierarchy = copyHierarchy(attributes: attributes) {
            return AnySequence(hierarchy)
        }
        // Fallback to manual traversal
        return recursiveChildren()
    }
}
