import Testing
@testable import NetMDKit

@Suite struct ListContentTests {
    func makeDevice() -> FakeNetMDDevice {
        FakeNetMDDevice(
            rawTitle: "0;Road Trip//2-3;Side B//",
            rawFullWidthTitle: "０；ロードトリップ／／２－３；Ｂ面／／",
            tracks: [
                .init(title: "Intro", length: [0, 1, 5, 0]),
                .init(title: "Highway", fullWidthTitle: "ハイウェイ", length: [0, 4, 30, 86], encoding: .lp2),
                .init(title: "Mono Demo", length: [0, 2, 0, 0], channels: .mono, protected: true),
            ]
        )
    }

    func open(_ device: FakeNetMDDevice) async throws -> NetMDInterface {
        try await NetMDInterface.open(transport: device, vendorID: 0x054c, productID: 0x00c8)
    }

    @Test func listsDiscTitlesGroupsAndTracks() async throws {
        let iface = try await open(makeDevice())
        #expect(iface.deviceName == "Sony MZ-N710/NF810")

        let disc = try await iface.listContent()
        #expect(disc.title == "Road Trip")
        #expect(disc.fullWidthTitle == "ロードトリップ")
        #expect(disc.writable)
        #expect(!disc.writeProtected)
        #expect(disc.trackCount == 3)
        #expect(disc.total == timeToFrames([1, 20, 0, 0]))
        #expect(disc.used == timeToFrames([0, 10, 0, 0]))
        #expect(disc.left == timeToFrames([1, 10, 0, 0]))

        #expect(disc.groups.map(\.title) == [nil, "Side B"])
        #expect(disc.groups[1].fullWidthTitle == "Ｂ面")
        #expect(disc.groups[0].tracks.map(\.index) == [0])
        #expect(disc.groups[1].tracks.map(\.index) == [1, 2])

        let highway = disc.tracks[1]
        #expect(highway.title == "Highway")
        #expect(highway.fullWidthTitle == "ハイウェイ")
        #expect(highway.duration == timeToFrames([0, 4, 30, 86]))
        #expect(highway.encodingName == "LP2")

        let mono = disc.tracks[2]
        #expect(mono.encodingName == "SP Mono")
        #expect(mono.isProtected)
    }

    @Test func halvesOversizedCapacity() async throws {
        // Sharp decks report capacity in the current recording mode, e.g. LP4 (4x).
        let device = makeDevice()
        device.capacity = [[0, 40, 0, 0], [5, 20, 0, 0], [4, 40, 0, 0]]
        let disc = try await open(device).listContent()
        #expect(disc.total == timeToFrames([1, 20, 0, 0]))
        #expect(disc.used == timeToFrames([0, 10, 0, 0]))
    }

    @Test func deviceStatus() async throws {
        let device = makeDevice()
        let status = try await open(device).getDeviceStatus()
        #expect(status.discPresent)
        #expect(status.state == .ready)
        #expect(status.track == 2)
        #expect(status.time == .init(minute: 1, second: 30, frame: 42))

        device.positionRejected = true
        device.operatingStatus = 50037
        let playing = try await open(device).getDeviceStatus()
        #expect(playing.state == .playing)
        #expect(playing.time == nil)
        #expect(playing.track == nil)
    }

    @Test func deviceStatusWithShortPlaybackReply() async throws {
        let device = makeDevice()
        device.shortPlaybackStatus = true
        let status = try await open(device).getDeviceStatus()
        #expect(status.state == .ready)
    }

    @Test func rejectedQueryThrows() async throws {
        let iface = try await open(makeDevice())
        await #expect(throws: NetMDError.self) { try await iface.getTrackTitle(99) }
    }

    /// Milestone 1 must never change anything on the player. Every command sent while
    /// reading a disc has to be a read (1806), a status query (1809), or opening a
    /// descriptor for reading / closing it (1808 with action 01 or 00).
    @Test func readingADiscSendsOnlyReadCommands() async throws {
        let device = makeDevice()
        let iface = try await open(device)
        _ = try await iface.listContent()
        _ = try await iface.getDeviceStatus()
        _ = try await iface.getNetMDLevelIfSupported()

        #expect(!device.commands.isEmpty)
        for command in device.commands {
            #expect(command[0] == 0x00, "status byte must be a plain control query")
            let opcode = (Int(command[1]) << 8) | Int(command[2])
            #expect([0x1806, 0x1808, 0x1809].contains(opcode), "unexpected command \(hex(command))")
            if opcode == 0x1808 {
                let action = command[command.count - 2]
                #expect(action == 0x01 || action == 0x00, "descriptor opened for writing: \(hex(command))")
            }
        }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private extension NetMDInterface {
    /// The fake device doesn't model the subunit identifier; it rejects it like old decks do.
    func getNetMDLevelIfSupported() async throws -> NetMDLevel? {
        try? await getNetMDLevel()
    }
}
