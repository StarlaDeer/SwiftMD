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
        try encoder.encode(self).write(to: folder.appendingPathComponent("disc.json"), options: .atomic)
    }

    public static func load(from folder: URL) -> DiscRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("disc.json")) else { return nil }
        return try? decoder.decode(DiscRecord.self, from: data)
    }

    /// Tracks with no files, and files that are missing or empty, in `folder`. Empty when every
    /// track's files are there.
    public func missingFiles(in folder: URL) -> [String] {
        tracks.flatMap { track -> [String] in
            guard !track.files.isEmpty else { return ["track \(track.number)"] }
            return track.files.filter { file in
                ((try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file).path)[.size] as? Int) ?? 0) == 0
            }
        }
    }
}

public enum ArchiveIndexError: Error, CustomStringConvertible {
    case unreadable(String)

    public var description: String {
        switch self {
        case .unreadable(let why):
            return "Your archive's list of discs (archive-index.json) couldn't be read, so SwiftMD left it alone: \(why). If the archive is on an external drive or in iCloud, make sure it's connected and downloaded, then try again."
        }
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

    /// Reads the index. No index yet is an empty one. One that can't be read at all (a drive or
    /// iCloud not ready) throws, so nothing saves over it. One that reads but doesn't make sense is
    /// kept beside it as "archive-index (unreadable …).json" and rebuilt from the disc.json files in
    /// the archive's folders, which hold the same information.
    public static func load(from root: URL) throws -> ArchiveIndex {
        let url = root.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return ArchiveIndex() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ArchiveIndexError.unreadable(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let index = try? decoder.decode(ArchiveIndex.self, from: data) { return index }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("archive-index (unreadable \(stamp.string(from: Date()))).json"))
        let rebuilt = rebuild(from: root)
        try rebuilt.save(to: root)
        return rebuilt
    }

    /// The index as the archive's folders describe it (each folder's disc.json), oldest first.
    public static func rebuild(from root: URL) -> ArchiveIndex {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var index = ArchiveIndex()
        index.discs = folders.compactMap { folder in
            DiscRecord.load(from: folder).map {
                Entry(fingerprint: $0.fingerprint, folder: folder.lastPathComponent, title: $0.title,
                      archivedAt: $0.archivedAt, complete: $0.complete)
            }
        }.sorted { ($0.archivedAt, $0.folder) < ($1.archivedAt, $1.folder) }
        return index
    }

    /// Saves the index, keeping the previous one as archive-index.json.bak.
    public func save(to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = root.appendingPathComponent(Self.fileName)
        let backup = root.appendingPathComponent(Self.fileName + ".bak")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The complete archive of this disc, if there is one.
    public func entry(for fingerprint: String) -> Entry? {
        discs.last { $0.fingerprint == fingerprint && $0.complete }
    }

    /// Every complete archive of discs with this fingerprint, newest first. Discs with no titles or
    /// recording dates are told apart only by their track layout, so two different discs can share
    /// a fingerprint; their audio tells them apart (sampleMatchesArchivedFile).
    public func entries(for fingerprint: String) -> [Entry] {
        discs.filter { $0.fingerprint == fingerprint && $0.complete }.reversed()
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

/// The exact ATRAC copy of a track in its archive folder (not the playable copy).
public func archivedAudioFile(_ track: DiscRecord.TrackRecord) -> String? {
    track.files.first { !$0.contains("/") && ($0.hasSuffix(".aea") || $0.hasSuffix(".wav")) }
}

/// True when a sample read from the disc (downloadTrack with a sector limit: the same header and the
/// start of the audio) is exactly the start of the archived copy.
public func sampleMatchesArchivedFile(sample: [UInt8], file: Data) -> Bool {
    !sample.isEmpty && file.count >= sample.count && file.prefix(sample.count).elementsEqual(sample)
}

/// Of `paths` (relative to an archive folder), the track files (exact copies and playable copies)
/// that aren't in `keeping`: copies that stopped early or weren't counted as done.
public func unlistedTrackFiles(_ paths: [String], keeping: Set<String>) -> [String] {
    paths.filter { path in
        let ext = (path as NSString).pathExtension.lowercased()
        return ["aea", "wav", "m4a"].contains(ext) && !keeping.contains(path)
    }.sorted()
}
