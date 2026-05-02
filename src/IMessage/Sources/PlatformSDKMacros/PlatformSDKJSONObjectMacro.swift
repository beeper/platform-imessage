import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct PlatformSDKMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        PlatformSDKJSONObjectMacro.self,
    ]
}

public enum PlatformSDKJSONObjectMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let properties = declaration.memberBlock.members.compactMap(storedProperty)
        let entries = properties.map { property in
            #""\#(property.name)": PlatformSDKJSONEncoding.encode(\#(property.name)),"#
        }

        let body = entries.map { "            \($0)" }.joined(separator: "\n")
        var members = [DeclSyntax(stringLiteral: """
        public var jsonObject: JSONObject {
            compactDictionary([
        \(body)
            ])
        }
        """)]

        if !hasMemberwiseInitializer(in: declaration, assigning: properties) {
            members.append(DeclSyntax(stringLiteral: initializer(for: properties)))
        }

        return members
    }

    private struct StoredProperty {
        let name: String
        let type: String
        let hasInitializer: Bool
        let hasNilDefault: Bool
    }

    private static func storedProperty(from member: MemberBlockItemSyntax) -> StoredProperty? {
        guard let variable = member.decl.as(VariableDeclSyntax.self),
              variable.modifiers.allSatisfy({ modifier in
                let text = modifier.name.text
                return text != "static" && text != "class"
              }),
              variable.bindings.count == 1,
              let binding = variable.bindings.first,
              binding.accessorBlock == nil,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let type = binding.typeAnnotation?.type.trimmedDescription else {
            return nil
        }

            return StoredProperty(
                name: identifier,
                type: type,
                hasInitializer: binding.initializer != nil,
                hasNilDefault: type.hasSuffix("?")
            )
    }

    private static func hasMemberwiseInitializer(in declaration: some DeclGroupSyntax, assigning properties: [StoredProperty]) -> Bool {
        let propertyNames = properties.filter { !$0.hasInitializer }.map(\.name)
        return declaration.memberBlock.members.contains { member in
            guard let initializer = member.decl.as(InitializerDeclSyntax.self) else {
                return false
            }
            let parameterNames = initializer.signature.parameterClause.parameters.map(\.firstName.text)
            return parameterNames == propertyNames
        }
    }

    private static func initializer(for properties: [StoredProperty]) -> String {
        let assignedProperties = properties.filter { !$0.hasInitializer }
        guard !assignedProperties.isEmpty else {
            return "public init() {}"
        }

        let parameters = assignedProperties.map { property in
            let defaultValue = property.hasNilDefault ? " = nil" : ""
            return "            \(property.name): \(property.type)\(defaultValue)"
        }.joined(separator: ",\n")
        let assignments = assignedProperties.map { property in
            "            self.\(property.name) = \(property.name)"
        }.joined(separator: "\n")

        return """
        public init(
        \(parameters)
        ) {
        \(assignments)
        }
        """
    }

}
