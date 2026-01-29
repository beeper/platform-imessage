import AccessibilityControl
import ApplicationServices
import Logging

private let log = Logger(swiftServerLabel: "hiservices")

// MARK: - Private HIServices symbols

/// Handle to the HIServices framework for loading private symbols
private let hiServicesHandle: UnsafeMutableRawPointer? = {
    dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        RTLD_NOW
    )
}()

/// Loads a symbol from HIServices and casts it to the specified type
private func loadHIServicesSymbol<T>(_ name: String) -> T? {
    guard let handle = hiServicesHandle else {
        log.warning("HIServices not loaded, cannot find \(name)")
        return nil
    }
    guard let sym = dlsym(handle, name) else {
        log.warning("Failed to find \(name): \(String(cString: dlerror()))")
        return nil
    }
    return unsafeBitCast(sym, to: T.self)
}

/// Loads a CFString constant from HIServices
private func loadHIServicesCFString(_ name: String) -> CFString? {
    guard let handle = hiServicesHandle else { return nil }
    guard let sym = dlsym(handle, name) else { return nil }
    let ptr = sym.assumingMemoryBound(to: CFString?.self)
    return ptr.pointee
}

// MARK: - AXUIElementCopyHierarchy private keys

/// Keys for the options dictionary passed to `_AXUIElementCopyHierarchy`
public enum AXCopyHierarchyOptionKey {
    /// Attributes that return arrays (CFArray of attribute names)
    public static let arrayAttributes: CFString? = loadHIServicesCFString("kAXUIElementCopyHierarchyArrayAttributesKey")

    /// Attributes to skip inspection for (CFArray of attribute names)
    public static let skipInspectionForAttributes: CFString? = loadHIServicesCFString("kAXUIElementCopyHierarchySkipInspectionForAttributesKey")

    /// Maximum count for array attributes (CFNumber)
    public static let maxArrayCount: CFString? = loadHIServicesCFString("kAXUIElementCopyHierarchyMaxArrayCountKey")

    /// Maximum depth to traverse (CFNumber)
    public static let maxDepth: CFString? = loadHIServicesCFString("kAXUIElementCopyHierarchyMaxDepthKey")

    /// Whether to return attribute errors (CFBoolean)
    public static let returnAttributeErrors: CFString? = loadHIServicesCFString("kAXUIElementCopyHierarchyReturnAttributeErrorsKey")

    /// Whether to truncate long strings (CFBoolean)
    public static let truncateStrings: CFString? = loadHIServicesCFString("kAXUIElementCopyHierarchyTruncateStringsKey")
}

/// Keys for values in the result dictionary from `_AXUIElementCopyHierarchy`
public enum AXCopyHierarchyResultKey {
    /// The result value (CFArray of elements with prefetched attributes)
    public static let value: CFString? = loadHIServicesCFString("kAXUIElementCopyHierarchyResultValueKey")

    /// Count of results (CFNumber)
    public static let count: CFString? = loadHIServicesCFString("kAXUIElementCopyHierarchyResultCountKey")

    /// Error information (CFDictionary)
    public static let error: CFString? = loadHIServicesCFString("kAXUIElementCopyHierarchyResultErrorKey")

    /// Marker for incomplete results (CFBoolean)
    public static let incomplete: CFString? = loadHIServicesCFString("kAXUIElementCopyHierarchyIncompleteResultKey")
}

// MARK: - AXUIElementCopyHierarchy function

/// Signature: `AXError _AXUIElementCopyHierarchy(AXUIElement, CFArray attributes, CFDictionary? options, CFTypeRef* result)`
private typealias AXUIElementCopyHierarchyFunc = @convention(c) (
    AXUIElement,                       // element to traverse
    CFArray,                           // attributes to prefetch (required, must be non-empty)
    CFDictionary?,                     // options dictionary (see AXCopyHierarchyOptionKey)
    UnsafeMutablePointer<CFTypeRef?>   // output: result (CFArray of elements or CFDictionary with result keys)
) -> AXError

private let axUIElementCopyHierarchy: AXUIElementCopyHierarchyFunc? = loadHIServicesSymbol("AXUIElementCopyHierarchy")

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

/// Options for `copyHierarchy`
public struct CopyHierarchyOptions {
    /// Attributes that return arrays (e.g., AXChildren)
    public var arrayAttributes: [AXAttribute]?

    /// Attributes to skip inspection for (optimization)
    public var skipInspectionForAttributes: [AXAttribute]?

    /// Maximum count for array attributes (limits children returned per element)
    public var maxArrayCount: Int?

    /// Maximum depth to traverse in the hierarchy
    public var maxDepth: Int?

    /// Whether to include attribute error information in results
    public var returnAttributeErrors: Bool?

    /// Whether to truncate long string values
    public var truncateStrings: Bool?

    public init(
        arrayAttributes: [AXAttribute]? = nil,
        skipInspectionForAttributes: [AXAttribute]? = nil,
        maxArrayCount: Int? = nil,
        maxDepth: Int? = nil,
        returnAttributeErrors: Bool? = nil,
        truncateStrings: Bool? = nil
    ) {
        self.arrayAttributes = arrayAttributes
        self.skipInspectionForAttributes = skipInspectionForAttributes
        self.maxArrayCount = maxArrayCount
        self.maxDepth = maxDepth
        self.returnAttributeErrors = returnAttributeErrors
        self.truncateStrings = truncateStrings
    }

    /// Convert to CFDictionary for passing to the private API
    func toCFDictionary() -> CFDictionary? {
        var dict = [CFString: Any]()

        if let arrayAttributes, let key = AXCopyHierarchyOptionKey.arrayAttributes {
            dict[key] = arrayAttributes.map(\.value) as CFArray
        }
        if let skipInspectionForAttributes, let key = AXCopyHierarchyOptionKey.skipInspectionForAttributes {
            dict[key] = skipInspectionForAttributes.map(\.value) as CFArray
        }
        if let maxArrayCount, let key = AXCopyHierarchyOptionKey.maxArrayCount {
            dict[key] = maxArrayCount as CFNumber
        }
        if let maxDepth, let key = AXCopyHierarchyOptionKey.maxDepth {
            dict[key] = maxDepth as CFNumber
        }
        if let returnAttributeErrors, let key = AXCopyHierarchyOptionKey.returnAttributeErrors {
            dict[key] = returnAttributeErrors as CFBoolean
        }
        if let truncateStrings, let key = AXCopyHierarchyOptionKey.truncateStrings {
            dict[key] = truncateStrings as CFBoolean
        }

        return dict.isEmpty ? nil : dict as CFDictionary
    }
}

/// Result from `copyHierarchy` when detailed result info is requested
public struct CopyHierarchyResult {
    /// The elements in the hierarchy with prefetched attributes
    public let elements: [Accessibility.Element]

    /// Whether the result is incomplete (hierarchy was truncated)
    public let isIncomplete: Bool

    /// Error information if `returnAttributeErrors` was enabled
    public let errors: [String: Any]?
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
    ///   - options: Options controlling hierarchy traversal (depth limits, etc.)
    /// - Returns: Array of all elements in the hierarchy, or nil if the API is unavailable or call failed
    func copyHierarchy(
        attributes: [AXAttribute] = Accessibility.Element.defaultHierarchyAttributes,
        options: CopyHierarchyOptions? = nil
    ) -> [Accessibility.Element]? {
        guard let copyHierarchy = axUIElementCopyHierarchy else {
            log.warning("AXUIElementCopyHierarchy not available")
            return nil
        }

        let attributeStrings = attributes.map(\.value).map { $0 as CFString } as CFArray
        let optionsDict = options?.toCFDictionary()

        var resultRef: CFTypeRef?
        let status = copyHierarchy(raw, attributeStrings, optionsDict, &resultRef)

        guard status == .success, let resultRef else {
            log.warning("AXUIElementCopyHierarchy failed with status: \(status)")
            return nil
        }

        // Result can be either a CFArray directly or a CFDictionary with result keys
        if let array = resultRef as? [AXUIElement] {
            return array.map { Accessibility.Element(raw: $0) }
        }

        // Try to cast as NSDictionary first (more flexible than [String: Any])
        // The dictionary maps AXUIElement -> attribute dictionary
        // Each key is an AXUIElement, value is its prefetched attributes
        if let nsDict = resultRef as? NSDictionary {
            var elements = [Accessibility.Element]()
            for key in nsDict.allKeys {
                if CFGetTypeID(key as CFTypeRef) == AXUIElementGetTypeID() {
                    elements.append(Accessibility.Element(raw: key as! AXUIElement))
                }
            }


            if !elements.isEmpty {
                return elements
            }

            // Try result key lookup as fallback
            if let valueKey = AXCopyHierarchyResultKey.value as String?,
               let array = nsDict[valueKey] as? [AXUIElement] {
                return array.map { Accessibility.Element(raw: $0) }
            }
        }

        log.warning("AXUIElementCopyHierarchy returned unexpected type: \(CFGetTypeID(resultRef))")
        return nil
    }

    /// Fetches the entire element hierarchy with detailed result information.
    /// - Parameters:
    ///   - attributes: Attributes to prefetch for each element
    ///   - options: Options controlling hierarchy traversal
    /// - Returns: Detailed result including elements, completion status, and errors
    func copyHierarchyDetailed(
        attributes: [AXAttribute] = Accessibility.Element.defaultHierarchyAttributes,
        options: CopyHierarchyOptions? = nil
    ) -> CopyHierarchyResult? {
        guard let copyHierarchy = axUIElementCopyHierarchy else {
            log.warning("AXUIElementCopyHierarchy not available")
            return nil
        }

        let attributeStrings = attributes.map(\.value).map { $0 as CFString } as CFArray
        let optionsDict = options?.toCFDictionary()

        var resultRef: CFTypeRef?
        let status = copyHierarchy(raw, attributeStrings, optionsDict, &resultRef)

        guard status == .success, let resultRef else {
            log.warning("AXUIElementCopyHierarchy failed with status: \(status)")
            return nil
        }

        // Handle direct array result
        if let array = resultRef as? [AXUIElement] {
            return CopyHierarchyResult(
                elements: array.map { Accessibility.Element(raw: $0) },
                isIncomplete: false,
                errors: nil
            )
        }

        // Handle dictionary result
        if let dict = resultRef as? [String: Any] {
            var elements = [Accessibility.Element]()
            var isIncomplete = false
            var errors: [String: Any]?

            if let valueKey = AXCopyHierarchyResultKey.value as String?,
               let array = dict[valueKey] as? [AXUIElement] {
                elements = array.map { Accessibility.Element(raw: $0) }
            }

            if let incompleteKey = AXCopyHierarchyResultKey.incomplete as String?,
               let incomplete = dict[incompleteKey] as? Bool {
                isIncomplete = incomplete
            }

            if let errorKey = AXCopyHierarchyResultKey.error as String?,
               let errorDict = dict[errorKey] as? [String: Any] {
                errors = errorDict
            }

            return CopyHierarchyResult(
                elements: elements,
                isIncomplete: isIncomplete,
                errors: errors
            )
        }

        return nil
    }

    /// Experimental version of `recursiveChildren` using `AXUIElementCopyHierarchy`.
    /// Falls back to standard `recursiveChildren`
    func _recursiveChildren(
        attributes: [AXAttribute] = Accessibility.Element.defaultHierarchyAttributes,
        options: CopyHierarchyOptions? = nil
    ) -> AnySequence<Accessibility.Element> {
        if let hierarchy = copyHierarchy(attributes: attributes, options: options) {
            return AnySequence(hierarchy)
        }
        // Fallback to manual traversal
        return recursiveChildren()
    }
}
