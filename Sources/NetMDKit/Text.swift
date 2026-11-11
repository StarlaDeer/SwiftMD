// SwiftMD - port of the text helpers in netmd-js src/utils.ts
// Original: Copyright (C) Stefano Brilli, Asivery (https://github.com/cybercase/netmd-js)
// Licensed under the GNU General Public License v2.0.

import Foundation

/// NetMD titles are stored as Shift-JIS.
public func encodeToSJIS(_ string: String) -> [UInt8] {
    Array(string.data(using: .shiftJIS, allowLossyConversion: true) ?? Data())
}

public func decodeFromSJIS(_ bytes: [UInt8]) -> String {
    let data = Data(bytes)
    // Fall back to Latin-1 so a malformed title never makes the whole disc unreadable.
    return String(data: data, encoding: .shiftJIS) ?? String(data: data, encoding: .isoLatin1) ?? ""
}

public func halfWidthToFullWidthRange(_ range: String) -> String {
    let mappings: [Character: Character] = [
        "0": "０", "1": "１", "2": "２", "3": "３", "4": "４",
        "5": "５", "6": "６", "7": "７", "8": "８", "9": "９",
        "-": "－", "/": "／", ";": "；",
    ]
    return String(range.compactMap { mappings[$0] })
}

/// MiniDisc time is counted in sound groups: 512 per second.
public let framesPerSecond = 512

public func timeToFrames(_ time: [Int]) -> Int {
    precondition(time.count == 4)
    return ((time[0] * 60 + time[1]) * 60 + time[2]) * framesPerSecond + time[3]
}

public func formatTimeFromFrames(_ value: Int, frames: Bool = true) -> String {
    let f = value % framesPerSecond
    var rest = value / framesPerSecond
    let s = rest % 60
    rest /= 60
    let m = rest % 60
    let h = rest / 60
    let base = String(format: "%02d:%02d:%02d", h, m, s)
    return frames ? base + String(format: "+%03d", f) : base
}

// MARK: - Title sanitizing
// Titles are processed one UTF-16 unit at a time, as in netmd-js. All the characters
// involved are in the BMP, so Unicode scalars give the same result.

/// Length of a half-width title in bytes once written. Kana with (han)dakuten take two.
public func getHalfWidthTitleLength(_ title: String) -> Int {
    title.utf16.count + title.unicodeScalars.filter { halfWidthMultiByteChars.contains($0) }.count
}

/// Strips anything that isn't plain ASCII. The last resort when a title can't be mapped safely.
public func aggressiveSanitizeTitle(_ title: String) -> String {
    let stripped = removeDiacritics(title).decomposedStringWithCanonicalMapping
    return String(String.UnicodeScalarView(stripped.unicodeScalars.filter { $0.value < 0x80 }))
}

func removeDiacritics(_ text: String) -> String {
    text.folding(options: .diacriticInsensitive, locale: nil)
}

private func remap(_ s: String, _ table: [Unicode.Scalar: String]) -> String {
    guard s.unicodeScalars.count == 1, let mapped = table[s.unicodeScalars.first!] else { return s }
    return mapped
}

public func sanitizeFullWidthTitle(_ title: String, justRemap: Bool = false) -> String {
    var newTitle = ""
    for scalar in title.unicodeScalars {
        var s = String(scalar)
        s = remap(s, fullWidthMappingsJP)
        s = remap(s, fullWidthMappingsRU)
        s = remap(s, fullWidthMappingsDE)
        newTitle += s
    }
    if justRemap { return newTitle }

    let sjisEncoded = encodeToSJIS(newTitle)
    // Every character in a full-width title is 2 bytes; anything else can't be written safely.
    if sjisEncoded.count != title.utf16.count * 2 { return aggressiveSanitizeTitle(title) }
    return decodeFromSJIS(sjisEncoded)
}

private let handakutenPossible = Set("はひふへほハヒフヘホ".unicodeScalars)
private let dakutenPossible = Set("かきくけこさしすせそたちつてとカキクケコサシスセソタチツテト".unicodeScalars).union(handakutenPossible)
private let allowedHalfWidthKana = Set(halfWidthMappings.values)

public func sanitizeHalfWidthTitle(_ title: String) -> String {
    enum CharType { case normal, dakuten, handakuten }

    // 'Flatten' all the characters followed by the (han)dakuten character into one.
    // This only works for full-width kana. They're converted to half-width below anyway.
    var dakutenFix: [Unicode.Scalar] = []
    var type = CharType.normal
    for char in sanitizeFullWidthTitle(title, justRemap: true).unicodeScalars.reversed() {
        if type == .dakuten, dakutenPossible.contains(char) {
            dakutenFix.append(Unicode.Scalar(char.value + 1)!)
            type = .normal
            continue
        }
        if type == .dakuten || type == .handakuten, handakutenPossible.contains(char) {
            dakutenFix.append(Unicode.Scalar(char.value + 2)!)
            type = .normal
            continue
        }
        switch char {
        case "\u{309B}", "\u{3099}", "\u{FF9E}":
            type = .dakuten
        case "\u{309C}", "\u{309A}", "\u{FF9F}":
            type = .handakuten
        default:
            type = .normal
            dakutenFix.append(char)
        }
    }
    let fixedTitle = String(String.UnicodeScalarView(dakutenFix.reversed()))

    func check(_ n: String) -> String? {
        if let first = n.unicodeScalars.first, n.unicodeScalars.count == 1, let mapped = halfWidthMappings[first] {
            return mapped
        }
        if let first = n.unicodeScalars.first, first.value < 0x7f { return n }
        if allowedHalfWidthKana.contains(n) { return n }
        return nil
    }

    var newTitle = ""
    for scalar in fixedTitle.unicodeScalars {
        let c = String(scalar)
        newTitle += check(c) ?? check(removeDiacritics(c)) ?? " "
    }
    // The encoded length must match the expected length (accounting for dakuten),
    // otherwise the disc's title area might end up corrupted.
    if encodeToSJIS(newTitle).count != getHalfWidthTitleLength(fixedTitle) {
        return aggressiveSanitizeTitle(fixedTitle)
    }
    return newTitle
}
