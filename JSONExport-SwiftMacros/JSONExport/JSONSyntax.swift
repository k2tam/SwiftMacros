//
//  JSONSyntax.swift
//  JSONExport
//
//  Locates syntax errors and foldable blocks in raw JSON text.
//  All locations are UTF-16 offsets, so they can be used directly with NSString / NSTextView ranges.
//

import Foundation

struct JSONSyntaxError {
    let location: Int
    let message: String
}

struct JSONFoldRegion {
    //Location of the opening '{' or '['
    let openLocation: Int
    //Location of the matching '}' or ']'
    let closeLocation: Int
    //Nesting level, 0 for the root object/array
    let depth: Int

    //The characters between the brackets, hidden while the region is folded
    var hiddenRange: NSRange {
        return NSRange(location: openLocation + 1, length: closeLocation - openLocation - 1)
    }
}

enum JSONSyntax {

    /**
     Returns the first syntax error in the passed JSON text, or nil if the text is valid.
     Control characters are tolerated the same way the generator tolerates them (it strips them before parsing).
     */
    static func firstError(in text: String) -> JSONSyntaxError? {
        var parser = Parser(chars: Array(text.utf16))
        do {
            try parser.parseDocument()
            return nil
        } catch let failure as Parser.Failure {
            return JSONSyntaxError(location: failure.location, message: failure.message)
        } catch {
            return nil
        }
    }

    /**
     Returns every matched bracket pair in the passed UTF-16 characters, ignoring brackets inside strings.
     */
    static func foldRegions(in chars: [UInt16]) -> [JSONFoldRegion] {
        var regions = [JSONFoldRegion]()
        var stack = [Int]()
        var inString = false
        var escaped = false
        for (index, char) in chars.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if char == Char.backslash {
                    escaped = true
                } else if char == Char.quote || char == Char.newline {
                    inString = false
                }
                continue
            }
            switch char {
            case Char.quote:
                inString = true
            case Char.openBrace, Char.openBracket:
                stack.append(index)
            case Char.closeBrace, Char.closeBracket:
                if let open = stack.popLast() {
                    regions.append(JSONFoldRegion(openLocation: open, closeLocation: index, depth: stack.count))
                }
            default:
                break
            }
        }
        return regions
    }

    //MARK: - Recursive descent validator

    fileprivate enum Char {
        static let quote: UInt16 = 0x22
        static let backslash: UInt16 = 0x5C
        static let slash: UInt16 = 0x2F
        static let singleQuote: UInt16 = 0x27
        static let newline: UInt16 = 0x0A
        static let carriageReturn: UInt16 = 0x0D
        static let openBrace: UInt16 = 0x7B
        static let closeBrace: UInt16 = 0x7D
        static let openBracket: UInt16 = 0x5B
        static let closeBracket: UInt16 = 0x5D
        static let colon: UInt16 = 0x3A
        static let comma: UInt16 = 0x2C
        static let minus: UInt16 = 0x2D
        static let plus: UInt16 = 0x2B
        static let dot: UInt16 = 0x2E
        static let zero: UInt16 = 0x30
        static let nine: UInt16 = 0x39
    }

    fileprivate struct Parser {

        struct Failure: Error {
            let location: Int
            let message: String
        }

        let chars: [UInt16]
        var index = 0

        init(chars: [UInt16]) {
            self.chars = chars
        }

        mutating func parseDocument() throws {
            skipWhitespace()
            guard index < chars.count else {
                throw Failure(location: 0, message: "JSON is empty")
            }
            guard chars[index] == Char.openBrace || chars[index] == Char.openBracket else {
                throw Failure(location: index, message: "JSON must start with '{' or '['")
            }
            try parseValue()
            skipWhitespace()
            if index < chars.count {
                throw Failure(location: index, message: "Unexpected \(describe(index)) after the end of the JSON")
            }
        }

        mutating func parseValue() throws {
            skipWhitespace()
            guard index < chars.count else {
                throw Failure(location: chars.count, message: "Unexpected end of JSON, expected a value")
            }
            let char = chars[index]
            switch char {
            case Char.openBrace:
                try parseObject()
            case Char.openBracket:
                try parseArray()
            case Char.quote:
                try parseString()
            case Char.minus, Char.zero...Char.nine:
                try parseNumber()
            case UInt16(UInt8(ascii: "t")):
                try parseLiteral("true")
            case UInt16(UInt8(ascii: "f")):
                try parseLiteral("false")
            case UInt16(UInt8(ascii: "n")):
                try parseLiteral("null")
            case Char.singleQuote:
                throw Failure(location: index, message: "Strings must use double quotes")
            default:
                throw Failure(location: index, message: "Unexpected \(describe(index)), expected a value")
            }
        }

        mutating func parseObject() throws {
            let open = index
            index += 1
            skipWhitespace()
            if index < chars.count && chars[index] == Char.closeBrace {
                index += 1
                return
            }
            var lastComma: Int?
            while true {
                skipWhitespace()
                guard index < chars.count else {
                    throw Failure(location: open, message: "This '{' is never closed")
                }
                let char = chars[index]
                if char == Char.closeBrace, let comma = lastComma {
                    throw Failure(location: comma, message: "Trailing comma is not allowed")
                }
                guard char == Char.quote else {
                    let message = char == Char.singleQuote ? "Property names must use double quotes" : "Expected a property name in double quotes, found \(describe(index))"
                    throw Failure(location: index, message: message)
                }
                try parseString()
                skipWhitespace()
                guard index < chars.count, chars[index] == Char.colon else {
                    throw Failure(location: index, message: "Expected ':' after the property name, found \(describe(index))")
                }
                index += 1
                try parseValue()
                let valueEnd = index
                skipWhitespace()
                guard index < chars.count else {
                    throw Failure(location: open, message: "This '{' is never closed")
                }
                if chars[index] == Char.comma {
                    lastComma = index
                    index += 1
                } else if chars[index] == Char.closeBrace {
                    index += 1
                    return
                } else if startsValue(chars[index]) {
                    throw Failure(location: valueEnd, message: "Missing ',' after this value")
                } else {
                    throw Failure(location: index, message: "Expected ',' or '}', found \(describe(index))")
                }
            }
        }

        mutating func parseArray() throws {
            let open = index
            index += 1
            skipWhitespace()
            if index < chars.count && chars[index] == Char.closeBracket {
                index += 1
                return
            }
            var lastComma: Int?
            while true {
                skipWhitespace()
                guard index < chars.count else {
                    throw Failure(location: open, message: "This '[' is never closed")
                }
                if chars[index] == Char.closeBracket, let comma = lastComma {
                    throw Failure(location: comma, message: "Trailing comma is not allowed")
                }
                try parseValue()
                let valueEnd = index
                skipWhitespace()
                guard index < chars.count else {
                    throw Failure(location: open, message: "This '[' is never closed")
                }
                if chars[index] == Char.comma {
                    lastComma = index
                    index += 1
                } else if chars[index] == Char.closeBracket {
                    index += 1
                    return
                } else if startsValue(chars[index]) {
                    throw Failure(location: valueEnd, message: "Missing ',' after this value")
                } else {
                    throw Failure(location: index, message: "Expected ',' or ']', found \(describe(index))")
                }
            }
        }

        mutating func parseString() throws {
            let open = index
            index += 1
            while index < chars.count {
                let char = chars[index]
                if char == Char.quote {
                    index += 1
                    return
                }
                if char == Char.newline || char == Char.carriageReturn {
                    throw Failure(location: open, message: "Unterminated string, missing the closing '\"'")
                }
                if char == Char.backslash {
                    index += 1
                    guard index < chars.count else { break }
                    switch chars[index] {
                    case Char.quote, Char.backslash, Char.slash, UInt16(UInt8(ascii: "b")), UInt16(UInt8(ascii: "f")), UInt16(UInt8(ascii: "n")), UInt16(UInt8(ascii: "r")), UInt16(UInt8(ascii: "t")):
                        index += 1
                    case UInt16(UInt8(ascii: "u")):
                        let escapeStart = index - 1
                        index += 1
                        for _ in 0..<4 {
                            guard index < chars.count, isHexDigit(chars[index]) else {
                                throw Failure(location: escapeStart, message: "Invalid unicode escape, expected \\u followed by 4 hex digits")
                            }
                            index += 1
                        }
                    default:
                        throw Failure(location: index - 1, message: "Invalid escape sequence \\\(describeRaw(index))")
                    }
                    continue
                }
                index += 1
            }
            throw Failure(location: open, message: "Unterminated string, missing the closing '\"'")
        }

        mutating func parseNumber() throws {
            let start = index
            if chars[index] == Char.minus {
                index += 1
            }
            guard index < chars.count, isDigit(chars[index]) else {
                throw Failure(location: start, message: "Invalid number")
            }
            if chars[index] == Char.zero {
                index += 1
            } else {
                skipDigits()
            }
            if index < chars.count && chars[index] == Char.dot {
                index += 1
                guard index < chars.count, isDigit(chars[index]) else {
                    throw Failure(location: start, message: "Invalid number, expected digits after '.'")
                }
                skipDigits()
            }
            if index < chars.count && (chars[index] == UInt16(UInt8(ascii: "e")) || chars[index] == UInt16(UInt8(ascii: "E"))) {
                index += 1
                if index < chars.count && (chars[index] == Char.plus || chars[index] == Char.minus) {
                    index += 1
                }
                guard index < chars.count, isDigit(chars[index]) else {
                    throw Failure(location: start, message: "Invalid number, expected digits in the exponent")
                }
                skipDigits()
            }
            if index < chars.count && (isDigit(chars[index]) || isLetter(chars[index]) || chars[index] == Char.dot) {
                throw Failure(location: start, message: "Invalid number")
            }
        }

        mutating func parseLiteral(_ literal: String) throws {
            let start = index
            for expected in literal.utf16 {
                guard index < chars.count, chars[index] == expected else {
                    throw Failure(location: start, message: "Invalid value, did you mean '\(literal)'?")
                }
                index += 1
            }
            if index < chars.count && isLetter(chars[index]) {
                throw Failure(location: start, message: "Invalid value, did you mean '\(literal)'?")
            }
        }

        //MARK: Helpers

        mutating func skipWhitespace() {
            while index < chars.count && isIgnorable(chars[index]) {
                index += 1
            }
        }

        mutating func skipDigits() {
            while index < chars.count && isDigit(chars[index]) {
                index += 1
            }
        }

        //JSON whitespace plus the control characters stripped by stringByRemovingControlCharacters
        func isIgnorable(_ char: UInt16) -> Bool {
            return char <= 0x20 || (char >= 0x7F && char <= 0x9F) || (char >= 0x200B && char <= 0x200F) || char == 0xFEFF
        }

        func isDigit(_ char: UInt16) -> Bool {
            return char >= Char.zero && char <= Char.nine
        }

        func isLetter(_ char: UInt16) -> Bool {
            return (char >= 0x41 && char <= 0x5A) || (char >= 0x61 && char <= 0x7A) || char == 0x5F
        }

        func isHexDigit(_ char: UInt16) -> Bool {
            return isDigit(char) || (char >= 0x41 && char <= 0x46) || (char >= 0x61 && char <= 0x66)
        }

        func startsValue(_ char: UInt16) -> Bool {
            return char == Char.quote || char == Char.openBrace || char == Char.openBracket || char == Char.minus || isDigit(char)
                || char == UInt16(UInt8(ascii: "t")) || char == UInt16(UInt8(ascii: "f")) || char == UInt16(UInt8(ascii: "n"))
        }

        func describeRaw(_ location: Int) -> String {
            guard location < chars.count else { return "" }
            return String(utf16CodeUnits: [chars[location]], count: 1)
        }

        func describe(_ location: Int) -> String {
            guard location < chars.count else { return "end of JSON" }
            let char = chars[location]
            if char == Char.newline || char == Char.carriageReturn {
                return "a line break"
            }
            return "'\(describeRaw(location))'"
        }
    }
}
