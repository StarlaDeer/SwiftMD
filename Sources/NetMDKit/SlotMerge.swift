// Making room for bulk backups on players whose firmware fills its own patch slots.
//
// The MZ-N910 (S1.600) loads four fixes of its own into patch slots 0-3 at start-up, and HFEC sits
// in slot 5, leaving three free slots; bulk download needs four. Slots 2 and 3 are a pair of traps
// 16 bytes apart in one routine (0x599FC, which packs a per-disc memory record before it's saved).
// While a bulk backup runs, SwiftMD makes Sony's slot 2 handler do both fixes: its final "return"
// becomes a branch to a continuation in the unused slot 6-7 handler space, which runs the
// firmware's instructions between the two traps, then Sony's slot 3 fix word for word, then returns
// past the slot 3 trap. Slot 3 is then free; afterwards everything is put back and read back.
//
// Tools/n910-slot-merge has the assembly and a simulator that runs Sony's two-trap path and the
// merged path on the N910's real firmware and RAM bytes and requires identical results.
// See docs/n910-patch-slots.md. Nothing here touches the EEPROM or the firmware; unplugging the
// player resets all of it.

import Foundation

struct FirmwareSlotMerge: Sendable {
    /// A firmware fix that only runs once, during start-up, so its slot can be lent out after
    /// start-up. `effect` is what the fix leaves behind, checked to be sure start-up has run.
    struct StartupOnlySlot: Sendable {
        let slot: Int
        let patch: (address: Int, data: [UInt8])
        let effect: (address: Int, value: [UInt8])
    }

    let startupOnly: StartupOnlySlot?
    let keepSlot: Int
    let freeSlot: Int
    let keepPatch: (address: Int, data: [UInt8])
    let freePatch: (address: Int, data: [UInt8])
    /// Sony's handlers in RAM, as loaded at start-up (40 bytes each).
    let keepHandlerAddress: Int
    let keepHandler: [UInt8]
    let freeHandlerAddress: Int
    let freeHandler: [UInt8]
    /// The word in the kept handler that becomes a branch to the continuation.
    let returnWordAddress: Int
    let branchWord: [UInt8]
    /// Where the continuation goes (unused handler space), and how much of it must be empty.
    let continuationAddress: Int
    let emptySpace: Int
    let continuation: [UInt8]

    var originalReturnWord: [UInt8] {
        let offset = returnWordAddress - keepHandlerAddress
        return Array(keepHandler[offset..<offset + 4])
    }

    static let known: [String: FirmwareSlotMerge] = [
        "S1.600": FirmwareSlotMerge(
            // Slot 4 patches 0xBB14 (movs r0, #0x4a; strb r0, [r1]) in 0xBB0C, which is reached only
            // from the reset handler (0xA4 -> 0x8B110 -> 0x7BFD0 -> 0x5A0E0 -> 0x9F94 -> 0xBB0C) and
            // stores 0x4A to 0x0200015E. See docs/n910-patch-slots.md.
            startupOnly: StartupOnlySlot(slot: 4, patch: (0x0000_bb14, [0x4a, 0x20, 0x08, 0x70]),
                                         effect: (0x0200_015e, [0x4a])),
            keepSlot: 2, freeSlot: 3,
            keepPatch: (0x0005_9ab8, [0x61, 0x72, 0x00, 0xde]), // strb r1, [r4, #9]; udf
            freePatch: (0x0005_9ac8, [0xe0, 0x72, 0x00, 0xde]), // strb r0, [r4, #0xb]; udf
            keepHandlerAddress: 0x0200_2bf0,
            keepHandler: [
                0x12, 0x00, 0xd7, 0xe5, 0x11, 0x10, 0xd7, 0xe5, 0x00, 0x02, 0xb0, 0xe1, 0x01, 0x1e, 0xb0, 0xe1,
                0x21, 0x1e, 0xb0, 0xe1, 0x01, 0x00, 0x90, 0xe1, 0x0a, 0x00, 0xc4, 0xe5, 0x00, 0x5f, 0xbd, 0xe8,
                0x0e, 0xf0, 0xb0, 0xe1, 0x00, 0x00, 0x00, 0x00,
            ],
            freeHandlerAddress: 0x0200_2c18,
            freeHandler: [
                0x16, 0x00, 0xd7, 0xe5, 0x15, 0x10, 0xd7, 0xe5, 0x00, 0x02, 0xb0, 0xe1, 0x01, 0x1e, 0xb0, 0xe1,
                0x21, 0x1e, 0xb0, 0xe1, 0x01, 0x00, 0x90, 0xe1, 0x0c, 0x00, 0xc4, 0xe5, 0x00, 0x5f, 0xbd, 0xe8,
                0x0e, 0xf0, 0xb0, 0xe1, 0x00, 0x00, 0x00, 0x00,
            ],
            returnWordAddress: 0x0200_2c0c, // pop {r8-r12, lr} in the slot 2 handler
            branchWord: [0x1f, 0x00, 0x00, 0xea], // b 0x02002c90
            continuationAddress: 0x0200_2c90, // slot 6 and 7 handler space
            emptySpace: 80,
            continuation: [
                // The firmware's Thumb code between the traps (0x59ABC-0x59AC9), in ARM
                0x14, 0x00, 0xd7, 0xe5, // ldrb r0, [r7, #0x14]
                0x13, 0x20, 0xd7, 0xe5, // ldrb r2, [r7, #0x13]
                0x00, 0x02, 0xb0, 0xe1, // lsls r0, r0, #4
                0x02, 0x2e, 0xb0, 0xe1, // lsls r2, r2, #28
                0x22, 0x2e, 0xb0, 0xe1, // lsrs r2, r2, #28
                0x02, 0x00, 0x90, 0xe1, // orrs r0, r0, r2
                0x0b, 0x00, 0xc4, 0xe5, // strb r0, [r4, #0xb]
                // Sony's slot 3 fix, word for word
                0x16, 0x00, 0xd7, 0xe5, 0x15, 0x10, 0xd7, 0xe5, 0x00, 0x02, 0xb0, 0xe1, 0x01, 0x1e, 0xb0, 0xe1,
                0x21, 0x1e, 0xb0, 0xe1, 0x01, 0x00, 0x90, 0xe1, 0x0c, 0x00, 0xc4, 0xe5,
                // Return past the slot 3 trap
                0x00, 0x5f, 0xbd, 0xe8, // pop {r8-r12, lr}
                0x10, 0xe0, 0x8e, 0xe2, // add lr, lr, #0x10
                0x0e, 0xf0, 0xb0, 0xe1, // movs pc, lr
            ]
        ),
    ]
}

public enum SlotMergeError: Error, Equatable, CustomStringConvertible {
    case unexpectedPlayerState(String)
    case readBackMismatch(String)
    case restoreFailed(String)

    public var description: String {
        switch self {
        case .unexpectedPlayerState(let what):
            return "The player isn't in the state SwiftMD expects (\(what)), so nothing was changed. Unplug it for a moment and try again."
        case .readBackMismatch(let what):
            return "A change didn't read back correctly (\(what)). SwiftMD put things back; unplug the player for a moment to be sure."
        case .restoreFailed(let what):
            return "Couldn't put the player's own fixes back (\(what)). Unplug the player for a moment: that restores them."
        }
    }
}

extension ExploitSession {
    /// Whether this firmware can free a slot for bulk backups this way.
    public var canMergeFirmwareSlots: Bool { FirmwareSlotMerge.known[version] != nil }

    func readMemory(_ address: Int, _ length: Int) async throws -> [UInt8] {
        var out: [UInt8] = []
        var offset = 0
        while offset < length {
            let n = min(0x10, length - offset)
            out += try await factory.cleanRead(address: address + offset, length: n, type: .mapped)
            offset += n
        }
        return out
    }

    func patchSlotState(_ slot: Int) async throws -> (enabled: Bool, address: Int, data: [UInt8]) {
        let control = try await factory.cleanRead(address: patchBase.rawValue + slot * 0x10, length: 4, type: .mapped)
        let patch = try await factory.readPatch(slot, base: patchBase)
        return (control[0] & 1 == 1, patch.address, patch.data)
    }

    /// Frees one of the firmware's own patch slots for the length of this session (see above).
    /// Checks the player first and changes nothing unless everything is exactly as expected.
    func mergeFirmwareSlots() async throws {
        guard let m = FirmwareSlotMerge.known[version], mergedSlots == nil else { return }

        // 1. Check: both of Sony's patches in place and switched on, handlers as loaded at start-up,
        //    the continuation space empty.
        let keep = try await patchSlotState(m.keepSlot)
        let free = try await patchSlotState(m.freeSlot)
        guard keep.enabled, keep.address == m.keepPatch.address, keep.data == m.keepPatch.data else {
            throw SlotMergeError.unexpectedPlayerState("slot \(m.keepSlot)")
        }
        guard free.enabled, free.address == m.freePatch.address, free.data == m.freePatch.data else {
            throw SlotMergeError.unexpectedPlayerState("slot \(m.freeSlot)")
        }
        guard try await readMemory(m.keepHandlerAddress, m.keepHandler.count) == m.keepHandler,
              try await readMemory(m.freeHandlerAddress, m.freeHandler.count) == m.freeHandler else {
            throw SlotMergeError.unexpectedPlayerState("fix code in RAM")
        }
        guard try await readMemory(m.continuationAddress, m.emptySpace).allSatisfy({ $0 == 0 }) else {
            throw SlotMergeError.unexpectedPlayerState("handler space in use")
        }
        if let lent = m.startupOnly {
            let state = try await patchSlotState(lent.slot)
            guard state.enabled, state.address == lent.patch.address, state.data == lent.patch.data else {
                throw SlotMergeError.unexpectedPlayerState("slot \(lent.slot)")
            }
            guard try await readMemory(lent.effect.address, lent.effect.value.count) == lent.effect.value else {
                throw SlotMergeError.unexpectedPlayerState("start-up fix not applied")
            }
        }
        log("[SlotMerge] Player matches; merging slot \(m.freeSlot)'s fix into slot \(m.keepSlot)")

        mergedSlots = m // From here on, restoreFirmwareSlots puts everything back.
        do {
            // 2. Put the continuation in place (unreachable until the branch is written), check it.
            try await factory.writeOfAnyLength(address: m.continuationAddress, data: m.continuation, type: .mapped)
            guard try await readMemory(m.continuationAddress, m.continuation.count) == m.continuation else {
                throw SlotMergeError.readBackMismatch("continuation")
            }
            // 3. Point slot 2's handler at it. From here a slot 2 trap does both fixes and returns past
            //    the slot 3 trap, so slot 3 is never reached.
            try await factory.cleanWrite(address: m.returnWordAddress, data: m.branchWord, type: .mapped)
            guard try await readMemory(m.returnWordAddress, 4) == m.branchWord else {
                throw SlotMergeError.readBackMismatch("branch")
            }
            // 4. Switch slot 3 off and hand it out.
            try await factory.unpatch(number: m.freeSlot, totalPatches: maxPatches, base: patchBase)
            guard try await patchSlotState(m.freeSlot).enabled == false else {
                throw SlotMergeError.readBackMismatch("slot \(m.freeSlot) switch")
            }
            freePatches.append(m.freeSlot)
            // 5. Lend out the start-up-only slot: its fix has already run and can't run again before
            //    the next power-on, which reloads it.
            if let lent = m.startupOnly {
                try await factory.unpatch(number: lent.slot, totalPatches: maxPatches, base: patchBase)
                guard try await patchSlotState(lent.slot).enabled == false else {
                    throw SlotMergeError.readBackMismatch("slot \(lent.slot) switch")
                }
                freePatches.append(lent.slot)
            }
            freePatches.sort()
            log("[SlotMerge] Slots \(([m.freeSlot] + (m.startupOnly.map { [$0.slot] } ?? [])).sorted()) are free for this session")
        } catch {
            try? await restoreFirmwareSlots()
            throw error
        }
    }

    /// Puts the firmware's own fixes back exactly as they were, and reads them back.
    func restoreFirmwareSlots() async throws {
        guard let m = mergedSlots else { return }
        freePatches.removeAll { $0 == m.freeSlot || $0 == m.startupOnly?.slot }
        if let lent = m.startupOnly {
            if try await patchSlotState(lent.slot) != (true, lent.patch.address, lent.patch.data) {
                try await factory.patch(address: lent.patch.address, value: lent.patch.data, number: lent.slot,
                                        totalPatches: maxPatches, base: patchBase)
            }
            guard try await patchSlotState(lent.slot) == (true, lent.patch.address, lent.patch.data) else {
                throw SlotMergeError.restoreFailed("slot \(lent.slot)")
            }
        }
        // Slot 3 first: with both its trap and the merged slot 2 active, slot 2 still returns past
        // slot 3's trap, so every order is consistent.
        if try await patchSlotState(m.freeSlot) != (true, m.freePatch.address, m.freePatch.data) {
            try await factory.patch(address: m.freePatch.address, value: m.freePatch.data, number: m.freeSlot,
                                    totalPatches: maxPatches, base: patchBase)
        }
        guard try await patchSlotState(m.freeSlot) == (true, m.freePatch.address, m.freePatch.data) else {
            throw SlotMergeError.restoreFailed("slot \(m.freeSlot)")
        }
        try await factory.cleanWrite(address: m.returnWordAddress, data: m.originalReturnWord, type: .mapped)
        try await factory.writeOfAnyLength(address: m.continuationAddress, data: [UInt8](repeating: 0, count: m.emptySpace), type: .mapped)
        guard try await readMemory(m.keepHandlerAddress, m.keepHandler.count) == m.keepHandler,
              try await readMemory(m.continuationAddress, m.emptySpace).allSatisfy({ $0 == 0 }) else {
            throw SlotMergeError.restoreFailed("fix code in RAM")
        }
        mergedSlots = nil
        log("[SlotMerge] Restored the firmware's own fixes")
    }
}
