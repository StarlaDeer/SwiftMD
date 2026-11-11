// SwiftMD - port of netmd-js src/query-utils.ts
// Original: Copyright (C) Stefano Brilli, Asivery (https://github.com/cybercase/netmd-js)
// Licensed under the GNU General Public License v2.0.

import Foundation

/// A value passed to `formatQuery` or produced by `scanQuery`.
public enum QueryValue: Equatable, Sendable, ExpressibleByIntegerLiteral {
    case int(UInt64)
    case bytes([UInt8])

    public init(integerLiteral value: UInt64) { self = .int(value) }
    public init<T: BinaryInteger>(_ value: T) { self = .int(UInt64(truncatingIfNeeded: value)) }

    public var int: Int {
        guard case .int(let v) = self else { preconditionFailure("Expected integer query value, got \(self)") }
        return Int(truncatingIfNeeded: v)
    }

    public var bytes: [UInt8] {
        guard case .bytes(let b) = self else { preconditionFailure("Expected byte query value, got \(self)") }
        return b
    }
}

public enum QueryError: Error, Equatable, CustomStringConvertible {
    case mismatch(index: Int, expected: UInt8, got: UInt8?, format: String)
    case trailingBytes(Int)
    case truncated(format: String)
    case badFormat(String)

    public var description: String {
        switch self {
        case let .mismatch(index, expected, got, format):
            let gotText = got.map { String($0) } ?? "end of data"
            return "Format and input mismatch at \(index): expected \(expected), got \(gotText) (format \(format))"
        case .trailingBytes(let n): return "\(n) Bytes remaining to parse"
        case .truncated(let format): return "Reply too short for format \(format)"
        case .badFormat(let msg): return msg
        }
    }
}

private let formatTypeLength: [Character: Int] = ["b": 1, "w": 2, "d": 4, "q": 8]

/*
    %b, w, d, q - byte, word, doubleword, quadword (big endian; '<' or '>' overrides, e.g. %<d)
    %s - bytes preceded by 2 bytes of length, with a trailing NUL counted in the length
    %x - bytes preceded by 2 bytes of length
    %z - bytes preceded by 1 byte of length
    %* - raw bytes
    %B - BCD-encoded 1-byte number
    %W - BCD-encoded 2-byte number
*/
public func formatQuery(_ format: String, _ args: QueryValue...) throws -> [UInt8] {
    var result: [UInt8] = []
    var half: Character?
    var littleEndian: Bool?
    var argStack = args[...]
    var escaped = false

    for char in format {
        if escaped {
            if littleEndian == nil, char == "<" || char == ">" {
                littleEndian = char == "<"
                continue
            }
            escaped = false
            guard let value = argStack.popFirst() else {
                throw QueryError.badFormat("Missing argument for %\(char) in \(format)")
            }
            if let len = formatTypeLength[char] {
                guard case .int(let number) = value else { throw QueryError.badFormat("Expected integer for %\(char)") }
                for byte in stride(from: len - 1, through: 0, by: -1) {
                    let b = littleEndian == true ? len - 1 - byte : byte
                    result.append(UInt8(truncatingIfNeeded: number >> UInt64(b * 8)))
                }
                littleEndian = nil
            } else if char == "x" || char == "s" || char == "z" {
                guard case .bytes(let data) = value else { throw QueryError.badFormat("Expected bytes for %\(char)") }
                var length = data.count
                if char == "s" { length += 1 }
                if char != "z" { result.append(UInt8((length >> 8) & 0xff)) }
                result.append(UInt8(length & 0xff))
                result.append(contentsOf: data)
                if char == "s" { result.append(0) }
            } else if char == "*" {
                guard case .bytes(let data) = value else { throw QueryError.badFormat("Expected bytes for %*") }
                result.append(contentsOf: data)
            } else if char == "B" || char == "W" {
                let converted = try int2BCD(value.int, length: char == "W" ? 2 : 1)
                if char == "W" { result.append(UInt8((converted >> 8) & 0xff)) }
                result.append(UInt8(converted & 0xff))
            } else {
                throw QueryError.badFormat("Unrecognized format char \(char)")
            }
            continue
        }
        if char == "%" {
            guard half == nil else { throw QueryError.badFormat("Expected \"half\" to be null") }
            escaped = true
            continue
        }
        if char == " " { continue }
        if let h = half {
            guard let byte = UInt8(String([h, char]), radix: 16) else {
                throw QueryError.badFormat("Bad hex \(h)\(char) in \(format)")
            }
            result.append(byte)
            half = nil
        } else {
            half = char
        }
    }
    return result
}

public func scanQuery(_ query: [UInt8], _ format: String) throws -> [QueryValue] {
    var result: [QueryValue] = []
    var input = query[...]
    var half: Character?
    var littleEndian: Bool?
    var escaped = false

    func take() throws -> UInt8 {
        guard let b = input.popFirst() else { throw QueryError.truncated(format: format) }
        return b
    }

    func takeBytes(_ n: Int) throws -> [UInt8] {
        guard input.count >= n else { throw QueryError.truncated(format: format) }
        let out = Array(input.prefix(n))
        input = input.dropFirst(n)
        return out
    }

    for char in format {
        if escaped {
            if littleEndian == nil, char == "<" || char == ">" {
                littleEndian = char == "<"
                continue
            }
            escaped = false
            if char == "?" {
                // Like netmd-js, a skipped byte may be absent (some devices send shorter replies).
                _ = input.popFirst()
                continue
            }
            if let len = formatTypeLength[char] {
                var value: UInt64 = 0
                for byte in stride(from: len - 1, through: 0, by: -1) {
                    let b = littleEndian == true ? len - 1 - byte : byte
                    value |= UInt64(try take()) << UInt64(b * 8)
                }
                littleEndian = nil
                result.append(.int(value))
            } else if char == "s" || char == "x" || char == "z" {
                let length = char == "z" ? Int(try take()) : (Int(try take()) << 8) | Int(try take())
                result.append(.bytes(try takeBytes(length)))
            } else if char == "*" || char == "#" {
                result.append(.bytes(Array(input)))
                input = input.dropFirst(input.count)
            } else if char == "B" {
                result.append(.int(UInt64(bcd2Int(Int(try take())))))
            } else if char == "W" {
                let v = (Int(try take()) << 8) | Int(try take())
                result.append(.int(UInt64(bcd2Int(v))))
            } else {
                throw QueryError.badFormat("Unrecognized format char \(char)")
            }
            continue
        }
        if char == "%" {
            guard half == nil else { throw QueryError.badFormat("Expected \"half\" to be null") }
            escaped = true
            continue
        }
        if char == " " { continue }
        if let h = half {
            guard let expected = UInt8(String([h, char]), radix: 16) else {
                throw QueryError.badFormat("Bad hex \(h)\(char) in \(format)")
            }
            let index = query.count - input.count
            let got = input.popFirst()
            if got != expected {
                throw QueryError.mismatch(index: index, expected: expected, got: got, format: format)
            }
            half = nil
        } else {
            half = char
        }
    }
    guard input.isEmpty else { throw QueryError.trailingBytes(input.count) }
    return result
}

public func bcd2Int(_ bcd: Int) -> Int {
    var bcd = bcd
    var value = 0
    var multiplier = 1
    while bcd != 0 {
        value += (bcd & 0xf) * multiplier
        bcd >>= 4
        multiplier *= 10
    }
    return value
}

public func int2BCD(_ value: Int, length: Int = 1) throws -> Int {
    guard length <= 4 else { throw QueryError.badFormat("Unsupported length. Max allowed is 4") }
    var limit = 1
    for _ in 0..<(length * 2) { limit *= 10 }
    guard value >= 0, value < limit else {
        throw QueryError.badFormat("Value \(value) cannot fit in \(length) bytes in BCD")
    }
    var value = value
    var bcd = 0
    var nibble = 0
    while value != 0 {
        bcd |= (value % 10) << (4 * nibble)
        value /= 10
        nibble += 1
    }
    return bcd
}
