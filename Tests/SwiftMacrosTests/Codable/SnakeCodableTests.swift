import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
import Testing

// Macro implementations build for the host, so the corresponding module is not available when cross-compiling. Cross-compiled tests may still make use of the macro itself in end-to-end tests.
#if canImport(SwiftMacrosMacros)
import SwiftMacrosMacros

let testMacros: [String: MacroSpec] = [
    "SnakeCodable": MacroSpec(type: SnakeCodableMacro.self, conformances: ["Codable"]),
    "CodedAt": MacroSpec(type: MarkerMacro.self),
    "Default": MacroSpec(type: MarkerMacro.self),
    "IgnoreCoding": MacroSpec(type: MarkerMacro.self),
]

/// Bọc assertMacroExpansion để báo lỗi qua Swift Testing (không cần XCTest/Xcode).
func assertExpansion(
    _ source: String,
    expandedSource: String,
    diagnostics: [DiagnosticSpec] = [],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) {
    assertMacroExpansion(
        source,
        expandedSource: expandedSource,
        diagnostics: diagnostics,
        macroSpecs: testMacros,
        failureHandler: { failure in
            Issue.record(
                Comment(rawValue: failure.message),
                sourceLocation: SourceLocation(
                    fileID: failure.location.fileID,
                    filePath: failure.location.filePath,
                    line: failure.location.line,
                    column: failure.location.column
                )
            )
        },
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}
#endif

@Suite struct SnakeCodableTests {
    @Test func snakeCaseKeys() throws {
        #if canImport(SwiftMacrosMacros)
        assertExpansion(
            """
            @SnakeCodable
            struct User {
                var userName: String
                var age: Int
            }
            """,
            expandedSource: """
            struct User {
                var userName: String
                var age: Int

                enum CodingKeys: String, CodingKey {
                    case userName = "user_name"
                    case age = "age"
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.userName = try container.decode(String.self, forKey: .userName)
                    self.age = try container.decode(Int.self, forKey: .age)
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(self.userName, forKey: .userName)
                    try container.encode(self.age, forKey: .age)
                }
            }

            extension User: Codable {
            }
            """
        )
        #else
        // macros are only supported when running tests for the host platform
        #endif
    }

    @Test func markers() throws {
        #if canImport(SwiftMacrosMacros)
        assertExpansion(
            """
            @SnakeCodable
            struct User {
                @CodedAt("id") var userId: Int
                @Default(18) var age: Int
                var nickName: String?
                @IgnoreCoding var cache: [String] = []
                static var shared: Int = 0
                var display: String { "" }
            }
            """,
            expandedSource: """
            struct User {
                var userId: Int
                var age: Int
                var nickName: String?
                var cache: [String] = []
                static var shared: Int = 0
                var display: String { "" }

                enum CodingKeys: String, CodingKey {
                    case userId = "id"
                    case age = "age"
                    case nickName = "nick_name"
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.userId = try container.decode(Int.self, forKey: .userId)
                    self.age = (try? container.decodeIfPresent(Int.self, forKey: .age)) ?? 18
                    self.nickName = try? container.decodeIfPresent(String.self, forKey: .nickName)
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(self.userId, forKey: .userId)
                    try container.encode(self.age, forKey: .age)
                    try container.encodeIfPresent(self.nickName, forKey: .nickName)
                }
            }

            extension User: Codable {
            }
            """
        )
        #else
        // macros are only supported when running tests for the host platform
        #endif
    }

    @Test func missingTypeAnnotationEmitsError() throws {
        #if canImport(SwiftMacrosMacros)
        assertExpansion(
            """
            @SnakeCodable
            struct User {
                var name = "tam"
            }
            """,
            expandedSource: """
            struct User {
                var name = "tam"
            }

            extension User: Codable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Property 'name' cần khai báo type rõ ràng (vd: var name: String?)",
                    line: 1,
                    column: 1
                )
            ]
        )
        #else
        // macros are only supported when running tests for the host platform
        #endif
    }
}
