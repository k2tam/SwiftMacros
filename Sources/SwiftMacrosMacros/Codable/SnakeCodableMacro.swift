import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// Marker dùng chung cho @CodedAt, @Default, @IgnoreCoding: không sinh gì
public struct MarkerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

private struct Field {
    let name: String
    let type: String          // type dùng để decode (đã bỏ dấu ? nếu optional)
    let isOptional: Bool
    let key: String
    let defaultValue: String? // nguyên văn biểu thức trong @Default(...)
}

public struct SnakeCodableMacro: MemberMacro, ExtensionMacro {

    // MARK: Member
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let fields = try fields(of: declaration)

        let cases = fields.map { "case \($0.name) = \"\($0.key)\"" }.joined(separator: "\n")
        let codingKeys = """
        enum CodingKeys: String, CodingKey {
        \(cases)
        }
        """

        let decodeLines = fields.map { f -> String in
            if let def = f.defaultValue {
                return "self.\(f.name) = (try? container.decodeIfPresent(\(f.type).self, forKey: .\(f.name))) ?? \(def)"
            } else if f.isOptional {
                return "self.\(f.name) = try? container.decodeIfPresent(\(f.type).self, forKey: .\(f.name))"
            } else {
                return "self.\(f.name) = try container.decode(\(f.type).self, forKey: .\(f.name))"
            }
        }.joined(separator: "\n")

        let encodeLines = fields.map { f -> String in
            let method = f.isOptional ? "encodeIfPresent" : "encode"
            return "try container.\(method)(self.\(f.name), forKey: .\(f.name))"
        }.joined(separator: "\n")

        let initDecl = """
        init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        \(decodeLines)
        }
        """
        let encodeDecl = """
        func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        \(encodeLines)
        }
        """

        return [
            DeclSyntax(stringLiteral: codingKeys),
            DeclSyntax(stringLiteral: initDecl),
            DeclSyntax(stringLiteral: encodeDecl),
        ]
    }

    // MARK: Extension (tự thêm : Codable)
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        if protocols.isEmpty { return [] }   // đã conform rồi thì thôi
        let ext: DeclSyntax = "extension \(type.trimmed): Codable {}"
        return [ext.cast(ExtensionDeclSyntax.self)]
    }

    // MARK: Phân tích property
    private static func fields(of declaration: some DeclGroupSyntax) throws -> [Field] {
        var result: [Field] = []

        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: { $0.name.text == "static" }),
                  let binding = variable.bindings.first,
                  binding.accessorBlock == nil,          // bỏ computed property
                  let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            else { continue }

            // @IgnoreCoding: bỏ qua hoàn toàn
            if attribute("IgnoreCoding", in: variable) != nil { continue }

            guard let typeSyntax = binding.typeAnnotation?.type else {
                throw MacroError("Property '\(name)' cần khai báo type rõ ràng (vd: var \(name): String?)")
            }

            let isOptional: Bool
            let type: String
            if let optional = typeSyntax.as(OptionalTypeSyntax.self) {
                isOptional = true
                type = optional.wrappedType.trimmedDescription
            } else {
                isOptional = false
                type = typeSyntax.trimmedDescription
            }

            // @CodedAt("...") hoặc snake_case tự động
            let key = stringArgument(of: attribute("CodedAt", in: variable)) ?? snakeCase(name)

            // @Default(...): lấy nguyên văn biểu thức
            let defaultValue = attribute("Default", in: variable)
                .flatMap { $0.arguments?.as(LabeledExprListSyntax.self)?.first?.expression.trimmedDescription }

            result.append(Field(name: name, type: type, isOptional: isOptional,
                                key: key, defaultValue: defaultValue))
        }
        return result
    }

    private static func attribute(_ name: String, in variable: VariableDeclSyntax) -> AttributeSyntax? {
        variable.attributes
            .compactMap { $0.as(AttributeSyntax.self) }
            .first { $0.attributeName.trimmedDescription == name }
    }

    private static func stringArgument(of attribute: AttributeSyntax?) -> String? {
        attribute?.arguments?.as(LabeledExprListSyntax.self)?.first?
            .expression.as(StringLiteralExprSyntax.self)?.segments.description
    }

    private static func snakeCase(_ s: String) -> String {
        // Gom cụm chữ hoa liên tiếp thành một từ: avatarURL -> avatar_url, userURLString -> user_url_string
        let chars = Array(s)
        var result = ""
        for (i, ch) in chars.enumerated() {
            if ch.isUppercase, i > 0 {
                let prev = chars[i - 1]
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if !prev.isUppercase || nextIsLower { result += "_" }
            }
            result += ch.lowercased()
        }
        return result
    }
}
