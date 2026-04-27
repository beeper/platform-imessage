import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct IMessageMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        PlatformSDKJSONObjectMacro.self,
        PlatformSDKJSONKeyMacro.self,
    ]
}

public enum PlatformSDKJSONObjectMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let entries = declaration.memberBlock.members.compactMap { member -> String? in
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  variable.modifiers.allSatisfy({ modifier in
                      let text = modifier.name.text
                      return text != "static" && text != "class"
                  }),
                  variable.bindings.count == 1,
                  let binding = variable.bindings.first,
                  binding.accessorBlock == nil,
                  let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                return nil
            }
            let key = jsonKey(in: variable.attributes) ?? identifier
            return #""\#(key)": PlatformSDKJSONEncoding.encode(\#(identifier)),"#
        }

        let body = entries.map { "            \($0)" }.joined(separator: "\n")
        return [DeclSyntax(stringLiteral: """
        public var jsonObject: JSONObject {
            compactDictionary([
        \(body)
            ])
        }
        """)]
    }

    private static func jsonKey(in attributes: AttributeListSyntax) -> String? {
        for attribute in attributes {
            guard let attribute = attribute.as(AttributeSyntax.self),
                  attribute.attributeName.trimmedDescription == "PlatformSDKJSONKey",
                  let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
                  let expression = arguments.first?.expression.as(StringLiteralExprSyntax.self) else {
                continue
            }
            return expression.segments.compactMap { segment in
                segment.as(StringSegmentSyntax.self)?.content.text
            }.joined()
        }
        return nil
    }
}

public enum PlatformSDKJSONKeyMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
