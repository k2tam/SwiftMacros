# SwiftMacros — Agent Guide

`@SnakeCodable` generates `CodingKeys`, `init(from:)`, `encode(to:)` and adds `Codable` conformance. Use it to map snake_case JSON to camelCase Swift structs.

```swift
import SwiftMacros
```

## API

| Macro | On | Effect |
|---|---|---|
| `@SnakeCodable` | struct | Generates Codable for all stored properties |
| `@CodedAt("key")` | property | Use this exact JSON key instead of auto snake_case |
| `@Default(expr)` | property | Use `expr` when key is missing, `null`, or wrong type |
| `@IgnoreCoding` | property | Skip entirely (must have an initial value) |

## Mapping raw JSON → struct

1. One Swift property per JSON key. Name it camelCase; the key is derived automatically:
   `userName` → `user_name`, `avatarURL` → `avatar_url`, `userURLString` → `user_url_string`.
2. If the JSON key does not equal the auto snake_case of the name, add `@CodedAt("<json key>")`.
   Typical cases: `id` → `userId`, keys with digits (`address_2`), camelCase/odd keys (`isVIP`, `type`).
3. Pick the type from the JSON value and its reliability:

| JSON value | Swift declaration |
|---|---|
| always present | `var x: T` (throws if missing) |
| may be missing / `null` | `var x: T?` |
| may be missing, want fallback | `@Default(v) var x: T` |
| nested object | a separate `@SnakeCodable struct` (or any `Codable`) |
| array of objects | `[NestedType]` |

4. Always write an explicit type annotation (`var x: Int`, not `var x = 0`) — otherwise compile error.

### Example

```json
{ "id": 42, "user_name": "tam", "avatar_url": null,
  "profile": { "full_name": "Tam Bui", "address_2": "HCM" },
  "tags": ["a", "b"] }
```

```swift
@SnakeCodable
struct User {
    @CodedAt("id") var userId: Int
    var userName: String
    var avatarURL: String?
    @Default(18) var age: Int          // not in JSON -> 18
    var profile: Profile
    @Default([]) var tags: [String]
    @IgnoreCoding var cache: [String] = []
    var displayName: String { "@\(userName)" } // computed: ignored
}

@SnakeCodable
struct Profile {
    var fullName: String
    @CodedAt("address_2") var address2: String?
}

let user = try JSONDecoder().decode(User.self, from: data)
```

## Gotchas

- **Do not** set `decoder.keyDecodingStrategy = .convertFromSnakeCase` (or the encoder equivalent) — keys are already snake_case; leave the default strategy.
- Optional fields decode with `try?`: a **wrong type becomes `nil` silently**, not an error.
- Encoding omits `nil` optionals (key absent, not `null`).
- Generated members are `internal` — not usable for `public` types across modules.
- Generated `init(from:)` removes the struct's implicit memberwise init; write one manually if needed.
- Declare one property per line (`var a: Int, b: Int` only maps `a`).
- `static` and computed properties are skipped. A `let` with an initial value must be `@IgnoreCoding`.
- Structs only (classes would need `required init`).

## Layout

Each macro group gets its own folder, mirrored across the targets.

- `Sources/SwiftMacros/Codable/SnakeCodable.swift` — public macro declarations
- `Sources/SwiftMacrosMacros/Codable/SnakeCodableMacro.swift` — implementation (`SnakeCodableMacro`, `MarkerMacro`, key logic in `snakeCase`)
- `Sources/SwiftMacrosMacros/Plugin.swift` — `CompilerPlugin`; register every new macro in `providingMacros`
- `Sources/SwiftMacrosMacros/MacroError.swift` — shared error type
- `Sources/SwiftMacrosClient/main.swift` — runnable example (`swift run SwiftMacrosClient`)
- `Tests/SwiftMacrosTests/Codable/` — tests per group
