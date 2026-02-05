import Foundation
import AccessibilityControl
import SwiftServerFoundation

public extension Accessibility.Element {
    struct Properties {
        var actions: [(Accessibility.Action.Name, String)] = []
        var attributes: [(Accessibility.Attribute<Any>.Name, Any)] = []
        var parAttributes: [Accessibility.ParameterizedAttribute<Any, Any>.Name] = []
    }

    struct ElementDescription {
        var path: [Int]
        var properties: Properties
    }

    func dumpProperties() -> Properties {
        var props = Properties()
        for act in (try? supportedActions()) ?? [] {
            props.actions.append((act.name, act.description))
        }
        for att in (try? supportedAttributes()) ?? [] {
            props.attributes.append((att.name, (try? att()) as Any))
        }
        for att in (try? supportedParameterizedAttributes()) ?? [] {
            props.parAttributes.append(att.name)
        }
        return props
    }

    private func _dumpRecursively(path: [Int], work: inout [ElementDescription]) {
        work.append(ElementDescription(path: path, properties: dumpProperties()))
        guard let children = try? self.children() else { return }
        for (idx, child) in children.enumerated() {
            child._dumpRecursively(path: path + [idx], work: &work)
        }
    }

    func dumpRecursively() -> [ElementDescription] {
        var ret: [ElementDescription] = []
        _dumpRecursively(path: [], work: &ret)
        return ret
    }

    func printAttributes<Target: TextOutputStream>(to ostream: inout Target) {
        for act in (try? supportedActions()) ?? [] {
            print("[action] \(act.name): \(act.description)", to: &ostream)
        }
        for att in (try? supportedAttributes()) ?? [] {
            print("[regular] \(att.name): \((try? att()) as Any)", to: &ostream)
        }
        for att in (try? supportedParameterizedAttributes()) ?? [] {
            print("[parameterized] \(att)", to: &ostream)
        }
    }

    func printAttributes() {
        #if DEBUG
        var str = ""
        printAttributes(to: &str)
        debugLog(str)
        #endif
    }

    private func _printRecursively<Target: TextOutputStream>(path: [Int], to ostream: inout Target) {
        print("ELEMENT [\(path.map(\.description).joined(separator: "."))] (\(self)):", to: &ostream)
        printAttributes(to: &ostream)
        guard let children = try? self.children() else { return }
        for (idx, child) in children.enumerated() {
            child._printRecursively(path: path + [idx], to: &ostream)
        }
    }

    func printRecursively<Target: TextOutputStream>(to ostream: inout Target) {
        _printRecursively(path: [], to: &ostream)
    }

    func printRecursively() {
        #if DEBUG
        var str = ""
        _printRecursively(path: [], to: &str)
        debugLog(str)
        #endif
    }

}
