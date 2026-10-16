import Foundation

/// JSON that keeps object key order and number spelling, so editing the user's
/// settings.json changes only what we mean to change.
public indirect enum OrderedJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    /// The number exactly as written in the source.
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([(key: String, value: OrderedJSON)])

    public static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case (.bool(let x), .bool(let y)): x == y
        case (.number(let x), .number(let y)): x == y
        case (.string(let x), .string(let y)): x == y
        case (.array(let x), .array(let y)): x == y
        case (.object(let x), .object(let y)):
            x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    /// Last value for `key`, matching JSON.parse's handling of duplicate keys.
    public subscript(key: String) -> OrderedJSON? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.last(where: { $0.key == key })?.value
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Sets (replacing the last occurrence, or appending) or removes (`nil`) a key.
    public mutating func set(_ key: String, _ value: OrderedJSON?) {
        guard case .object(var pairs) = self else { return }
        if let i = pairs.lastIndex(where: { $0.key == key }) {
            if let value { pairs[i].value = value } else { pairs.removeAll { $0.key == key } }
        } else if let value {
            pairs.append((key, value))
        }
        self = .object(pairs)
    }
}

// MARK: - Parsing

public struct JSONSyntaxError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "\(message) at byte \(offset)" }
}

extension OrderedJSON {
    public static let maxDepth = 256

    public static func parse(_ text: String) throws -> OrderedJSON {
        var p = Parser(bytes: Array(text.utf8))
        p.skipWhitespace()
        let value = try p.value(depth: 0)
        p.skipWhitespace()
        guard p.i == p.bytes.count else { throw p.error("Unexpected content after the JSON value") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        func error(_ m: String) -> JSONSyntaxError { JSONSyntaxError(message: m, offset: i) }

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func expect(_ literal: String) throws {
            let l = Array(literal.utf8)
            guard i + l.count <= bytes.count, Array(bytes[i..<(i + l.count)]) == l else { throw error("Expected \(literal)") }
            i += l.count
        }

        mutating func value(depth: Int) throws -> OrderedJSON {
            guard depth < OrderedJSON.maxDepth else { throw error("Nested too deeply") }
            guard i < bytes.count else { throw error("Unexpected end of file") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func object(depth: Int) throws -> OrderedJSON {
            i += 1
            var pairs: [(key: String, value: OrderedJSON)] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("Expected a key") }
                let key = try string()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                pairs.append((key, try value(depth: depth + 1)))
                skipWhitespace()
                guard i < bytes.count else { throw error("Unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                throw error("Expected , or }")
            }
        }

        mutating func array(depth: Int) throws -> OrderedJSON {
            i += 1
            var items: [OrderedJSON] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                guard i < bytes.count else { throw error("Unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw error("Expected , or ]")
            }
        }

        mutating func string() throws -> String {
            i += 1
            var out = [UInt8]()
            while true {
                guard i < bytes.count else { throw error("Unterminated string") }
                let c = bytes[i]
                if c == UInt8(ascii: "\"") { i += 1; break }
                if c < 0x20 { throw error("Control character in string") }
                if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
                i += 1
                guard i < bytes.count else { throw error("Unterminated escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        // Surrogate pair.
                        guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else {
                            throw error("Unpaired surrogate")
                        }
                        i += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw error("Invalid surrogate pair") }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        throw error("Unpaired surrogate")
                    }
                    guard let u = Unicode.Scalar(scalar) else { throw error("Invalid code point") }
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                default:
                    throw error("Invalid escape")
                }
            }
            guard let s = String(bytes: out, encoding: .utf8) else { throw error("Invalid UTF-8") }
            return s
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let s = String(bytes: bytes[i..<(i + 4)], encoding: .ascii),
                  s.allSatisfy(\.isHexDigit), let v = UInt32(s, radix: 16)
            else { throw error("Invalid \\u escape") }
            i += 4
            return v
        }

        mutating func number() throws -> String {
            let start = i
            func digits() -> Int {
                let s = i
                while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
                return i - s
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard i < bytes.count else { throw error("Invalid value") }
            if bytes[i] == UInt8(ascii: "0") {
                i += 1
            } else if digits() == 0 {
                throw error("Invalid value")
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                guard digits() > 0 else { throw error("Invalid number") }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard digits() > 0 else { throw error("Invalid number") }
            }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }
    }
}

// MARK: - Printing

extension OrderedJSON {
    /// Same layout as JavaScript's `JSON.stringify(value, null, 2)`, which is how
    /// Claude Code writes its settings files.
    public func formatted() -> String {
        var out = ""
        write(into: &out, indent: 0)
        return out
    }

    private func write(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent + 1)
        let closePad = String(repeating: "  ", count: indent)
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): Self.quote(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (n, item) in items.enumerated() {
                out += pad
                item.write(into: &out, indent: indent + 1)
                out += n == items.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "]"
        case .object(let pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{\n"
            for (n, pair) in pairs.enumerated() {
                out += pad
                Self.quote(pair.key, into: &out)
                out += ": "
                pair.value.write(into: &out, indent: indent + 1)
                out += n == pairs.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "}"
        }
    }

    private static func quote(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}
