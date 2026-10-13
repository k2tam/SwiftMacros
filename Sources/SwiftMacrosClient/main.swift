import Foundation
import SwiftMacros

@SnakeCodable
struct User {
    var userName: String
    @CodedAt("id") var userId: Int
    @Default(18) var age: Int
    var avatarURL: String?
    @IgnoreCoding var cache: [String] = []

    var displayName: String { "@\(userName)" } // computed -> bị bỏ qua
}

// 1. Decode: JSON snake_case, thiếu "age" -> dùng default 18
let json = """
{
    "user_name": "tam",
    "id": 42,
    "avatar_url": null
}
""".data(using: .utf8)!

do {
    let user = try JSONDecoder().decode(User.self, from: json)
    print("Decoded:", user.userName, user.userId, user.age, user.avatarURL ?? "nil", user.displayName)

    // 2. Encode ngược lại
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(user)
    print("Encoded:\n" + String(decoding: data, as: UTF8.self))
} catch {
    print("Error:", error)
}
