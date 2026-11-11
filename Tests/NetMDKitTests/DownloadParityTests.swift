import CryptoKit
import Foundation
import Testing
@testable import NetMDKit

/// Replays netmd-exploits' disc backup against a simulated player (Tools/record-netmdjs-download.js):
/// SwiftMD must send the same commands, byte for byte, and produce the same file.
@Suite struct DownloadParityTests {
    struct Recording: Decodable {
        struct Result: Decodable {
            let `extension`: String
            let length: Int
            let sha256: String
            let head: String
        }
        /// netmd-exploits' output (absent for recordings that don't download).
        let result: Result?
        let exchanges: [ReplayTransport.Exchange]
    }

    static let recordings: [String: Recording] = {
        let url = Bundle.module.url(forResource: "download-transcripts", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode([String: Recording].self, from: Data(contentsOf: url))
    }()

    func replay(_ name: String, method: AtracDownloader.Method? = nil) async throws {
        let recording = try #require(Self.recordings[name], "missing recording \(name)")
        let transport = ReplayTransport(recording.exchanges)
        let iface = try await NetMDInterface.open(transport: transport, vendorID: 0x054c, productID: 0x00c7)
        let track: DownloadedTrack
        do {
            let session = try await ExploitSession.create(device: iface, factory: NetMDFactory(device: iface, kind: .netmd))
            session.sleep = { _ in }
            let downloader = try AtracDownloader(session: session, method: method)
            try await downloader.prepare()
            track = try await downloader.downloadTrack(0)
            try await downloader.finish()
            try await session.close()
        } catch {
            Issue.record("\(name): \(transport.mismatch ?? String(describing: error))")
            return
        }
        #expect(transport.remaining == 0, "\(name): \(transport.remaining) netmd-exploits commands were never sent")
        #expect(track.complete)
        let expected = try #require(recording.result)
        #expect(track.fileExtension == expected.extension)
        #expect(track.data.count == expected.length)
        #expect(hexString(Array(track.data.prefix(64))) == expected.head)
        #expect(hexString(Array(SHA256.hash(data: track.data))) == expected.sha256)
    }

    @Test func spStereoOnTypeS() async throws {
        try await replay("download.spStereo.S1.600")
    }

    /// netmd-exploits' bulk reader (unmodified), as ElectronWMD uses on Type-S.
    @Test func spStereoOnTypeSWithBulkTransfers() async throws {
        try await replay("download.spStereo.S1.600.bulk", method: .bulk)
    }

    @Test func bulkIsTypeSOnly() {
        #expect(AtracDownloader.supportsBulk(version: "S1.600"))
        #expect(AtracDownloader.supportsBulk(version: "S1.000"))
        #expect(!AtracDownloader.supportsBulk(version: "R1.400"))
    }

    @Test func lp2OnTypeR() async throws {
        try await replay("download.lp2.R1.400")
    }

    @Test func secondsConversionMatchesFirmware() {
        // Values from netmd-exploits' conversion of 20 sectors' worth of time.
        var lp2 = TimeRepresentation(seconds: 20 * 704.0 / 11025.0)
        lp2.fromLP2Mono()
        #expect(lp2.seconds == 2)
        var lp4 = TimeRepresentation(seconds: 20 * 704.0 / 11025.0)
        lp4.fromLP4()
        #expect(lp4.seconds == 4) // netmd-exploits' translateRepresentationFromLP4 gives 4
    }

    @Test func sectorValidityCountsFramesFromTheEnd() {
        var data = [UInt8](repeating: 1, count: 212 + 100)
        data[0] = 9 // A frame aligned to the start would fail; netmd-exploits checks the last 212 bytes.
        #expect(isValidATRACSector(data[...]))
        data[100] = 7
        data[101] = 8
        #expect(!isValidATRACSector(data[...]))
    }
}

extension DownloadParityTests {
    /// The real MZ-N910's slots: the firmware's fixes switched on in 0-3, HFEC in 5, old leftovers in
    /// 4, 6 and 7. Only a switched-off slot (7) may be used; netmd-exploits alone would pick 3.
    @Test func neverOverwritesTheFirmwaresOwnPatches() async throws {
        try await replay("download.spStereo.S1.600.n910slots")
    }
}

extension DownloadParityTests {
    /// Bulk needs four free slots. With three and no known way to free one (anything but S1.600,
    /// see SlotMerge.swift), it must refuse without sending anything.
    @Test func bulkRefusesWithoutEnoughFreeSlots() async throws {
        let transport = ReplayTransport([])
        let iface = try await NetMDInterface.open(transport: transport, vendorID: 0x054c, productID: 0x00c7)
        let report = SafetyPatches.Report(hfecSupported: true, hfecFoundAt: 5, hfecLoadedAt: nil, developerPatches: [], freePatches: [4, 6, 7])
        let session = ExploitSession(device: iface, factory: NetMDFactory(device: iface, kind: .netmd), version: "S1.500", safety: report, log: { _ in })
        let downloader = try AtracDownloader(session: session, method: .bulk)
        await #expect(throws: ExploitError.notEnoughPatchSlots(needed: 4, free: 3)) { try await downloader.prepare() }
        #expect(transport.mismatch == nil)
        #expect(session.freePatches == [4, 6, 7])
    }
}

extension DownloadParityTests {
    /// Backups use Sony's factory mode: other brands are refused before anything is sent.
    @Test func backUpRefusesOtherBrandsWithoutSendingAnything() async throws {
        let transport = ReplayTransport([])
        let iface = try await NetMDInterface.open(transport: transport, vendorID: 0x04dd, productID: 0x7202)
        await #expect(throws: ExploitError.unsupportedDevice(iface.deviceName)) {
            try await iface.backUp(tracks: [0], alsoAllowedFirmware: [], progress: { _, _ in }, isCancelled: { false }, save: { _, _ in })
        }
        await #expect(throws: ExploitError.unsupportedDevice(iface.deviceName)) { _ = try await iface.archiveInfo() }
        #expect(transport.mismatch == nil)
    }

    @Test func onlyHardwareTestedFirmwareIsTrustedByDefault() {
        #expect(AtracDownloader.testedFirmware == ["S1.600", "R1.400"])
    }
}
