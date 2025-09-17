import AccessibilityControl
import ApplicationServices
import Foundation

private func printAttribute(to output: inout some TextOutputStream, name: String, value: Any?, omitTrailingSpace: Bool = false) {
    guard let value else { return }
    let valueEscaped = if let struc = Accessibility.Struct(erased: value as AnyObject) {
        // this looks _much nicer_ compared to the default description
        "\(struc)".xmlEscaped
    } else {
        "\(value)".xmlEscaped
    }
    print("\(name)=\(valueEscaped.quoted)", terminator: omitTrailingSpace ? "" : " ", to: &output)
}

public struct XMLDumper {
    public static let defaultExcludedAttributes: Set<String> = [
        // children are printed specially, so we don't need to print them out as attributes
        "AXChildren", "AXChildrenInNavigationOrder",

        // avoid redundantly printing parent elements, which can quickly bloat the result
        "AXTopLevelUIElement", "AXMenuItemPrimaryUIElement", "AXParent", "AXWindow",
    ]
    
    static var attributesLikelyToContainPII: Set<String> {
        [
            kAXHelpAttribute,
            kAXDescriptionAttribute,
            kAXTitleAttribute,

            // text entry area values
            kAXValueAttribute,
            
            kAXLabelValueAttribute,
            kAXSelectedTextAttribute,
            kAXPlaceholderValueAttribute,
            kAXFilenameAttribute,
            kAXDocumentAttribute,
        ]
    }

    var maxDepth: Int? = nil
    var indentation = "  "
    var excludedRoles: Set<String> = []
    var excludedAttributes: Set<String> = XMLDumper.defaultExcludedAttributes
    var intendingToExcludePII = false
    var includeActions = true
    var includeSections = true
    var shallow = false

    func dump(
        _ element: Accessibility.Element,
        to output: inout some TextOutputStream,
        depth: Int = 0,
        indent: Int = 0,
        shallow: Bool? = nil,
        preamble: String? = nil,
    ) throws {
        let shallow = shallow ?? self.shallow
        let whitespace = String(repeating: indentation, count: indent)
        
        if let maxDepth {
            guard depth < maxDepth else {
                print(whitespace + "⚠️ reached max depth (\(depth) >= \(maxDepth))".asComment, to: &output)
                return
            }
        }

        let role: String
        do {
            role = try element.role()
        } catch {
            print(whitespace + "⚠️ couldn't obtain role, skipping \(element): \(String(describing: error))".asComment, to: &output)
            return
        }

        guard !excludedRoles.contains(role) else {
            return
        }

        let injectedComment = if let preamble { preamble.asComment + " " } else { "" }
        print("\(whitespace)\(injectedComment)<\(role)", terminator: " ", to: &output)

        // keep track of attributes that contain ui elements (as opposed to string/rect/etc.), so we can emit them as child XML elements instead of XML attributes
        var attributesPointingToElements = [String: [Accessibility.Element]]()

        if let supportedAttributes = try? element.supportedAttributes() {
            let attributes = Dictionary(
                supportedAttributes.filter { !excludedAttributes.contains($0.name.value) }.map { attribute in (attribute.name.value, try? attribute()) },
                uniquingKeysWith: { first, second in second },
            )

            let lastNonNilIndex = Array(attributes.values).lastIndex(where: { $0 != nil })

            for (index, (name, value)) in attributes.enumerated() {
                if let array = value as? [Any] {
                    guard let first = array.first, CFGetTypeID(first as CFTypeRef) == AXUIElementGetTypeID() else {
                        continue
                    }
                    // attribute value is of an array of ui elements
                    attributesPointingToElements[name, default: []].append(contentsOf: array.map {
                        Accessibility.Element(raw: $0 as! AXUIElement)
                    })
                    continue
                } else if let element = Accessibility.Element(erased: value as CFTypeRef) {
                    // attribute value is of a singular ui element
                    attributesPointingToElements[name, default: []].append(element)
                    continue
                }

                printAttribute(to: &output, name: name, value: value, omitTrailingSpace: index == lastNonNilIndex)
            }
        }

        // closing angle bracket of the opening tag
        print("> \(String(describing: element.raw).asComment)", to: &output)
        let whitespace2 = String(repeating: indentation, count: indent + 1)

        if !shallow {
            for (attributeContainingElementsName, containedElements) in attributesPointingToElements {
                print(whitespace2 + "attribute containing elements".asComment + " <\(attributeContainingElementsName)>", to: &output)
                for element in containedElements {
                    try dump(element, to: &output, depth: depth + 1, indent: indent + 2, shallow: true)
                }
                print("\(whitespace2)</\(attributeContainingElementsName)>", to: &output)
            }
        }

        defer { print("\(whitespace)</\(role)>", to: &output) }

        if includeActions, let actions = try? element.supportedActions(), !actions.isEmpty {
            for (index, action) in actions.enumerated() {
                print(whitespace2 + "actions[\(index)]".asComment + "<action", terminator: " ", to: &output)

                let actionName = action.name.value
                // some action names (maybe menu items?) are weird and look something like:
                //
                // "Name:Pin <NAME OF A CHAT>
                // Target:0x0
                // Selector:(null)"
                //
                // (yes, including the newlines.) skip these if we are intending to exclude PII
                if (intendingToExcludePII && actionName.hasPrefix("AX")) || !intendingToExcludePII {
                    printAttribute(to: &output, name: "name", value: actionName)
                }

                if !excludedAttributes.contains(kAXDescriptionAttribute) {
                    printAttribute(to: &output, name: "description", value: action.description, omitTrailingSpace: true)
                }
                print("></action>", to: &output)
            }
        }

        guard !shallow else {
            // used to avoid following cycles endlessly, since sections can point back up the tree etc.
            print(whitespace2 + "...".asComment, to: &output)
            return
        }

        if includeSections, let sections = try? element.sections() as [[String: Any]] {
            for (index, section) in sections.enumerated() {
                print(whitespace2 + "[\(index)]".asComment + " <section", terminator: " ", to: &output)
                printAttribute(to: &output, name: "uniqueID", value: section["SectionUniqueID"])
                printAttribute(to: &output, name: "description", value: section["SectionDescription"], omitTrailingSpace: true)

                if case let object = section["SectionObject"] as CFTypeRef, CFGetTypeID(object) == AXUIElementGetTypeID() {
                    print(">", to: &output)
                    if let element = Accessibility.Element(axRaw: object) {
                        try dump(element, to: &output, depth: depth + 1, indent: indent + 2)
                    }
                    print("\(whitespace2)</section>", to: &output)
                } else {
                    print("></section>", to: &output)
                }
            }
        }

        guard let children = try? element.children() else { return }
        for (index, child) in children.enumerated() {
            try dump(child, to: &output, depth: depth + 1, indent: indent + 1, preamble: "children[\(index)]")
        }
    }
}

public extension Accessibility.Element {
    func dumpXML(
        to output: inout some TextOutputStream,
        shallow: Bool = false,
        maxDepth: Int? = nil,
        excludingPII: Bool = false,
        excludingElementsWithRoles excludedRoles: Set<String> = [],
        excludingAttributes excludedAttributes: Set<String> = XMLDumper.defaultExcludedAttributes,
        includeActions: Bool = true,
        includeSections: Bool = true,
    ) throws {
        var excludedAttributes = excludedAttributes
        if excludingPII {
            excludedAttributes.formUnion(XMLDumper.attributesLikelyToContainPII)
        }
        
        return try XMLDumper(
            maxDepth: maxDepth,
            excludedRoles: excludedRoles,
            excludedAttributes: excludedAttributes,
            intendingToExcludePII: excludingPII,
            includeActions: includeActions,
            includeSections: includeSections,
            shallow: shallow,
        ).dump(self, to: &output)
    }
}

// MARK: -

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    var quoted: String {
        "\"\(self)\""
    }

    var asComment: String {
        "<!-- \(self) -->"
    }
}
