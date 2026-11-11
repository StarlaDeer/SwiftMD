import Foundation
import Testing
@testable import NetMDKit

/// Checks SwiftMD's UTOC port against netmd-tocmanip on a hand-built TOC (Fixtures/toc-fixture.json,
/// made by Tools/record-netmdjs-download.js), and the TOC write against netmd-exploits' ForceTOCEdit.
@Suite struct TOCTests {
    struct Fixture: Decodable {
        struct Info: Decodable {
            let title: String
            let writtenBy: String
            let signature: Int
            let fragments: [[Int]]
        }
        let sectors: [String]
        let rebuiltWithSignature: [String]
        let discTitle: String
        let fullWidth: String
        let info: [Info]
        let edited: [String]
    }

    static let fixture: Fixture = {
        let url = Bundle.module.url(forResource: "toc-fixture", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    var toc: TableOfContents { TableOfContents(sectors: Self.fixture.sectors.map { hexBytes($0) }) }

    @Test func roundTripsByteForByte() {
        let rebuilt = toc.sectors(updateSignature: false).map { hexString($0!) }
        #expect(rebuilt == Self.fixture.sectors)
    }

    @Test func rebuildingMarksTheTOCLikeNetMDTocmanip() {
        #expect(toc.sectors().map { hexString($0!) } == Self.fixture.rebuiltWithSignature)
    }

    @Test func titlesAndTrackInfo() {
        let toc = self.toc
        #expect(toc.trackCount == 3)
        #expect(toc.title(track: 0) == Self.fixture.discTitle)
        #expect(toc.title(track: 1, fullWidth: true) == Self.fixture.fullWidth)
        for (i, expected) in Self.fixture.info.enumerated() {
            let info = toc.trackInfo(i + 1)
            #expect(info.title == expected.title)
            #expect(info.timestamp?.signature == expected.signature)
            #expect(info.fragments.map { [$0.start.logical, $0.start.group, $0.end.logical, $0.end.group, $0.mode] } == expected.fragments)
        }
        // These names are the same in netmd-tocmanip's bundled and current signature lists.
        #expect(toc.trackInfo(1).writtenBy == Self.fixture.info[0].writtenBy)
        #expect(toc.trackInfo(3).writtenBy == "UNKNOWN")
    }

    @Test func swapAndFlagEditsMatchNetMDTocmanip() {
        var toc = self.toc
        toc.swapTracks(1, 2)
        toc.setFlag(TOCModeFlag.writable, false, track: 1)
        #expect(toc.sectors(updateSignature: false).map { hexString($0!) } == Self.fixture.edited)
    }

    func replayWrite(_ name: String) async throws {
        let recording = try #require(DownloadParityTests.recordings[name], "missing recording \(name)")
        let transport = ReplayTransport(recording.exchanges)
        let iface = try await NetMDInterface.open(transport: transport, vendorID: 0x054c, productID: 0x00c7)
        do {
            let session = try await ExploitSession.create(device: iface, factory: NetMDFactory(device: iface, kind: .netmd))
            session.sleep = { _ in }
            try await session.writeTOC(toc)
        } catch {
            Issue.record("\(name): \(transport.mismatch ?? String(describing: error))")
            return
        }
        #expect(transport.remaining == 0, "\(name): \(transport.remaining) netmd-exploits commands were never sent")
    }

    @Test func writeOnTypeS() async throws { try await replayWrite("toc.write.S1.600") }
    @Test func writeOnTypeR() async throws { try await replayWrite("toc.write.R1.400") }
}
