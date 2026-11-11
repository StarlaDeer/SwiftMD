import Foundation
import Testing
@testable import NetMDKit

/// A player that only answers factory memory commands, backed by a byte map.
final class MemoryPlayer: USBTransport, @unchecked Sendable {
    var memory: [Int: UInt8] = [:]
    private(set) var writes = 0
    private var pending: [UInt8]?

    func byte(_ a: Int) -> UInt8 { memory[a] ?? 0 }
    func set(_ a: Int, _ bytes: [UInt8]) { for (i, b) in bytes.enumerated() { memory[a + i] = b } }
    func get(_ a: Int, _ n: Int) -> [UInt8] { (0..<n).map { byte(a + $0) } }

    func controlOut(request: UInt8, data: [UInt8]) throws {
        let q = Array(data.dropFirst()) // status byte
        func le32(_ o: Int) -> Int { Int(q[o]) | Int(q[o + 1]) << 8 | Int(q[o + 2]) << 16 | Int(q[o + 3]) << 24 }
        switch (q[0], q[1]) {
        case (0x18, 0x20): // changeMemoryState
            var out = q; out[2] = 0; pending = [0x09] + out
        case (0x18, 0x21): // read
            let addr = le32(4), len = Int(q[8])
            pending = [0x09, 0x18, 0x21, 0x00, q[3]] + Array(q[4..<8]) + [q[8], 0, 0] + get(addr, len) + [0, 0]
        case (0x18, 0x22): // write
            let addr = le32(4), len = Int(q[8])
            set(addr, Array(q[11..<11 + len]))
            writes += 1
            var out = Array(q.prefix(9)); out[2] = 0; pending = [0x09] + out
        default:
            throw USBError.io("MemoryPlayer can't answer \(q.prefix(2))")
        }
    }

    func controlIn(request: UInt8, length: Int) throws -> [UInt8] {
        if request == 0x01 { return [0, 0, UInt8(pending?.count ?? 0), 0] }
        defer { pending = nil }
        return Array((pending ?? []).prefix(length))
    }

    func bulkIn(length: Int) throws -> [UInt8] { [] }
    func bulkOut(_ data: [UInt8]) throws {}
    func close() {}
}

@Suite struct SlotMergeTests {
    static let m = FirmwareSlotMerge.known["S1.600"]!

    /// Patch registers and fix code as on the real MZ-N910 after start-up.
    func n910() -> MemoryPlayer {
        let p = MemoryPlayer()
        for slot in 0..<8 {
            let base = 0x0380_2000 + slot * 0x10
            p.set(base, [[0, 1, 2, 3, 4, 5].contains(slot) ? 1 : 0, 0, 0, 0])
        }
        p.set(0x0380_2044, [0x14, 0xbb, 0x00, 0x00]); p.set(0x0380_2048, [0x4a, 0x20, 0x08, 0x70]) // slot 4
        p.set(0x0200_015e, [0x4a]) // what slot 4's fix stored at start-up
        p.set(0x0380_2024, [0xb8, 0x9a, 0x05, 0x00]); p.set(0x0380_2028, Self.m.keepPatch.data)
        p.set(0x0380_2034, [0xc8, 0x9a, 0x05, 0x00]); p.set(0x0380_2038, Self.m.freePatch.data)
        p.set(Self.m.keepHandlerAddress, Self.m.keepHandler)
        p.set(Self.m.freeHandlerAddress, Self.m.freeHandler)
        return p
    }

    func session(_ player: MemoryPlayer) async throws -> ExploitSession {
        let iface = try await NetMDInterface.open(transport: player, vendorID: 0x054c, productID: 0x00c7)
        let report = SafetyPatches.Report(hfecSupported: true, hfecFoundAt: 5, hfecLoadedAt: nil, developerPatches: [], freePatches: [6, 7])
        return ExploitSession(device: iface, factory: NetMDFactory(device: iface, kind: .netmd), version: "S1.600", safety: report, log: { _ in })
    }

    @Test func mergeFreesSlotThreeAndRestoreUndoesEverything() async throws {
        let player = n910()
        let before = player.memory
        let session = try await session(player)

        try await session.mergeFirmwareSlots()
        #expect(session.freePatches == [3, 4, 6, 7])
        #expect(player.byte(0x0380_2010) & 1 == 1 && player.byte(0x0380_2000) & 1 == 1) // slots 0, 1 untouched
        #expect(player.byte(0x0380_2030) & 1 == 0) // slot 3 switched off
        #expect(player.byte(0x0380_2040) & 1 == 0) // slot 4 lent out
        #expect(player.byte(0x0380_2020) & 1 == 1) // slot 2 still on
        #expect(player.get(Self.m.returnWordAddress, 4) == Self.m.branchWord)
        #expect(player.get(Self.m.continuationAddress, Self.m.continuation.count) == Self.m.continuation)
        #expect(player.get(Self.m.freeHandlerAddress, 40) == Self.m.freeHandler) // Sony's slot 3 code untouched

        try await session.close()
        #expect(session.freePatches == [6, 7])
        #expect(session.mergedSlots == nil)
        // Patch-unit control register writes (5, 12, 5, 9) are commands, not state; compare the rest.
        let control = 0x0380_2080
        var after = player.memory
        after[control] = before[control]
        #expect(after.filter { $0.value != 0 } == before.filter { $0.value != 0 })
    }

    @Test func refusesWithoutWritingIfTheFixCodeDiffers() async throws {
        let player = n910()
        player.set(Self.m.keepHandlerAddress + 8, [0xff])
        let session = try await session(player)
        await #expect(throws: SlotMergeError.unexpectedPlayerState("fix code in RAM")) { try await session.mergeFirmwareSlots() }
        #expect(player.writes == 0)
        #expect(session.freePatches == [6, 7])
    }

    @Test func refusesIfSlotThreeIsNotSonysFix() async throws {
        let player = n910()
        player.set(0x0380_2034, [0x9c, 0xe6, 0x00, 0x00]) // something else in slot 3
        let session = try await session(player)
        await #expect(throws: SlotMergeError.unexpectedPlayerState("slot 3")) { try await session.mergeFirmwareSlots() }
        #expect(player.writes == 0)
    }

    @Test func refusesIfTheHandlerSpaceIsInUse() async throws {
        let player = n910()
        player.set(Self.m.continuationAddress + 70, [0x42])
        let session = try await session(player)
        await #expect(throws: SlotMergeError.unexpectedPlayerState("handler space in use")) { try await session.mergeFirmwareSlots() }
        #expect(player.writes == 0)
    }

    @Test func refusesIfSlotFourIsNotSonysStartupFix() async throws {
        let player = n910()
        player.set(0x0380_2048, [0x00, 0x20, 0x08, 0x70])
        let session = try await session(player)
        await #expect(throws: SlotMergeError.unexpectedPlayerState("slot 4")) { try await session.mergeFirmwareSlots() }
        #expect(player.writes == 0)
    }

    @Test func refusesIfTheStartupFixHasNotRun() async throws {
        let player = n910()
        player.set(0x0200_015e, [0x00])
        let session = try await session(player)
        await #expect(throws: SlotMergeError.unexpectedPlayerState("start-up fix not applied")) { try await session.mergeFirmwareSlots() }
        #expect(player.writes == 0)
    }

    @Test func onlyKnownFirmware() {
        #expect(FirmwareSlotMerge.known.keys.sorted() == ["S1.600"])
        // Slot 3's fix appears word for word in the continuation.
        #expect(Array(Self.m.continuation[28..<56]) == Array(Self.m.freeHandler[0..<28]))
    }
}

/// A transport whose bulk reads return the given chunks in order (empty = zero-length packet).
final class ChunkedBulkTransport: USBTransport, @unchecked Sendable {
    var chunks: [[UInt8]]
    init(_ chunks: [[UInt8]]) { self.chunks = chunks }
    func controlOut(request: UInt8, data: [UInt8]) throws {}
    func controlIn(request: UInt8, length: Int) throws -> [UInt8] { [0, 0, 0, 0] }
    func bulkIn(length: Int) throws -> [UInt8] { chunks.isEmpty ? [] : chunks.removeFirst() }
    func bulkOut(_ data: [UInt8]) throws {}
    func close() {}
}

@Suite struct BulkReadTests {
    /// netmd-js keeps reading after a zero-length transfer; SwiftMD used to give up.
    @Test func zeroLengthTransfersAreSkipped() throws {
        let netmd = NetMD(transport: ChunkedBulkTransport([[], [1, 2, 3], [], [], [4, 5]]), vendorID: 0x054c, productID: 0x00c7)
        #expect(try netmd.readBulk(length: 5) == [1, 2, 3, 4, 5])
    }
}
