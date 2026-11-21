import AVFoundation
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
        var index = try ArchiveIndex.load(from: root)
        #expect(index.discs.isEmpty)
        index.record(.init(fingerprint: "abc", folder: "Mixtape", title: "Mixtape", archivedAt: Date(timeIntervalSince1970: 0), complete: false))
        #expect(index.entry(for: "abc") == nil)
        index.record(.init(fingerprint: "abc", folder: "Mixtape", title: "Mixtape", archivedAt: Date(timeIntervalSince1970: 0), complete: true))
        try index.save(to: root)
        let loaded = try ArchiveIndex.load(from: root)
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

    /// Discs with no titles or dates are told apart only by their track layout, so the index can
    /// hold several complete archives with one fingerprint; all of them are offered, newest first.
    @Test func indexOffersEveryCompleteArchiveWithAFingerprint() {
        var index = ArchiveIndex()
        let date = Date(timeIntervalSince1970: 0)
        index.record(.init(fingerprint: "a", folder: "A1", title: "", archivedAt: date, complete: true))
        index.record(.init(fingerprint: "a", folder: "A2", title: "", archivedAt: date, complete: false))
        index.record(.init(fingerprint: "b", folder: "B", title: "", archivedAt: date, complete: true))
        index.record(.init(fingerprint: "a", folder: "A3", title: "", archivedAt: date, complete: true))
        #expect(index.entries(for: "a").map(\.folder) == ["A3", "A1"])
        #expect(index.entries(for: "c").isEmpty)
    }

    @Test func theExactCopyIsTheFileOutsidePlayable() throws {
        let json = #"{"number":1,"seconds":1,"encoding":"SP","files":["Playable/01.m4a","01 - Song.aea"]}"#
        let track = try JSONDecoder().decode(DiscRecord.TrackRecord.self, from: Data(json.utf8))
        #expect(archivedAudioFile(track) == "01 - Song.aea")
        let none = try JSONDecoder().decode(DiscRecord.TrackRecord.self, from: Data(#"{"number":1,"seconds":1,"encoding":"SP","files":["Playable/01.m4a"]}"#.utf8))
        #expect(archivedAudioFile(none) == nil)
    }

    /// A sample is the same header and the start of the audio, so it must be the file's first bytes.
    @Test func sampleMustBeTheStartOfTheArchivedFile() {
        let file = Data((0..<100).map { UInt8($0) })
        #expect(sampleMatchesArchivedFile(sample: Array(0..<40), file: file))
        #expect(sampleMatchesArchivedFile(sample: Array(0..<100), file: file))
        #expect(!sampleMatchesArchivedFile(sample: Array(0..<39) + [0xff], file: file))
        #expect(!sampleMatchesArchivedFile(sample: Array(0..<101).map { UInt8($0) }, file: file))
        #expect(!sampleMatchesArchivedFile(sample: [], file: file))
    }

    /// Carrying on with an unfinished archive: copies that aren't listed as done (stopped early, or
    /// failed to decode) are cleared away; listed ones, disc.json and the TOC stay.
    @Test func unlistedTrackFilesAreOnlyUnlistedCopies() {
        let paths = ["disc.json", "TOC", "01.aea", "02 (incomplete).aea", "03.wav", "Playable",
                     "Playable/01.m4a", "Playable/03.m4a", "notes.txt", "Cover.jpg"]
        let keep: Set<String> = ["01.aea", "Playable/01.m4a"]
        #expect(unlistedTrackFiles(paths, keeping: keep) == ["02 (incomplete).aea", "03.wav", "Playable/03.m4a"])
    }

    @Test func incompleteTracksAreNamedOneBased() {
        #expect(BackupError.incomplete(tracks: [13]).description.hasPrefix("Track 14 couldn't be read completely"))
        #expect(BackupError.incomplete(tracks: [0, 4, 13]).description.hasPrefix("Tracks 1, 5 and 14 couldn't"))
    }

    // MARK: Keeping the archive's records safe (review S1-S4)

    static func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftmd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A disc.json for a two-track disc, with each track's exact and playable copy listed.
    static func writeDisc(_ folder: URL, fingerprint: String, complete: Bool, date: String) throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Playable"), withIntermediateDirectories: true)
        let json = """
        {"fingerprint":"\(fingerprint)","title":"","fullWidthTitle":"","archivedAt":"\(date)","player":"MZ-N910",
         "firmware":"S1.600","tocWrittenBy":"MZ-N910","complete":\(complete),"tracks":[
          {"number":1,"seconds":1,"encoding":"SP","files":["01.aea","Playable/01.m4a"]},
          {"number":2,"seconds":1,"encoding":"SP","files":["02.aea","Playable/02.m4a"]}]}
        """
        try Data(json.utf8).write(to: folder.appendingPathComponent("disc.json"))
        for file in ["01.aea", "Playable/01.m4a", "02.aea", "Playable/02.m4a"] {
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent(file))
        }
    }

    @Test func missingFilesFindsMissingAndEmptyFiles() throws {
        let folder = try Self.tempFolder().appendingPathComponent("Disc")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try Self.writeDisc(folder, fingerprint: "a", complete: true, date: "2026-11-20T10:00:00Z")
        let record = try #require(DiscRecord.load(from: folder))
        #expect(record.missingFiles(in: folder).isEmpty)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("02.aea"))
        try Data().write(to: folder.appendingPathComponent("Playable/01.m4a"))
        #expect(record.missingFiles(in: folder) == ["Playable/01.m4a", "02.aea"])
    }

    /// S2: an index that can't be decoded used to load as empty, and the next save wiped the list.
    /// Now it's kept aside and rebuilt from the folders' disc.json files.
    @Test func aBrokenIndexIsKeptAndRebuiltFromTheFolders() throws {
        let root = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeDisc(root.appendingPathComponent("B"), fingerprint: "b", complete: false, date: "2026-11-20T11:00:00Z")
        try Self.writeDisc(root.appendingPathComponent("A"), fingerprint: "a", complete: true, date: "2026-11-20T10:00:00Z")
        try Data("{ not json".utf8).write(to: root.appendingPathComponent(ArchiveIndex.fileName))

        let index = try ArchiveIndex.load(from: root)
        #expect(index.discs.map(\.folder) == ["A", "B"])
        #expect(index.entries(for: "a").map(\.folder) == ["A"])
        #expect(index.entries(for: "b").isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let kept = try #require(names.first { $0.hasPrefix("archive-index (unreadable ") })
        #expect(try String(contentsOf: root.appendingPathComponent(kept), encoding: .utf8) == "{ not json")
        #expect(try ArchiveIndex.load(from: root) == index)
    }

    @Test func anIndexThatCantBeReadIsLeftAlone() throws {
        let root = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        // Something that exists but can't be read as a file.
        try FileManager.default.createDirectory(at: root.appendingPathComponent(ArchiveIndex.fileName), withIntermediateDirectories: false)
        #expect(throws: ArchiveIndexError.self) { try ArchiveIndex.load(from: root) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(ArchiveIndex.fileName).path))
    }

    @Test func noIndexYetIsAnEmptyOneAndSavingKeepsTheLastOne() throws {
        let root = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try ArchiveIndex.load(from: root).discs.isEmpty)
        var index = ArchiveIndex()
        index.record(.init(fingerprint: "a", folder: "A", title: "", archivedAt: Date(timeIntervalSince1970: 0), complete: true))
        try index.save(to: root)
        let first = try ArchiveIndex.load(from: root)
        index.record(.init(fingerprint: "b", folder: "B", title: "", archivedAt: Date(timeIntervalSince1970: 0), complete: true))
        try index.save(to: root)
        let backup = try Data(contentsOf: root.appendingPathComponent(ArchiveIndex.fileName + ".bak"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(ArchiveIndex.self, from: backup) == first)
        #expect(try ArchiveIndex.load(from: root).discs.count == 2)
    }

    /// S4: the playable copy is read back after writing. A real 3-second copy must pass the check.
    @Test func playableCopiesAreCheckedForLength() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frames = 44100 * 3
        let samples = (0..<frames).flatMap { i -> [Float] in
            let v = Float(sin(Double(i) * 2 * .pi * 440 / 44100)) * 0.3
            return [v, v]
        }
        let url = folder.appendingPathComponent("tone.m4a")
        try writeM4A(PCMAudio(samples: samples), to: url)
        let length = try Int(AVAudioFile(forReading: url).length)
        #expect(abs(length - frames) <= 4096)
    }

    /// S7: SwiftMD only runs on Type-S firmware whose crash safety net (HFEC) it knows.
    @Test func typeSFirmwareWithoutHFECIsRecognised() {
        #expect(versionStoreLookup(SafetyPatches.hfecAddress, version: "S1.600") != nil)
        #expect(versionStoreLookup(SafetyPatches.hfecAddress, version: "S1.400") != nil)
        #expect(versionStoreLookup(SafetyPatches.hfecAddress, version: "S1.300") == nil)
        #expect(versionStoreLookup(SafetyPatches.hfecAddress, version: "S1.100") == nil)
    }
}
