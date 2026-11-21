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

/// If SwiftMD can't take its code back out of the player, it must stop changing things and ask
/// for an unplug, never report an ordinary error as if the player were clean.
extension DownloadParityTests {
    /// A command the player "fails": the replay rejects it, as a real USB error would.
    static let failingExchange = try! JSONDecoder().decode(ReplayTransport.Exchange.self,
                                                          from: Data(#"{"request":0,"command":"ff","reply":""}"#.utf8))
    static let bulk = "download.spStereo.S1.600.bulk"
    /// Index of each write that starts a patch's main-control sequence (5, then 12 or 9).
    static func mainControlWrites(_ name: String) -> [Int] {
        let exchanges = recordings[name]!.exchanges
        return exchanges.indices.filter { exchanges[$0].bulkIn == nil && exchanges[$0].command.hasPrefix("001822ff008020800301000005") }
    }

    static func isUnplug(_ error: Error) -> Bool {
        if case ExploitError.needsUnplug = error { return true }
        return false
    }

    func session(_ transport: ReplayTransport) async throws -> ExploitSession {
        let iface = try await NetMDInterface.open(transport: transport, vendorID: 0x054c, productID: 0x00c7)
        let session = try await ExploitSession.create(device: iface, factory: NetMDFactory(device: iface, kind: .netmd))
        session.sleep = { _ in }
        return session
    }

    /// Review finding 3: the bulk reader's clean-up fails. Its hooks may still be live, so the
    /// session must not remove code execution or restore slots over them; it asks for an unplug.
    @Test func failedBulkCleanUpAsksForAnUnplug() async throws {
        let exchanges = Self.recordings[Self.bulk]!.exchanges
        // Where the reader's clean-up starts: after the track has been read.
        let full = ReplayTransport(exchanges)
        let fullSession = try await session(full)
        let fullReader = try AtracDownloader(session: fullSession, method: .bulk)
        try await fullReader.prepare()
        _ = try await fullReader.downloadTrack(0)
        let cleanUpStart = exchanges.count - full.remaining
        let unpatchStart = try #require(Self.mainControlWrites(Self.bulk).first { $0 > cleanUpStart }) - 1

        let transport = ReplayTransport(Array(exchanges[..<cleanUpStart]) + [Self.failingExchange] + Array(exchanges[unpatchStart...]))
        let session = try await session(transport)
        let reader = try AtracDownloader(session: session, method: .bulk)
        try await reader.prepare()
        _ = try await reader.downloadTrack(0)
        let finishError = await #expect(throws: ExploitError.self) { try await reader.finish() }
        #expect(finishError.map(Self.isUnplug) == true)
        // Neither a retry nor the session's own clean-up sends anything more.
        let sent = transport.remaining
        let retryError = await #expect(throws: ExploitError.self) { try await reader.finish() }
        #expect(retryError.map(Self.isUnplug) == true)
        let closeError = await #expect(throws: ExploitError.self) { try await session.close() }
        #expect(closeError.map(Self.isUnplug) == true)
        #expect(transport.remaining == sent)
    }

    /// Review finding 4: loading the code-execution patch fails on its last writes, after the slot
    /// was switched on. The session must know the slot is in an unknown state.
    @Test func failedPatchWriteAsksForAnUnplug() async throws {
        let exchanges = Self.recordings[Self.bulk]!.exchanges
        // The second main-control sequence of the first patch ("5, 9", after the slot is enabled).
        let lastWrites = Self.mainControlWrites(Self.bulk)[1]
        let transport = ReplayTransport(Array(exchanges[..<lastWrites]) + [Self.failingExchange])
        let session = try await session(transport)
        let reader = try AtracDownloader(session: session, method: .bulk)
        let loadError = await #expect(throws: ExploitError.self) { try await reader.prepare() }
        #expect(loadError.map(Self.isUnplug) == true)
        let closeError = await #expect(throws: ExploitError.self) { try await session.close() }
        #expect(closeError.map(Self.isUnplug) == true)
    }

    /// Review finding 5: Stop used to cancel the task, and a cancelled task's waits end at once,
    /// cutting commands and clean-up short. The player-side waits now always wait.
    @Test func waitsAreNotCutShortByCancelling() async {
        let task = Task { () -> Duration in
            withUnsafeCurrentTask { $0?.cancel() }
            let start = ContinuousClock.now
            await uninterruptibleSleep(.milliseconds(60))
            return ContinuousClock.now - start
        }
        #expect(await task.value >= .milliseconds(50))
    }
}
