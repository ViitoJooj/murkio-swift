import Foundation

/// A JSON value. Numbers are always `Double`.
///
/// The SDK reads JSON with its own small parser instead of
/// `JSONSerialization`: that one bridges numbers and booleans differently on
/// Apple platforms and on Linux, and the canvas validation must behave on a
/// phone exactly as it does where the tests run.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The member of an object, or nil (also when this is not an object).
    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var isNull: Bool { self == .null }

    /// The strings of an array, skipping anything else.
    var strings: [String] { (array ?? []).compactMap { $0.string } }

    /// Parses JSON text. Nil when it is not JSON.
    public static func parse(_ text: String) -> JSONValue? {
        var parser = JSONParser(bytes: Array(text.utf8))
        return try? parser.document()
    }

    /// JSON text, with object keys sorted so the output is always the same.
    public func write() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .number(let value):
            if !value.isFinite {
                out += "null"
            } else if value == value.rounded(), abs(value) < 1e15 {
                out += String(Int64(value))
            } else {
                out += String(value)
            }
        case .string(let value):
            JSONValue.write(string: value, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                JSONValue.write(string: key, into: &out)
                out += ":"
                members[key]?.write(into: &out)
            }
            out += "}"
        }
    }

    private static func write(string: String, into out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0..<0x20, 0x2028, 0x2029:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

// No nil literal on purpose: `nil` must keep meaning "no value" wherever a
// `JSONValue?` is expected, never a JSON null.
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

private struct JSONError: Error {}

private struct JSONParser {
    let bytes: [UInt8]
    var at = 0
    static let maxDepth = 64

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func document() throws -> JSONValue {
        skipSpace()
        let value = try self.value(depth: 0)
        skipSpace()
        guard at == bytes.count else { throw JSONError() }
        return value
    }

    private mutating func skipSpace() {
        while at < bytes.count, bytes[at] == 0x20 || bytes[at] == 0x0A || bytes[at] == 0x0D || bytes[at] == 0x09 {
            at += 1
        }
    }

    private func peek() throws -> UInt8 {
        guard at < bytes.count else { throw JSONError() }
        return bytes[at]
    }

    private mutating func value(depth: Int) throws -> JSONValue {
        guard depth <= JSONParser.maxDepth else { throw JSONError() }
        switch try peek() {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["): return try array(depth: depth)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): return try literal("true", .bool(true))
        case UInt8(ascii: "f"): return try literal("false", .bool(false))
        case UInt8(ascii: "n"): return try literal("null", .null)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
        default: throw JSONError()
        }
    }

    private mutating func literal(_ word: String, _ value: JSONValue) throws -> JSONValue {
        let expected = Array(word.utf8)
        guard at + expected.count <= bytes.count, Array(bytes[at..<(at + expected.count)]) == expected else {
            throw JSONError()
        }
        at += expected.count
        return value
    }

    private mutating func object(depth: Int) throws -> JSONValue {
        var members: [String: JSONValue] = [:]
        at += 1
        skipSpace()
        if try peek() == UInt8(ascii: "}") {
            at += 1
            return .object(members)
        }
        while true {
            skipSpace()
            guard try peek() == UInt8(ascii: "\"") else { throw JSONError() }
            let key = try string()
            skipSpace()
            guard try peek() == UInt8(ascii: ":") else { throw JSONError() }
            at += 1
            skipSpace()
            members[key] = try value(depth: depth + 1)
            skipSpace()
            switch try peek() {
            case UInt8(ascii: ","): at += 1
            case UInt8(ascii: "}"):
                at += 1
                return .object(members)
            default: throw JSONError()
            }
        }
    }

    private mutating func array(depth: Int) throws -> JSONValue {
        var items: [JSONValue] = []
        at += 1
        skipSpace()
        if try peek() == UInt8(ascii: "]") {
            at += 1
            return .array(items)
        }
        while true {
            skipSpace()
            items.append(try value(depth: depth + 1))
            skipSpace()
            switch try peek() {
            case UInt8(ascii: ","): at += 1
            case UInt8(ascii: "]"):
                at += 1
                return .array(items)
            default: throw JSONError()
            }
        }
    }

    private mutating func hex4() throws -> UInt32 {
        guard at + 4 <= bytes.count else { throw JSONError() }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[at]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A")) + 10
            default: throw JSONError()
            }
            value = value * 16 + digit
            at += 1
        }
        return value
    }

    private mutating func string() throws -> String {
        var out: [UInt8] = []
        at += 1
        while true {
            guard at < bytes.count else { throw JSONError() }
            let byte = bytes[at]
            at += 1
            if byte == UInt8(ascii: "\"") { break }
            if byte < 0x20 { throw JSONError() }
            if byte != UInt8(ascii: "\\") {
                out.append(byte)
                continue
            }
            guard at < bytes.count else { throw JSONError() }
            let escape = bytes[at]
            at += 1
            switch escape {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escape)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var code = try hex4()
                if (0xD800...0xDBFF).contains(code), at + 1 < bytes.count, bytes[at] == UInt8(ascii: "\\"),
                   bytes[at + 1] == UInt8(ascii: "u") {
                    let saved = at
                    at += 2
                    let low = try hex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        at = saved
                    }
                }
                // A surrogate on its own is not a character: it becomes the replacement one.
                let scalar = Unicode.Scalar(code) ?? Unicode.Scalar(0xFFFD)!
                out.append(contentsOf: Array(String(scalar).utf8))
            default: throw JSONError()
            }
        }
        // The bytes came from a Swift string or from scalars encoded above, so they are valid UTF-8.
        return String(decoding: out, as: UTF8.self)
    }

    private mutating func digits() {
        while at < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[at]) { at += 1 }
    }

    private mutating func number() throws -> Double {
        let start = at
        if bytes[at] == UInt8(ascii: "-") { at += 1 }
        guard at < bytes.count else { throw JSONError() }
        if bytes[at] == UInt8(ascii: "0") {
            at += 1
        } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(bytes[at]) {
            digits()
        } else {
            throw JSONError()
        }
        if at < bytes.count, bytes[at] == UInt8(ascii: ".") {
            at += 1
            guard at < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[at]) else { throw JSONError() }
            digits()
        }
        if at < bytes.count, bytes[at] == UInt8(ascii: "e") || bytes[at] == UInt8(ascii: "E") {
            at += 1
            if at < bytes.count, bytes[at] == UInt8(ascii: "+") || bytes[at] == UInt8(ascii: "-") { at += 1 }
            guard at < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[at]) else { throw JSONError() }
            digits()
        }
        guard let value = Double(String(decoding: bytes[start..<at], as: UTF8.self)) else { throw JSONError() }
        return value
    }
}
