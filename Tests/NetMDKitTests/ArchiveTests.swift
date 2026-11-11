import Foundation
import Testing
@testable import NetMDKit

@Suite struct ArchiveTests {
    var toc: TableOfContents { TableOfContents(sectors: TOCTests.fixture.sectors.map { hexBytes($0) }) }

    @Test func fingerprintIgnoresTheSignatureButNotTheTracks() throws {
        let a = try #require(discFingerprint(toc))
        var resigned = toc
        resigned.deviceSignature = 0x0a23
        #expect(discFingerprint(resigned) == a)
        var moved = toc
        moved.trackFragments[1].end = DiscAddress(logical: 0x6fe)
        #expect(discFingerprint(moved) != a)
        var retitled = toc
        retitled.titleCells[1].title[0] = UInt8(ascii: "N")
        #expect(discFingerprint(retitled) != a)
        #expect(discFingerprint(TableOfContents(sectors: [[UInt8](repeating: 0, count: 2352), nil, nil, nil])) == nil)
    }

    @Test func indexFindsCompleteArchivesOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftMD-archive-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var index = ArchiveIndex.load(from: root)
        #expect(index.discs.isEmpty)
        index.record(.init(fingerprint: "abc", folder: "Mixtape", title: "Mixtape", archivedAt: Date(timeIntervalSince1970: 0), complete: false))
        #expect(index.entry(for: "abc") == nil)
        index.record(.init(fingerprint: "abc", folder: "Mixtape", title: "Mixtape", archivedAt: Date(timeIntervalSince1970: 0), complete: true))
        try index.save(to: root)
        let loaded = ArchiveIndex.load(from: root)
        #expect(loaded.discs.count == 1)
        #expect(loaded.entry(for: "abc")?.folder == "Mixtape")
    }

    @Test func folderNames() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(archiveFolderName(title: "Mixtape: Summer/Fall", date: date) == "Mixtape- Summer-Fall")
        #expect(archiveFolderName(title: "  ", date: date).hasPrefix("Untitled disc 20"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftMD-folders-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Mixtape"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(uniqueFolderURL(in: root, name: "Mixtape").lastPathComponent == "Mixtape (2)")
    }

    @Test func discRecordUsesTheTOC() throws {
        let tracks = [
            Track(index: 0, title: "Hello world", fullWidthTitle: nil, duration: 512 * 60, channel: 0, encoding: 0x90, protected: 0),
            Track(index: 1, title: "B-side", fullWidthTitle: nil, duration: 512 * 30, channel: 0, encoding: 0x92, protected: 0),
        ]
        let disc = Disc(title: "Mixtape", fullWidthTitle: "", writable: true, writeProtected: false, used: 0, left: 0, total: 0,
                        trackCount: 2, groups: [Group(index: 0, title: nil, fullWidthTitle: nil, tracks: tracks)])
        let record = DiscRecord(fingerprint: "abc", disc: disc, toc: toc, player: "Sony MZ-N910", firmware: "S1.600")
        #expect(record.tracks.map(\.number) == [1, 2])
        #expect(record.tracks[0].seconds == 60)
        #expect(record.tracks[0].recordedBy?.contains("MZ-N910") == true)
        #expect(record.tracks[1].recordedBy?.contains("MZ-N707") == true)
        #expect(record.tocWrittenBy.contains("MZ-N910"))
    }
}
