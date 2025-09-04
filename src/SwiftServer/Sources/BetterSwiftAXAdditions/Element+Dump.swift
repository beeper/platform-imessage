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

extension Accessibility.Element {
    func dumpXML(to output: inout some TextOutputStream, indent: Int = 0, shallow: Bool = false, preamble: String? = nil) throws {
        let whitespace = String(repeating: "  ", count: indent)

        guard let role = try? self.role() else {
            print(whitespace + "⚠️ couldn't obtain role, skipping (\(self))".asComment, to: &output)
            return
        }
        let injectedComment = if let preamble { preamble.asComment + " " } else { "" }
        print("\(whitespace)\(injectedComment)<\(role)", terminator: " ", to: &output)

        var attributesPointingToElements = [String: [Accessibility.Element]]()
        if let supportedAttributes = try? supportedAttributes() {
            let attributes = Dictionary(
                supportedAttributes.filter { $0.name.value != kAXChildrenAttribute }.map { attribute in (attribute.name.value, try? attribute()) },
                uniquingKeysWith: { first, second in second },
            )

            let lastNonNilIndex = Array(attributes.values).lastIndex(where: { $0 != nil })

            for (index, (name, value)) in attributes.enumerated() {
                // collect attribute values which contain ui elements separately, so we can emit them as child XML elements
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
        print(">", to: &output)
        let whitespace2 = String(repeating: "  ", count: indent + 1)

        if !shallow {
            for (attributeContainingElementsName, containedElements) in attributesPointingToElements {
                print(whitespace2 + "attribute containing element(s)".asComment + " <\(attributeContainingElementsName)>", to: &output)
                for element in containedElements {
                    try element.dumpXML(to: &output, indent: indent + 2, shallow: true)
                }
                print("\(whitespace2)</\(attributeContainingElementsName)>", to: &output)
            }
        }

        defer { print("\(whitespace)</\(role)>", to: &output) }

        if let actions = try? supportedActions(), !actions.isEmpty {
            for (index, action) in actions.enumerated() {
                print(whitespace2 + "actions[\(index)]".asComment + "<action", terminator: " ", to: &output)
                printAttribute(to: &output, name: "name", value: action.name.value)
                printAttribute(to: &output, name: "description", value: action.description, omitTrailingSpace: true)
                print("></action>", to: &output)
            }
        }

        guard !shallow else {
            // used to avoid following cycles endlessly, since sections can point back up the tree etc.
            print(whitespace2 + "omitting children, sections, etc.".asComment, to: &output)
            return
        }

        if let sections = try? self.sections() as [[String: Any]] {
            for (index, section) in sections.enumerated() {
                print(whitespace2 + "[\(index)]".asComment + " <section", terminator: " ", to: &output)
                printAttribute(to: &output, name: "uniqueID", value: section["SectionUniqueID"])
                printAttribute(to: &output, name: "description", value: section["SectionDescription"], omitTrailingSpace: true)

                if case let object = section["SectionObject"] as CFTypeRef, CFGetTypeID(object) == AXUIElementGetTypeID() {
                    let element = Accessibility.Element(axRaw: object)
                    print(">", to: &output)
                    try element?.dumpXML(to: &output, indent: indent + 2)
                    print("\(whitespace2)</section>", to: &output)
                } else {
                    print("></section>", to: &output)
                }
            }
        }

        guard let children = try? self.children() else { return }
        for (index, child) in children.enumerated() {
            try child.dumpXML(to: &output, indent: indent + 1, preamble: "[\(index)]")
        }
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
