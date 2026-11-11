// The disc's User TOC: track fragments, titles, timestamps. Port of netmd-tocmanip (GPL-2.0, by
// asivery): toc.ts (parseTOC, reconstructTOC), toc-functions.ts and signatures.ts.
//
// UTOC sectors are read and written through the factory command set (readUTOCSector /
// writeUTOCSector). Writing changes the recorder's in-memory copy; ForceTOCEdit (TOCWrite.swift)
// or ejecting the disc saves it to the disc.

import Foundation

public enum TOCModeFlag {
    public static let emphasis = 0x1
    public static let stereo = 0x2
    public static let spMode = 0x4
    public static let codecModeReserved = 0x8
    public static let audio = 0x10 // Negated: audio = 0
    public static let scmsDigitalCopy = 0x20
    public static let scmsUnrestricted = 0x40
    public static let writable = 0x80
}

extension DiscAddress {
    public init(cluster: Int, sector: Int, group: Int) {
        self.cluster = cluster
        self.sector = sector
        self.group = group
    }

    public init(logical: Int) {
        self.init(cluster: logical / 32, sector: logical % 32, group: 0)
    }

    var bytes: [UInt8] {
        [UInt8(truncatingIfNeeded: cluster >> 6),
         UInt8(truncatingIfNeeded: ((cluster & 0x3f) << 2) | ((sector & 0x30) >> 4)),
         UInt8(truncatingIfNeeded: ((sector & 0x0f) << 4) | group)]
    }
}

public struct TOCFragment: Sendable, Equatable {
    public var start: DiscAddress
    public var mode: Int
    public var end: DiscAddress
    public var link: Int

    public var isValid: Bool {
        start.cluster != 0 || start.sector != 0 || start.group != 0 || end.cluster != 0 || end.sector != 0 || end.group != 0
    }
}

public struct TOCTitleCell: Sendable, Equatable {
    public var title: [UInt8] // 7 bytes
    public var link: Int
}

public struct TOCTimestamp: Sendable, Equatable {
    public var year, month, day, hour, minute, second: Int
    /// The recorder that wrote it (see `TableOfContents.signatures`).
    public var signature: Int
}

/// All four UTOC sectors, or the ones given. Round-trips byte for byte through `sectors()`.
public struct TableOfContents: Sendable, Equatable {
    public var sectorsGiven: [Int] = []

    // Sector 0
    public var sec0Padding: [UInt8] = []
    public var deviceSignature = 0
    public var discNonEmpty = 0
    public var trackCount = 0
    public var sec0aPadding: [UInt8] = []
    public var nextFreeTrackSlot = 0
    public var trackMap: [Int] = []
    public var trackFragments: [TOCFragment] = []

    // Sector 1
    public var sec1Padding: [UInt8] = []
    public var nextFreeTitleSlot = 0
    public var titleMap: [Int] = []
    public var titleCells: [TOCTitleCell] = []

    // Sector 2
    public var sec2Padding: [UInt8] = []
    public var nextFreeTimestampSlot = 0
    public var timestampMap: [Int] = []
    public var timestamps: [TOCTimestamp] = []

    // Sector 3
    public var sec3Padding: [UInt8] = []
    public var nextFreeFullWidthTitleSlot = 0
    public var fullWidthTitleMap: [Int] = []
    public var fullWidthTitleCells: [TOCTitleCell] = []

    /// The signature netmd-tocmanip writes when it changes a TOC.
    public static let ownSignature = 0x8ca2

    /// Parses UTOC sectors 0...3; pass nil for sectors you don't have. Port of parseTOC.
    public init(sectors: [[UInt8]?]) {
        for (i, sector) in sectors.prefix(4).enumerated() {
            guard let raw = sector else { continue }
            sectorsGiven.append(i)
            var offset = 0
            func byte() -> Int { defer { offset += 1 }; return offset < raw.count ? Int(raw[offset]) : 0 }
            func short() -> Int { (byte() << 8) | byte() }
            func multiple(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8(byte()) } }
            func address() -> DiscAddress { DiscAddress(multiple(3)[...]) }
            func fragment() -> TOCFragment { TOCFragment(start: address(), mode: byte(), end: address(), link: byte()) }
            func titleCell() -> TOCTitleCell { TOCTitleCell(title: multiple(7), link: byte()) }
            func timestamp() -> TOCTimestamp {
                TOCTimestamp(year: byte(), month: byte(), day: byte(), hour: byte(), minute: byte(), second: byte(), signature: short())
            }
            switch i {
            case 0:
                sec0Padding = multiple(0x1c)
                deviceSignature = short()
                discNonEmpty = byte()
                trackCount = byte()
                sec0aPadding = multiple(0x0f)
                nextFreeTrackSlot = byte()
                trackMap = (0..<256).map { _ in byte() }
                trackFragments = (0..<256).map { _ in fragment() }
            case 1:
                sec1Padding = multiple(0x2f)
                nextFreeTitleSlot = byte()
                titleMap = (0..<256).map { _ in byte() }
                titleCells = (0..<256).map { _ in titleCell() }
            case 2:
                sec2Padding = multiple(0x2f)
                nextFreeTimestampSlot = byte()
                timestampMap = (0..<256).map { _ in byte() }
                timestamps = (0..<256).map { _ in timestamp() }
            default:
                sec3Padding = multiple(0x2f)
                nextFreeFullWidthTitleSlot = byte()
                fullWidthTitleMap = (0..<256).map { _ in byte() }
                fullWidthTitleCells = (0..<256).map { _ in titleCell() }
            }
        }
    }

    /// Rebuilds the sectors (nil for ones not given). Port of reconstructTOC; by default it marks
    /// the TOC as written by netmd-tocmanip, as the original does.
    public func sectors(updateSignature: Bool = true) -> [[UInt8]?] {
        var out: [[UInt8]?] = []
        func u8(_ n: Int) -> UInt8 { UInt8(truncatingIfNeeded: n) }
        func fragment(_ f: TOCFragment) -> [UInt8] { f.start.bytes + [u8(f.mode)] + f.end.bytes + [u8(f.link)] }
        func cell(_ c: TOCTitleCell) -> [UInt8] { c.title + [u8(c.link)] }
        func stamp(_ t: TOCTimestamp) -> [UInt8] {
            [u8(t.year), u8(t.month), u8(t.day), u8(t.hour), u8(t.minute), u8(t.second), u8(t.signature >> 8), u8(t.signature)]
        }
        for i in 0..<4 {
            guard sectorsGiven.contains(i) else { out.append(nil); continue }
            var s: [UInt8] = []
            switch i {
            case 0:
                let signature = updateSignature ? Self.ownSignature : deviceSignature
                s += sec0Padding + [u8(signature >> 8), u8(signature), u8(discNonEmpty), u8(trackCount)]
                s += sec0aPadding + [u8(nextFreeTrackSlot)] + trackMap.map(u8)
                s += trackFragments.flatMap(fragment)
            case 1:
                s += sec1Padding + [u8(nextFreeTitleSlot)] + titleMap.map(u8) + titleCells.flatMap(cell)
            case 2:
                s += sec2Padding + [u8(nextFreeTimestampSlot)] + timestampMap.map(u8) + timestamps.flatMap(stamp)
            default:
                s += sec3Padding + [u8(nextFreeFullWidthTitleSlot)] + fullWidthTitleMap.map(u8) + fullWidthTitleCells.flatMap(cell)
            }
            out.append(s)
        }
        return out
    }

    // MARK: toc-functions.ts

    /// Port of getTitleByCellIndex.
    public func title(cellIndex index: Int, fullWidth: Bool = false, forceZeroFirst: Bool = false) -> String {
        let cells = fullWidth ? fullWidthTitleCells : titleCells
        var cell = index
        var depth = 0
        var forceZero = forceZeroFirst
        var flat: [UInt8] = []
        while cell != 0 || forceZero {
            if depth > 10 { flat += Array("...".utf8); break }
            flat += cells[cell].title
            cell = cells[cell].link
            depth += 1
            forceZero = false
        }
        if let zero = flat.firstIndex(of: 0) { flat = Array(flat[..<zero]) }
        return fullWidth ? decodeFromSJIS(flat) : String(decoding: flat, as: UTF8.self)
    }

    /// Port of getTitleByTrackNumber. Track 0 is the disc title; tracks start at 1.
    public func title(track index: Int, fullWidth: Bool = false) -> String {
        title(cellIndex: fullWidth ? fullWidthTitleMap[index] : titleMap[index], fullWidth: fullWidth)
    }

    /// The fragments of a track (1-based), in play order.
    public func fragments(track index: Int) -> [TOCFragment] {
        var result: [TOCFragment] = []
        var fragment = trackFragments[trackMap[index]]
        result.append(fragment)
        var guardCount = 0
        while fragment.link != 0 && guardCount < 256 {
            fragment = trackFragments[fragment.link]
            result.append(fragment)
            guardCount += 1
        }
        return result
    }

    public struct TrackInfo: Sendable {
        public var title: String?
        public var timestamp: TOCTimestamp?
        public var fragments: [TOCFragment]
        /// The recorder that wrote the track, from its timestamp signature.
        public var writtenBy: String?
    }

    /// Port of getTrackInfo (1-based track).
    public func trackInfo(_ index: Int) -> TrackInfo {
        let title = sectorsGiven.contains(1) ? self.title(track: index) : nil
        let timestamp = sectorsGiven.contains(2) ? timestamps[timestampMap[index]] : nil
        return TrackInfo(
            title: title,
            timestamp: timestamp,
            fragments: fragments(track: index),
            writtenBy: timestamp.map { Self.signatures[$0.signature] ?? "UNKNOWN" }
        )
    }

    /// Port of updateFlagAllFragmentsOfTrack.
    public mutating func setFlag(_ flag: Int, _ set: Bool, track index: Int) {
        var slot = trackMap[index]
        var guardCount = 0
        while true {
            if set { trackFragments[slot].mode |= flag } else { trackFragments[slot].mode &= ~flag }
            let link = trackFragments[slot].link
            if link == 0 || guardCount >= 256 { break }
            slot = link
            guardCount += 1
        }
    }

    /// Port of swapTrack.
    public mutating func swapTracks(_ a: Int, _ b: Int) {
        trackMap.swapAt(a, b)
        titleMap.swapAt(a, b)
        timestampMap.swapAt(a, b)
    }

    // MARK: signatures.ts

    public static let signatures: [Int: String] = [
        0x120: "Sony MZ-N505/MZ-N707/MZ-N1/MZ-S1/MZ-R910",
        0x121: "Sony MZ-N510/MZ-N520/MZ-NE410/MZ-N910/MZ-N920/MZ-N710/MZ-N10 / Aiwa AM-NX9",
        0x124: "Sony MZ-R3 / Sony MZ-RH10",
        0x122: "Sony MZ-NH1/MZ-NH700/MZ-NH900",
        0x125: "Sony MZ-RH1",
        0x126: "Sony MZ-R30",
        0x127: "Sony MZ-R50",
        0x129: "Sony MZ-R55",
        0x12B: "Sony MZ-R90",
        0x12C: "Sony MZ-R900/MZ-R700/MZ-R501",
        0x12F: "Sony MZ-R410/MZ-R909/MZ-B100",
        0x136: "Sony PMC-MD55",
        0x13D: "Sony LAM-Z03",
        0x144: "Sony MDS-303",
        0x145: "Sony MDS-503",
        0x146: "Sony MDS-JE500/MDS-JE510",
        0x147: "Sony MDS-B5",
        0x14A: "Sony MDS-JE520",
        0x14C: "Sony MDS-W1",
        0x14D: "Sony MDS-JB920/MDS-JB730/MDS-JE530/MDS-JE330/MDS-JE440",
        0x154: "Sony MDS-JB940/MDS-S50/DMC-MD595/MDS-PC3",
        0x157: "Sony MDS-NT1",
        0x158: "Sony MMD-JE480",
        0x159: "Sony MDS-S500",
        0x17E: "Sony MDS-E10/MDS-E12",
        0x305: "Panasonic SJ-MR100/SJ-MR200",
        0x307: "Panasonic SJ-MR220",
        0x308: "Panasonic SJ-MR250",
        0x30A: "Panasonic SJ-MR240/SJ-MR270",
        0x304: "Technics SJ-MD150",
        0xA11: "Sharp MD-MS701",
        0xA23: "Sharp MD-F250",
        0x1209: "Tascam MD-CD1/MD-CD1mkII",
        0xA26: "Tascam MD-CD1mkIII",
        0xD0A: "Aiwa AM-F70",
        0xD0B: "Aiwa AM-F72",
        0x1001: "Yamaha MD4",
        0x1003: "Yamaha MD4s",
        0xA13: "Yamaha MDX-595",
        ownSignature: "TOCManip",
    ]
}

extension NetMDFactory {
    /// Reads UTOC sectors 0...3 (read-only).
    public func readTOC() async throws -> TableOfContents {
        var sectors: [[UInt8]?] = []
        for i in 0..<4 { sectors.append(try await readUTOCSector(i)) }
        return TableOfContents(sectors: sectors)
    }
}
