// Disc backup: copies ATRAC audio off a NetMD portable. Ports of netmd-exploits (GPL-2.0, by
// asivery and contributors):
// - exploit-state.ts (ExploitStateManager): patch-slot bookkeeping
// - usb-code-execution.ts: one patch makes a USB command run code that SwiftMD sends
// - wait-for-disc-spinning.ts
// - atrac-recovery/cached-sector-noram-transfers.ts: reads cached sectors out of the player's DRAM
// - atrac-recovery/atrac-recovery-interface.ts: walks a track's sectors, re-seeking as the cache runs out
// and of netmd-tocmanip's UTOC parser and netmd-js's AEA / WAV headers.
//
// The disc is only read. Patches and code live in patch slots and RAM, which clear on reset.

import Foundation

// MARK: - UTOC (netmd-tocmanip)

public struct DiscAddress: Sendable, Equatable {
    public var cluster: Int
    public var sector: Int
    public var group: Int

    init(_ b: ArraySlice<UInt8>) {
        let b0 = Int(b[b.startIndex]), b1 = Int(b[b.startIndex + 1]), b2 = Int(b[b.startIndex + 2])
        cluster = (b0 << 6) | (b1 >> 2)
        sector = ((b1 & 0b11) << 4) | (b2 >> 4)
        group = b2 & 0b1111
    }

    public var logical: Int { sector + cluster * 32 }
}

struct UTOC {
    enum ModeFlag {
        static let stereo = 0x2
        static let spMode = 0x4
    }

    struct Fragment {
        var start: DiscAddress
        var mode: Int
        var end: DiscAddress
        var link: Int
    }

    var trackMap: [Int] = []
    var fragments: [Fragment] = []
    var titleMap: [Int] = []
    var titleCells: [(title: [UInt8], link: Int)] = []

    init(sector0: [UInt8]? = nil, sector1: [UInt8]? = nil) {
        if let s = sector0 {
            trackMap = (0..<256).map { Int(s[0x30 + $0]) }
            fragments = (0..<256).map { i in
                let o = 0x130 + i * 8
                return Fragment(start: DiscAddress(s[o..<o + 3]), mode: Int(s[o + 3]), end: DiscAddress(s[o + 4..<o + 7]), link: Int(s[o + 7]))
            }
        }
        if let s = sector1 {
            titleMap = (0..<256).map { Int(s[0x30 + $0]) }
            titleCells = (0..<256).map { i in
                let o = 0x130 + i * 8
                return (Array(s[o..<o + 7]), Int(s[o + 7]))
            }
        }
    }

    /// Port of getTitleByTrackNumber (half-width).
    func title(track: Int) -> String {
        var cell = titleMap[track]
        var depth = 0
        var flat: [UInt8] = []
        while cell != 0 {
            if depth > 10 { flat += Array("...".utf8); break }
            flat += titleCells[cell].title
            cell = titleCells[cell].link
            depth += 1
        }
        if let zero = flat.firstIndex(of: 0) { flat = Array(flat[..<zero]) }
        return String(decoding: flat, as: UTF8.self)
    }
}

// MARK: - File headers (netmd-js utils)

private func le(_ value: Int, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
}

/// AEA header for ATRAC1 (SP) data. Port of netmd-js createAeaHeader.
func aeaHeader(name: String, channels: Int, soundgroups: Int) -> [UInt8] {
    var header = le(2048, 4)
    let encoded = Array(name.utf8.prefix(256))
    header += encoded + [UInt8](repeating: 0, count: 256 - encoded.count)
    header += le(soundgroups, 4) + [UInt8(channels), 0]
    for _ in 0..<8 { header += le(0, 4) } // flags
    header += le(0, 4) + le(0, 4) + le(0, 4) // reserved, encrypted, groupstart
    return header + [UInt8](repeating: 0, count: 2048 - header.count)
}

/// WAV header around ATRAC3 (LP2 / LP4) data. Port of netmd-js createWavHeader.
func atrac3WavHeader(lp4: Bool, bytes: Int) -> [UInt8] {
    let bytesPerFrame = lp4 ? 96 : 192
    let jointStereo = lp4 ? 1 : 0
    let bytesPerSecond = bytesPerFrame * 44100 / 512
    var h = Array("RIFF".utf8) + le(bytes + 60, 4) + Array("WAVEfmt ".utf8)
    h += le(32, 4) + le(0x270, 2) + le(2, 2) + le(44100, 4) + le(bytesPerSecond, 4) + le(bytesPerFrame * 2, 2) + [0, 0]
    h += le(14, 2) + le(1, 2) + le(bytesPerFrame, 4) + le(jointStereo, 2) + le(jointStereo, 2) + le(1, 2) + le(0, 2)
    return h + Array("data".utf8) + le(bytes, 4)
}

// MARK: - Exploit session (ExploitStateManager)

/// Owns the factory connection and the patch slots while exploits are loaded.
public final class ExploitSession: @unchecked Sendable {
    public let device: NetMDInterface
    public let factory: NetMDFactory
    public let version: String
    public let safety: SafetyPatches.Report
    let maxPatches: Int
    /// Patch slots still free (handed out last first).
    public internal(set) var freePatches: [Int]
    let log: @Sendable (String) -> Void
    /// Sleeps for the given number of milliseconds. Tests replace it.
    var sleep: @Sendable (Int) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) }

    var usbExecution: USBCodeExecution?
    /// Set while the firmware's own fixes are merged to free a slot (SlotMerge.swift).
    var mergedSlots: FirmwareSlotMerge?
    /// Set when code SwiftMD loaded couldn't be removed: from then on it only asks for an unplug.
    var needsReset = false

    /// Port of ExploitStateManager.create: reads the firmware version and loads the safety patches.
    public static func create(device: NetMDInterface, factory: NetMDFactory,
                              log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ExploitSession {
        let version = try await factory.descriptiveDeviceCode()
        // SwiftMD addition: find the slots that hold active patches. Many players load the
        // firmware's own fixes into patch slots at start-up (the MZ-N910 uses slots 0-3, the MZ-N707
        // 0-2); netmd-exploits would hand those slots out and overwrite the fixes.
        let inUse = try await activePatchSlots(factory: factory, version: version)
        if !inUse.isEmpty { log("[StateManager] Patch slots in use by the firmware: \(inUse.sorted())") }
        var report = try await SafetyPatches.load(on: factory, version: version, inUse: inUse) { log("[StateManager] \($0)") }
        // Only switched-off slots are free. This also frees slots that only look like developer
        // patches because an earlier session left its (disabled) patch address behind.
        if let total = SafetyPatches.maxPatches(for: version) {
            report.freePatches = (0..<total).filter { !inUse.contains($0) && $0 != report.hfecLoadedAt }
        }
        return ExploitSession(device: device, factory: factory, version: version, safety: report, log: log)
    }

    /// Slots whose patch is switched on (bit 0 of the slot's control word). Read-only.
    public static func activePatchSlots(factory: NetMDFactory, version: String) async throws -> Set<Int> {
        guard let total = SafetyPatches.maxPatches(for: version) else { return [] }
        let base: PatchPeripheralBase = version.hasPrefix("H") ? .himd : .netmd
        var active: Set<Int> = []
        for i in 0..<total {
            let control = try await factory.cleanRead(address: base.rawValue + i * 0x10, length: 4, type: .mapped)
            if control[0] & 1 == 1 { active.insert(i) }
        }
        return active
    }

    init(device: NetMDInterface, factory: NetMDFactory, version: String, safety: SafetyPatches.Report,
         log: @escaping @Sendable (String) -> Void) {
        self.device = device
        self.factory = factory
        self.version = version
        self.safety = safety
        self.maxPatches = SafetyPatches.maxPatches(for: version) ?? 0
        self.freePatches = safety.freePatches
        self.log = log
    }

    var isTypeR: Bool { version.hasPrefix("R") }
    var patchBase: PatchPeripheralBase { version.hasPrefix("H") ? .himd : .netmd }

    /// Loads a patch into the next free slot and returns the slot.
    func patch(address: Int, value: [UInt8]) async throws -> Int {
        guard let slot = freePatches.popLast() else {
            throw ExploitError.patchMemoryFull(maxPatches)
        }
        try await factory.patch(address: address, value: value, number: slot, totalPatches: maxPatches, base: patchBase)
        return slot
    }

    func unpatch(_ slot: Int) async throws {
        try await factory.unpatch(number: slot, totalPatches: maxPatches, base: patchBase)
        freePatches.append(slot)
    }

    /// Hands out a patch slot for code that loads its own patches (getIncrementalPatchNumber).
    func reservePatchSlot() throws -> Int {
        guard let slot = freePatches.popLast() else { throw ExploitError.patchMemoryFull(maxPatches) }
        return slot
    }

    /// Returns a slot whose patch was removed by other means (freePatch).
    func releasePatchSlot(_ slot: Int) {
        if !freePatches.contains(slot) { freePatches.append(slot) }
    }

    /// USB code execution, loaded on first use (ExploitStateManager.require).
    func codeExecution() async throws -> USBCodeExecution {
        if let usbExecution { return usbExecution }
        let exec = try USBCodeExecution(session: self)
        try await exec.load()
        usbExecution = exec
        return exec
    }

    /// Removes SwiftMD's patches. (ElectronWMD leaves the code-execution patch in place until the
    /// player resets; SwiftMD takes it out when it's done.)
    /// If anything can't be taken out cleanly, it stops there and asks for the player to be
    /// unplugged rather than changing more: a reset undoes everything, as it's all in RAM.
    public func close() async throws {
        if needsReset { throw ExploitError.needsUnplug("an earlier step failed") }
        if let usbExecution {
            do {
                try await usbExecution.unload()
            } catch {
                needsReset = true
                throw ExploitError.needsUnplug(String(describing: error))
            }
            self.usbExecution = nil
        }
        try await restoreFirmwareSlots()
    }

    /// Port of WaitForDiscToStopSpinning.wait.
    func waitForDiscToStopSpinning() async throws {
        let maxWait = 20000
        guard !isTypeR, !version.hasPrefix("H"), let address = versionStoreLookup(ExploitPayloads.discSpinState, version: version) else {
            try await sleep(maxWait)
            return
        }
        let start = ContinuousClock.now
        try await factory.changeMemoryState(address: address, length: 1, type: .mapped, state: .read)
        while true {
            let state = try await factory.read(address: address, length: 1, type: .mapped)[0]
            if (state >> 4) & 1 != 0 || ContinuousClock.now - start > .milliseconds(maxWait) { break }
            try await sleep(500)
        }
        try await factory.changeMemoryState(address: address, length: 1, type: .mapped, state: .close)
        log("[WaitForDiscToStopSpinning] Had to wait \((ContinuousClock.now - start).components.seconds) s")
    }
}

extension ExploitError {
    static func patchMemoryFull(_ n: Int) -> ExploitError { .unsupportedFirmware("patch memory full (\(n) slots)") }
}

extension NetMDInterface {
    /// Sends a raw command on the normal channel and reads exactly `replyLength` bytes, with no
    /// status checks. Code execution answers "not implemented", which sendQuery would reject.
    func sendRawCommand(_ command: [UInt8], replyLength: Int) async throws -> [UInt8] {
        await lock()
        defer { unlock() }
        try netMD.sendCommand(command)
        return try await netMD.readReply(overrideLength: replyLength)
    }

    /// Reads `length` bytes from the bulk IN endpoint.
    func readBulkData(length: Int) async throws -> [UInt8] {
        await lock()
        defer { unlock() }
        return try netMD.readBulk(length: length)
    }
}

// MARK: - USB code execution

final class USBCodeExecution: @unchecked Sendable {
    static let onePatchAddress: [String: Int] = [
        "S1.600": 0x0000_e69c, "S1.500": 0x0000_e538, "S1.400": 0x0000_e4c4, "S1.300": 0x0000_daa8,
        "S1.200": 0x0000_d834, "S1.100": 0x0000_d784, "S1.000": 0x0000_e784,
        "R1.000": 0x0005_6228, "R1.100": 0x0005_6aac, "R1.200": 0x0005_77f8, "R1.300": 0x0005_7b48, "R1.400": 0x0005_7be8,
    ]
    static let onePatchValue: [String: [UInt8]] = [
        "S1.600,S1.500,S1.400,S1.300,S1.200,S1.100,S1.000": [0x13, 0x48, 0x00, 0x47], // ldr r0, [pc, #0x4c]; bx r0
        "R1.400,R1.300,R1.200,R1.100,R1.000": [0x1a, 0x48, 0x00, 0x47], // ldr r0, [pc, #0x68]; bx r0
    ]
    static let command: [String: UInt8] = ["S*": 0xd2, "R*": 0xd3]

    let session: ExploitSession
    let address: Int
    let value: [UInt8]
    let commandByte: UInt8
    private(set) var slot: Int?

    init(session: ExploitSession) throws {
        guard let address = versionStoreLookup(Self.onePatchAddress, version: session.version),
              let value = versionStoreLookup(Self.onePatchValue, version: session.version),
              let command = versionStoreLookup(Self.command, version: session.version) else {
            throw ExploitError.unsupportedFirmware(session.version)
        }
        self.session = session
        self.address = address
        self.value = value
        self.commandByte = command
    }

    func load() async throws {
        // Check if the device has already been patched (f. ex. hard-patch):
        // mov r0, #1; strb r0, [pc]; bx lr, followed by the byte it sets.
        let probe: [UInt8] = [0x01, 0x00, 0xa0, 0xe3, 0x00, 0x00, 0xcf, 0xe5, 0x1e, 0xff, 0x2f, 0xe1]
        let reply = try await execute(probe + [0x00])
        guard reply.count == probe.count + 1, Array(reply.prefix(probe.count)) == probe else {
            throw QueryError.badFormat("Unexpected code execution probe reply")
        }
        if reply[probe.count] == 0 {
            slot = try await session.patch(address: address, value: value)
            session.log("[USBCodeExecution] Reserved patch \(slot!)")
        }
    }

    func unload() async throws {
        if let slot {
            try await session.unpatch(slot)
            session.log("[USBCodeExecution] Released patch \(slot)")
            self.slot = nil
        }
    }

    /// Runs `code` on the player and returns the code buffer as the player left it.
    func execute(_ code: [UInt8], replyLength: Int? = nil) async throws -> [UInt8] {
        let query: [UInt8] = [0x00, 0x18, commandByte, 0xff] + code
        let reply = try await session.device.sendRawCommand(query, replyLength: replyLength ?? query.count + 1)
        guard reply.count >= 4, reply[0] == 0x08, reply[1] == 0x18, reply[3] == 0xff else {
            throw QueryError.badFormat("Unexpected code execution reply \(NetMD.hex(Array(reply.prefix(8))))")
        }
        return Array(reply[4...])
    }
}

// MARK: - Sector source

/// Where cached sectors come from (netmd-exploits AtracRecovery's abstract methods).
protocol CachedSectorReader: AnyObject {
    /// Loads whatever the reader needs on the player (ExploitStateManager.require → init).
    func load() async throws
    /// Removes it again (unload).
    func unload() async throws
    func readNextSector() async throws -> [UInt8]
    func setSectorToRead(_ sector: Int, sectorsRemaining: Int) async throws
    func startDownload(track: Int) async throws
    func finishDownload() async throws
}

/// CachedSectorNoRamControlDownload: reads each 2352-byte sector in pieces through control transfers.
final class NoRamSectorReader: CachedSectorReader {
    let session: ExploitSession
    let payload: ExploitPayloads.NoRamDownload
    var currentTrack = -1
    var sector = 0

    init(session: ExploitSession) throws {
        guard let payload = ExploitPayloads.noRamDownload[session.version] else {
            throw ExploitError.unsupportedFirmware(session.version)
        }
        self.session = session
        self.payload = payload
    }

    func load() async throws {} // Code execution loads on the first read, as in netmd-exploits.
    func unload() async throws {}

    func readNextSector() async throws -> [UInt8] {
        guard currentTrack != -1 else { throw QueryError.badFormat("You need to startDownload() first") }
        let exec = try await session.codeExecution()
        var result: [UInt8] = []
        var remaining = 2352
        // netmd-exploits reads 512 - 8 - codeLength (420) bytes at a time. Type-S firmware copies its
        // buffer in 8-byte units, so a piece starting 4 bytes past an 8-byte boundary comes back with
        // every other word shifted (found on an MZ-N910, S1.600, against the same disc on an MZ-N505).
        // SwiftMD keeps Type-S pieces 8-byte aligned; Type-R keeps netmd-exploits' size.
        var maxPiece = 512 - 8 - payload.codeLength
        if !session.isTypeR { maxPiece &= ~7 }
        while remaining > 0 {
            let length = min(remaining, maxPiece)
            let code = payload.template + le(sector, 4) + le(2352 - remaining, 4) + le(length, 4)
            let full = try await exec.execute(code, replyLength: length + payload.codeLength + 4)
            let part = Array(full.dropFirst(payload.codeLength))
            result += part
            remaining -= part.count
            if part.isEmpty { throw QueryError.truncated(format: "cached sector") }
        }
        sector += 1
        return result
    }

    func setSectorToRead(_ sector: Int, sectorsRemaining: Int) async throws {
        self.sector = sector
    }

    func startDownload(track: Int) async throws {
        if !session.isTypeR { try await session.factory.display("ACCESS", blink: true) }
        currentTrack = track
    }

    func finishDownload() async throws {
        if !session.isTypeR { try await session.factory.setDisplayMode(.default) }
        currentTrack = -1
    }
}

/// CachedSectorBulkDownload (Type-S): resident code streams cached sectors over bulk USB, 900 at a
/// time, each padded to 2432 bytes. The non-ATRAC bulk transfer code was written by Sir68k.
final class BulkSectorReader: CachedSectorReader {
    static let sectorLength = 2432
    static let sectorsPerLoad = 900

    let session: ExploitSession
    let payload: ExploitPayloads.BulkDownload
    var slots: [Int] = []
    var currentTrack = -1
    var cached: [UInt8] = []
    var cachedPointer = 0
    var currentSector = 0
    var sectorsRemaining = 0

    init(session: ExploitSession) throws {
        guard let payload = ExploitPayloads.bulkDownload[session.version] else {
            throw ExploitError.unsupportedFirmware(session.version)
        }
        self.session = session
        self.payload = payload
    }

    func withSlots(_ template: [UInt8], _ offsets: [Int]) -> [UInt8] {
        var code = template
        for (offset, slot) in zip(offsets, slots) { code[offset] = UInt8(slot) }
        return code
    }

    func load() async throws {
        // Check before changing anything: three slots for this, one for code execution.
        let needed = session.usbExecution == nil ? 4 : 3
        if session.freePatches.count < needed && session.canMergeFirmwareSlots {
            // Short of slots (the MZ-N910): free some of the firmware's own for this session.
            try await session.mergeFirmwareSlots()
        }
        guard session.freePatches.count >= needed else {
            throw ExploitError.notEnoughPatchSlots(needed: needed, free: session.freePatches.count)
        }
        let factory = session.factory
        try await factory.writeOfAnyLength(address: payload.prepAddress, data: payload.prepCode, type: .mapped)
        session.log("[CachedSectorBulkDownload] Prep OK!")
        slots = [try session.reservePatchSlot(), try session.reservePatchSlot(), try session.reservePatchSlot()]
        session.log("[CachedSectorBulkDownload] Reserved patches \(slots)")
        do {
            try await factory.writeOfAnyLength(address: payload.residentAddress, data: payload.residentCode, type: .mapped)
            session.log("[CachedSectorBulkDownload] Resident OK!")
            let exec = try await session.codeExecution()
            _ = try await exec.execute(withSlots(payload.initTemplate, payload.initSlotOffsets))
            session.log("[CachedSectorBulkDownload] Init OK!")
        } catch {
            // SwiftMD addition. Only init patches anything; it needs code execution. Without it
            // nothing was patched, so just hand the slots back.
            guard session.usbExecution != nil else {
                for slot in slots { session.releasePatchSlot(slot) }
                slots = []
                throw error
            }
            // Init may have hooked the USB handler before failing, so run its cleanup code
            // (harmless if it hadn't). If even that fails, only an unplug is safe.
            do {
                try await unload()
            } catch {
                session.needsReset = true
                throw ExploitError.needsUnplug(String(describing: error))
            }
            throw error
        }
    }

    func unload() async throws {
        guard !slots.isEmpty else { return }
        // The init code patched the USB handler itself, so its own cleanup code removes the patches.
        let exec = try await session.codeExecution()
        _ = try await exec.execute(withSlots(payload.cleanupTemplate, payload.cleanupSlotOffsets))
        for slot in slots { session.releasePatchSlot(slot) }
        slots = []
    }

    func reloadBuffer(_ count: Int) async throws {
        let factory = session.factory
        try await factory.cleanWrite(address: payload.sectorStartAddress, data: le(currentSector, 4), type: .mapped)
        try await factory.cleanWrite(address: payload.sectorEndAddress, data: le(currentSector + count, 4), type: .mapped)
        session.log("[CachedSectorBulkDownload] Set boundaries to \(currentSector) -> \(currentSector + count)")
        _ = try await session.codeExecution().execute(payload.prepLoader)
        cachedPointer = 0
        do {
            cached = try await session.device.readBulkData(length: count * Self.sectorLength)
        } catch {
            // The player's streaming code waits for the Mac to read and ignores commands meanwhile,
            // so SwiftMD can't tidy up; unplugging resets it.
            throw ExploitError.bulkTransferFailed(String(describing: error))
        }
    }

    func readNextSector() async throws -> [UInt8] {
        guard currentTrack != -1 else { throw QueryError.badFormat("You need to startDownload() first") }
        if cachedPointer >= cached.count {
            try await reloadBuffer(min(sectorsRemaining, Self.sectorsPerLoad))
        }
        let end = min(cachedPointer + 2352, cached.count)
        let slice = cachedPointer < end ? Array(cached[cachedPointer..<end]) : []
        currentSector += 1
        cachedPointer += Self.sectorLength
        return slice
    }

    func setSectorToRead(_ sector: Int, sectorsRemaining: Int) async throws {
        guard currentTrack != -1 else { throw QueryError.badFormat("You need to startDownload() first") }
        currentSector = sector
        self.sectorsRemaining = sectorsRemaining
        cachedPointer = cached.count + 1 // Force a reload on the next sector
    }

    func startDownload(track: Int) async throws { currentTrack = track }
    func finishDownload() async throws { currentTrack = -1 }
}

// MARK: - Time conversions (copied from the firmware by netmd-exploits)

struct TimeRepresentation {
    var low: Int32
    var high: Int32
    var type: Int32

    init(seconds: Double) {
        let unk = Int32(truncatingIfNeeded: Int(floor(seconds * 1566 / 100)))
        low = unk & 0b11111
        high = (unk >> 5) & 0xffff
        type = (unk & 1) == 0 ? 0 : 6
    }

    var seconds: Int {
        let unk = Int((high << 5) | low)
        return Int(floor(Double(unk * 100) / 1566))
    }

    mutating func fromLP4() {
        var tempNewHigh = high << 2
        var newHigh = tempNewHigh
        var newType = type * 4
        while 10 < newType { newType -= 0xb } // (the firmware also counts into tempNewLow here, then overwrites it)
        var tempNewLow = ((low >> 1) << 1) * 4
        while 0x1f < tempNewLow {
            tempNewLow -= 0x20
            tempNewHigh += 1
            newHigh = tempNewHigh
        }
        var newLow = tempNewLow
        if 5 < newType { newLow |= 1 }
        type = newType
        low = newLow
        high = newHigh
    }

    mutating func fromLP2Mono() {
        var tempNewHigh = high << 1
        var newHigh = tempNewHigh
        var newType = type * 2
        while 10 < newType { newType -= 0xb }
        var tempNewLow = ((low >> 1) << 1) * 2
        while 0x1f < tempNewLow {
            tempNewLow -= 0x20
            tempNewHigh += 1
            newHigh = tempNewHigh
        }
        var newLow = tempNewLow
        if 5 < newType { newLow |= 1 }
        type = newType
        low = newLow
        high = newHigh
    }
}

/// A sector is ATRAC if, in every 212-byte frame, the block size mode or the block floating unit
/// count is repeated at the frame's end. Like netmd-exploits, frames are counted back from the end
/// of the data, which matters for sectors trimmed at a track boundary.
func isValidATRACSector(_ data: ArraySlice<UInt8>) -> Bool {
    let base = data.startIndex
    var offset = data.count - 212
    while offset >= 0 {
        let start = base + offset
        if data[start] != data[start + 211] && data[start + 1] != data[start + 210] { return false }
        offset -= 212
    }
    return true
}

/// JavaScript `Uint8Array.subarray` index rules: truncation, negatives count from the end, clamped.
private func jsSubarray(_ a: [UInt8], _ begin: Double, _ end: Double? = nil) -> [UInt8] {
    func resolve(_ v: Double) -> Int {
        let t = Int(v.rounded(.towardZero))
        return t < 0 ? max(a.count + t, 0) : min(t, a.count)
    }
    let b = resolve(begin)
    let e = end.map(resolve) ?? a.count
    return b < e ? Array(a[b..<e]) : []
}

// MARK: - ATRAC recovery

public enum TrackFormat: String, Sendable {
    case spStereo = "SPS", spMono = "SPM", lp2 = "LP2", lp4 = "LP4"
}

public struct DownloadedTrack: Sendable {
    public var data: [UInt8]
    /// "aea" (ATRAC1, SP) or "wav" (ATRAC3 in a WAV container, LP2 / LP4).
    public var fileExtension: String
    public var format: TrackFormat
    public var title: String?
    /// False when the transfer stopped early, after too many unreadable sectors in a row.
    public var complete: Bool
}

public struct DownloadProgress: Sendable {
    public enum Action: String, Sendable { case read = "READ", seek = "SEEK", chunk = "CHUNK" }
    public var read: Int
    public var total: Int
    public var action: Action
}

public enum DownloadError: Error, Equatable, CustomStringConvertible {
    case cannotJump
    case cannotAlign

    public var description: String {
        switch self {
        case .cannotJump: return "The player wouldn't move to the next part of the track."
        case .cannotAlign: return "Couldn't line up the player's buffer with what was already read."
        }
    }
}

public final class AtracDownloader: @unchecked Sendable {
    let session: ExploitSession
    let reader: CachedSectorReader

    public enum Method: String, Sendable {
        /// Control transfers, a few hundred bytes at a time. Every Type-S and Type-R.
        case controlTransfers
        /// Bulk USB streaming, much faster. Type-S only. (netmd-exploits' first choice there.)
        case bulk
    }

    public let method: Method
    private var loaded = false

    /// `method` nil picks control transfers, which have been tested on every player here; bulk is
    /// used only when asked for.
    public init(session: ExploitSession, method: Method? = nil) throws {
        self.session = session
        let method = method ?? .controlTransfers
        self.method = method
        switch method {
        case .controlTransfers: self.reader = try NoRamSectorReader(session: session)
        case .bulk: self.reader = try BulkSectorReader(session: session)
        }
    }

    /// Bulk if this player can do it (loading it now), otherwise control transfers. Bulk is only
    /// refused before anything on the player is changed, so falling back is always clean.
    public static func fastest(session: ExploitSession) async throws -> AtracDownloader {
        if supportsBulk(version: session.version) {
            let bulk = try AtracDownloader(session: session, method: .bulk)
            do {
                try await bulk.prepare()
                session.log("[AtracDownloader] Using bulk transfers")
                return bulk
            } catch let error as ExploitError {
                guard case .notEnoughPatchSlots = error else { throw error }
                session.log("[AtracDownloader] Bulk not possible (\(error)); using control transfers")
            } catch let error as SlotMergeError {
                guard case .unexpectedPlayerState = error else { throw error }
                session.log("[AtracDownloader] Bulk not possible (\(error)); using control transfers")
            }
        }
        return try AtracDownloader(session: session, method: .controlTransfers)
    }

    /// Firmware that backups have been tried on with real players: S1.600 (MZ-N910), R1.400 (MZ-N505).
    /// Other versions in netmd-exploits' tables work in Web MiniDisc Pro but need the user's OK here.
    public static let testedFirmware: Set<String> = ["S1.600", "R1.400"]

    /// Whether this firmware supports bulk transfers.
    public static func supportsBulk(version: String) -> Bool { ExploitPayloads.bulkDownload[version] != nil }

    /// Loads the reader on the player (ElectronWMD's prepareDownload). Called by the first download
    /// if not called before.
    public func prepare() async throws {
        guard !loaded else { return }
        try await reader.load()
        loaded = true
    }

    /// Removes the reader from the player (ElectronWMD's finalizeDownload). Call before closing the session.
    public func finish() async throws {
        guard loaded else { return }
        loaded = false
        try await reader.unload()
    }

    /// Diagnostics: seeks to the start of a track, lets the buffer fill, and returns the first
    /// `count` cached sectors exactly as the player holds them (20-byte header + 2332 bytes).
    public func readCachedSectors(track: Int, count: Int) async throws -> [[UInt8]] {
        try await prepare()
        _ = try await session.device.gotoTrack(track)
        try await session.device.gotoTime(track, hour: 0, minute: 0, second: 0)
        try await session.waitForDiscToStopSpinning()
        try await reader.startDownload(track: track)
        try await reader.setSectorToRead(0, sectorsRemaining: count)
        var sectors: [[UInt8]] = []
        do {
            for _ in 0..<count { sectors.append(try await reader.readNextSector()) }
        } catch {
            try? await reader.finishDownload()
            throw error
        }
        try await reader.finishDownload()
        return sectors
    }

    /// Port of AtracRecovery.downloadTrack with the default config. `track` is zero-based.
    public func downloadTrack(_ track: Int, progress: @Sendable (DownloadProgress) -> Void = { _ in },
                              isCancelled: @Sendable () -> Bool = { false }) async throws -> DownloadedTrack {
        let device = session.device
        let factory = session.factory
        let log = session.log
        var output: [UInt8] = []
        var fileExtension = ""
        var trackTitle: String?
        let secondsPerSector = 704.0 / 11025.0

        var nextSectorBeginInclude = 0.0
        try await prepare()

        do {
            let sector0 = try await factory.readUTOCSector(0)
            let toc = UTOC(sector0: sector0)
            let root = toc.fragments[toc.trackMap[track + 1]]
            let stereo = root.mode & UTOC.ModeFlag.stereo != 0
            let sp = root.mode & UTOC.ModeFlag.spMode != 0
            let format: TrackFormat = stereo ? (sp ? .spStereo : .lp2) : (sp ? .spMono : .lp4)

            var sectorsRead = 0
            var allSectors = 0
            var ranges: [(Int, Int)] = []
            var blacklist: [[UInt8]] = []
            var splices: [Int: (start: Int?, end: Int?)] = [:]
            func rawToLogical(_ d: ArraySlice<UInt8>) -> Int {
                let b = d.startIndex
                return ((Int(d[b]) << 8) | Int(d[b + 1])) * 32 + Int(d[b + 2])
            }
            func addFragment(_ f: UTOC.Fragment) {
                let end = f.end.logical, start = f.start.logical
                allSectors += end - start + 1
                ranges.append((start, end))
                splices[start] = (start: f.start.group, end: nil)
                splices[end & ~1] = (start: nil, end: f.end.group)
            }
            func isPartOfThisTrack(_ l: Int) -> Bool { ranges.contains { l >= $0.0 && l <= $0.1 } }
            func addressString(_ raw: ArraySlice<UInt8>) -> String {
                let b = raw.startIndex
                return String(format: "%04x.%02x", (Int(raw[b]) << 8) | Int(raw[b + 1]), Int(raw[b + 2]))
            }

            var last = root
            while last.link != 0 {
                addFragment(last)
                last = toc.fragments[last.link]
            }
            addFragment(last)
            log("[AtracRecovery] Track \(track): \(format.rawValue), sectors \(ranges.map { "\($0.0)-\($0.1)" }.joined(separator: ", "))")

            let amount = allSectors

            if format == .lp2 || format == .lp4 {
                fileExtension = "wav"
                output += atrac3WavHeader(lp4: format == .lp4, bytes: amount * (2332 - 20 * 11))
            } else {
                let sector1 = try await factory.readUTOCSector(1)
                let name = UTOC(sector1: sector1).title(track: track + 1)
                trackTitle = name
                fileExtension = "aea"
                output += aeaHeader(name: name, channels: stereo ? 2 : 1, soundgroups: amount * 11)
            }

            _ = try await device.gotoTrack(track)
            try await device.gotoTime(track, hour: 0, minute: 0, second: 0)
            try await session.waitForDiscToStopSpinning()

            try await reader.startDownload(track: track)
            try await reader.setSectorToRead(0, sectorsRemaining: amount + 2)
            progress(DownloadProgress(read: sectorsRead, total: amount, action: .seek))

            var sector = 0
            var positionsRead: [Int] = []
            var isAfterBlacklist = false
            var alignmentKnockBack = 0.0
            var badSectorCounter = 0
            let maxBadSectors = 15

            mainLoop: while sector < 0xfff && !isCancelled() {
                if sectorsRead >= amount && nextSectorBeginInclude == 0 {
                    log("[AtracRecovery] Dumping complete!")
                    try await reader.finishDownload()
                    return DownloadedTrack(data: output, fileExtension: fileExtension, format: format, title: trackTitle, complete: true)
                }
                let content = try await reader.readNextSector()
                sector += 1

                let metadata = Array(content.prefix(20))
                let position = metadata[12..<15]
                let currentLogical = rawToLogical(position)
                var audio = Array(content.dropFirst(20))
                var wasMitigation = false

                if nextSectorBeginInclude != 0 {
                    audio = jsSubarray(audio, 0, nextSectorBeginInclude)
                    nextSectorBeginInclude = 0
                    wasMitigation = true
                } else if let splice = splices[currentLogical] {
                    var start = Double(splice.start ?? 0)
                    let end = splice.end ?? -1
                    if start >= 5 { start -= 5.5 }
                    let startByte = start * 424
                    let endByte = end == -1 ? Double(audio.count) : Double((end + 1) * 424)
                    if startByte > Double(audio.count) {
                        nextSectorBeginInclude = startByte - Double(audio.count)
                        positionsRead.append(currentLogical)
                        sectorsRead += 1
                        isAfterBlacklist = false
                        continue
                    }
                    if endByte > Double(audio.count) {
                        nextSectorBeginInclude = endByte - Double(audio.count) + startByte
                        audio = jsSubarray(audio, startByte)
                    } else {
                        audio = jsSubarray(audio, startByte, endByte)
                    }
                }

                let invalid = !isValidATRACSector(audio[...]) || (!isPartOfThisTrack(currentLogical) && !wasMitigation)
                    || positionsRead.contains(currentLogical)
                if invalid {
                    if content.count == 2352 && blacklist.contains(metadata) {
                        log("[AtracRecovery] Read sector with metadata block in the blacklist (@\(addressString(position))). It will be skipped.")
                        if isAfterBlacklist {
                            sectorsRead += 1
                            isAfterBlacklist = false
                        }
                        continue
                    }
                    // Past the cached ATRAC data: work out how far into the track we are and seek there.
                    var originalSeconds = Double(sectorsRead) * secondsPerSector - alignmentKnockBack
                    if format != .spStereo {
                        var representation = TimeRepresentation(seconds: originalSeconds)
                        switch format {
                        case .spMono, .lp2: representation.fromLP2Mono()
                        case .lp4: representation.fromLP4()
                        case .spStereo: break
                        }
                        originalSeconds = Double(representation.seconds)
                    }

                    if sector < 100 {
                        // A bad sector; netmd-exploits' default answer is to reload.
                        badSectorCounter += 1
                        if badSectorCounter > maxBadSectors {
                            log("[AtracRecovery] Aborting: \(maxBadSectors) bad sectors in a row, to spare the laser.")
                            try await reader.finishDownload()
                            return DownloadedTrack(data: output, fileExtension: fileExtension, format: format, title: trackTitle, complete: false)
                        }
                    }
                    log("[AtracRecovery] The sector read is not an ATRAC sector. Sectors read previously add up to \(originalSeconds) seconds. Jumping to that time")
                    blacklist.append(metadata)
                    isAfterBlacklist = true

                    var alignmentTries = 0
                    var thisKnockBack = 0.0
                    while true {
                        var seconds = originalSeconds - thisKnockBack
                        let hours = floor(seconds / 3600)
                        seconds -= hours * 3600
                        let minutes = floor(seconds / 60)
                        seconds -= minutes * 60
                        log("[AtracRecovery] Jumping to \(Int(hours)):\(Int(minutes)):\(seconds) (knockback: \(thisKnockBack) + \(alignmentKnockBack))")
                        progress(DownloadProgress(read: sectorsRead, total: amount, action: .seek))

                        try await reader.finishDownload()
                        try await session.sleep(1000)
                        try await device.stop()
                        var tries = 0
                        while true {
                            do {
                                // %B sends whole seconds, as netmd-js's BCD conversion drops the fraction.
                                try await device.gotoTime(track, hour: Int(hours), minute: Int(minutes), second: Int(floor(seconds)))
                                break
                            } catch {
                                log("[AtracRecovery] While jumping: \(error)")
                                if tries > 5 { throw DownloadError.cannotJump }
                                tries += 1
                                try await session.sleep(1000)
                            }
                        }
                        try await device.stop()
                        try await session.waitForDiscToStopSpinning()
                        try await reader.startDownload(track: track)
                        try await reader.setSectorToRead(0, sectorsRemaining: 1)

                        let sync = try await reader.readNextSector()
                        let syncLogical = rawToLogical(sync[12..<15])
                        log("[AtracRecovery] After moving the head, position is \(addressString(sync[12..<15]))")

                        // How many sectors back from the newest one read the player's buffer now starts.
                        let alignment = positionsRead.lastIndex(of: syncLogical).map { positionsRead.count - $0 } ?? -1

                        if alignment == -1 {
                            if alignmentTries < 3 {
                                alignmentTries += 1
                                thisKnockBack += 2
                                continue
                            }
                            log("[AtracRecovery] Could not align! originalSeconds=\(originalSeconds) knockback=\(thisKnockBack)+\(alignmentKnockBack)")
                            try await reader.finishDownload()
                            throw DownloadError.cannotAlign
                        }
                        sector = 0
                        alignmentTries = 0
                        log("[AtracRecovery] Aligned! Running \(alignment) sectors behind!")
                        try await reader.setSectorToRead(alignment, sectorsRemaining: amount - sectorsRead + 2)
                        alignmentKnockBack += thisKnockBack
                        break
                    }
                    continue mainLoop
                }

                // A valid ATRAC sector.
                badSectorCounter = 0
                positionsRead.append(currentLogical)
                if format == .lp2 || format == .lp4 {
                    // Remove the SP compatibility bytes: 12 zero bytes at the start of each frame and 8 at the end.
                    for frame in stride(from: 10, through: 0, by: -1) {
                        let start = frame * 212
                        jsSplice(&audio, start + 212 - 8, 8)
                        jsSplice(&audio, start, 12)
                    }
                }
                output += audio
                sectorsRead += 1
                isAfterBlacklist = false
                progress(DownloadProgress(read: sectorsRead, total: amount, action: .read))
            }
            // netmd-exploits leaves the loop like this (cancelled, or 0xfff cached sectors) without
            // finishing the download; SwiftMD finishes it so the player's display goes back to normal.
            try await reader.finishDownload()
            return DownloadedTrack(data: output, fileExtension: fileExtension, format: format, title: trackTitle, complete: false)
        } catch {
            try? await reader.finishDownload() // At least try to put the device back into a usable state.
            throw error
        }
    }
}

/// JavaScript `Array.splice(start, count)` removal rules.
private func jsSplice(_ a: inout [UInt8], _ start: Int, _ count: Int) {
    let s = min(max(start, 0), a.count)
    let n = min(count, a.count - s)
    if n > 0 { a.removeSubrange(s..<s + n) }
}
