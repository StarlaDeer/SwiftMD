// Archiving a collection: one folder per disc, a record of what's on it, and an index so the same
// disc isn't backed up twice.

import CryptoKit
import Foundation

/// Identifies a disc by its table of contents: where every track is, plus titles and recording
/// dates. Sector headers and the device signature are left out, so a TOC rewritten unchanged by
/// another recorder still matches. Nil when the disc has no track table (pre-recorded discs).
public func discFingerprint(_ toc: TableOfContents) -> String? {
    guard toc.trackCount > 0 else { return nil }
    let sectors = toc.sectors(updateSignature: false)
    var hasher = SHA256()
    for (i, sector) in sectors.enumerated() {
        guard let sector else { continue }
        hasher.update(data: Data(sector.dropFirst(i == 0 ? 0x1f : 0x2f)))
    }
    return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
}

/// What was on a disc, saved as disc.json next to its tracks.
public struct DiscRecord: Codable, Sendable, Equatable {
    public struct TrackRecord: Codable, Sendable, Equatable {
        public var number: Int
        public var title: String?
        public var fullWidthTitle: String?
        public var group: String?
        public var seconds: Double
        public var encoding: String
        public var recordedBy: String?
        public var recordedOn: String?
        public var files: [String]
    }

    public var fingerprint: String
    public var title: String
    public var fullWidthTitle: String
    public var archivedAt: Date
    public var player: String
    public var firmware: String
    public var tocWrittenBy: String
    public var tracks: [TrackRecord]
    /// False if any track couldn't be copied completely.
    public var complete: Bool

    public init(fingerprint: String, disc: Disc, toc: TableOfContents, player: String, firmware: String, archivedAt: Date = Date()) {
        self.fingerprint = fingerprint
        title = disc.title
        fullWidthTitle = disc.fullWidthTitle
        self.archivedAt = archivedAt
        self.player = player
        self.firmware = firmware
        tocWrittenBy = TableOfContents.signatures[toc.deviceSignature] ?? String(format: "unknown (0x%04x)", toc.deviceSignature)
        complete = false
        tracks = disc.groups.flatMap { group in
            group.tracks.map { track in
                let info = track.index + 1 <= toc.trackCount ? toc.trackInfo(track.index + 1) : nil
                let stamp = info?.timestamp.flatMap { t -> String? in
                    guard t.signature != 0 || t.year != 0 || t.month != 0 else { return nil }
                    return String(format: "20%02x-%02x-%02x %02x:%02x:%02x", t.year, t.month, t.day, t.hour, t.minute, t.second)
                }
                return TrackRecord(
                    number: track.index + 1, title: track.title, fullWidthTitle: track.fullWidthTitle, group: group.title,
                    seconds: Double(track.duration) / Double(framesPerSecond), encoding: track.encodingName,
                    recordedBy: stamp == nil ? nil : info?.writtenBy, recordedOn: stamp, files: []
                )
            }
        }.sorted { $0.number < $1.number }
    }

    public func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: folder.appendingPathComponent("disc.json"))
    }
}

/// archive-index.json in the archive folder: which discs are already there.
public struct ArchiveIndex: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var fingerprint: String
        public var folder: String
        public var title: String
        public var archivedAt: Date
        public var complete: Bool

        public init(fingerprint: String, folder: String, title: String, archivedAt: Date, complete: Bool) {
            self.fingerprint = fingerprint
            self.folder = folder
            self.title = title
            self.archivedAt = archivedAt
            self.complete = complete
        }
    }

    public var discs: [Entry] = []

    public static let fileName = "archive-index.json"

    public init() {}

    public static func load(from root: URL) -> ArchiveIndex {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return ArchiveIndex() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ArchiveIndex.self, from: data)) ?? ArchiveIndex()
    }

    public func save(to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// The complete archive of this disc, if there is one.
    public func entry(for fingerprint: String) -> Entry? {
        discs.last { $0.fingerprint == fingerprint && $0.complete }
    }

    public mutating func record(_ entry: Entry) {
        discs.removeAll { $0.fingerprint == entry.fingerprint && $0.folder == entry.folder }
        discs.append(entry)
    }
}

/// A folder name for a disc: its title, or "Untitled disc <date>" when it has none.
public func archiveFolderName(title: String, date: Date = Date()) -> String {
    let cleaned = title
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    if !cleaned.isEmpty { return cleaned }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    return "Untitled disc \(formatter.string(from: date))"
}

/// `name` in `root`, or "name (2)", "name (3)"… if a folder with that name exists.
public func uniqueFolderURL(in root: URL, name: String) -> URL {
    var url = root.appendingPathComponent(name, isDirectory: true)
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = root.appendingPathComponent("\(name) (\(n))", isDirectory: true)
        n += 1
    }
    return url
}

extension NetMDInterface {
    /// Reads what archiving needs to know about the disc: its TOC and the player's firmware.
    /// Read-only (factory mode, no patches).
    public func archiveInfo() async throws -> (toc: TableOfContents, firmware: String) {
        try checkBackupSupported()
        try await stop()
        let factory = try await factory()
        guard factory.kind == .netmd else { throw ExploitError.unsupportedDevice(deviceName) }
        let firmware = try await factory.descriptiveDeviceCode()
        let toc = try await factory.readTOC()
        return (toc, firmware)
    }
}
