/// Sinh `CodingKeys` (snake_case), `init(from:)`, `encode(to:)` và tự conform `Codable`.
///
///     @SnakeCodable
///     struct User {
///         var userName: String          // key: "user_name"
///         @CodedAt("id") var userId: Int // key: "id"
///         @Default(0) var age: Int       // thiếu key -> 0
///         @IgnoreCoding var cache: [String] = []
///     }
@attached(member, names: named(CodingKeys), named(init(from:)), named(encode(to:)))
@attached(extension, conformances: Codable)
public macro SnakeCodable() =
    #externalMacro(module: "SwiftMacrosMacros", type: "SnakeCodableMacro")

// Các marker, chỉ để đánh dấu property
@attached(peer)
public macro CodedAt(_ key: String) =
    #externalMacro(module: "SwiftMacrosMacros", type: "MarkerMacro")

@attached(peer)
public macro Default<T>(_ value: T) =
    #externalMacro(module: "SwiftMacrosMacros", type: "MarkerMacro")

@attached(peer)
public macro IgnoreCoding() =
    #externalMacro(module: "SwiftMacrosMacros", type: "MarkerMacro")
