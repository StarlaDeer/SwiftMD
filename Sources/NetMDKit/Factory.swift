// SwiftMD - port of netmd-js src/factory (factory command set)
// Original: Copyright (C) Asivery, Sir68k (https://github.com/cybercase/netmd-js)
// Licensed under the GNU General Public License v2.0.
//
// The factory command set reads and writes the player's RAM, EEPROM and disc cache, and loads
// firmware patches. Misuse can leave a player unable to record over NetMD. SwiftMD keeps it behind
// an explicit opt-in; nothing here runs unless asked for.

import CommonCrypto
import Foundation

public enum MemoryType: UInt8, Sendable {
    case mapped = 0x0
    case eeprom2 = 0x2
    case eeprom3 = 0x3
}

public enum MemoryOpenType: UInt8, Sendable {
    case close = 0x0
    case read = 0x1
    case write = 0x2
    case readWrite = 0x3
}

public enum DisplayMode: UInt8, Sendable {
    case `default` = 0x0
    case override = 0x1
}

public enum PatchPeripheralBase: Int, Sendable {
    case netmd = 0x0380_2000
    case himd = 0x0380_4000
}

public enum FactoryError: Error, Equatable, CustomStringConvertible {
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .invalidArgument(let m): return m
        }
    }
}

public struct DeviceCode: Sendable, Equatable {
    public var chipType: Int
    public var hwid: Int
    public var version: Int
    public var subversion: Int

    /// The code netmd-exploits keys its tables on, e.g. "S1.600" or "R1.400".
    public var descriptive: String {
        let prefix: String
        switch chipType {
        case 0x20: prefix = "R" // Type-R
        case 0x21: prefix = "S" // Type-S
        case 0x23: prefix = "Hp" // DH10P
        case 0x22: prefix = "Hn" // MZ-NH*
        case 0x24: prefix = "Hr" // MZ-RH*
        case 0x25: prefix = "Hx" // MZ-RH1
        default: prefix = "\(chipType)?"
        }
        let digits = Array(String(version))
        let major = digits.first.map(String.init) ?? "0"
        let minor = digits.count > 1 ? String(digits[1]) : "undefined"
        return "\(prefix)\(major).\(minor)\(String(format: "%02X", subversion))"
    }
}

/// CRC used by factory writes. Port of netmd-js `calculateChecksum`.
func factoryChecksum(_ data: [UInt8], as16Bit: Bool, seed: UInt32 = 0) -> UInt16 {
    var crc = seed
    let words: [UInt32] = as16Bit
        ? stride(from: 0, to: data.count - 1, by: 2).map { UInt32(data[$0 + 1]) << 8 | UInt32(data[$0]) }
        : data.map(UInt32.init)
    var temp = UInt32(words.count)
    for e in words {
        temp = (temp & 0xffff_0000) | e
        crc ^= temp
        for _ in 0..<16 {
            let topBit = crc & 0x8000
            crc = crc << 1
            if topBit != 0 { crc ^= 0x1021 }
        }
    }
    return UInt16(crc & 0xffff)
}

public func eepromChecksum(_ data: [UInt8], isHiMD: Bool = false) -> UInt16 {
    factoryChecksum(data, as16Bit: true, seed: isHiMD ? 0xa596 : 0)
}

private let factoryTransferKey: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]

/// Port of netmd-js `encryptDataForFactoryTransfer`: DES-ECB with PKCS#7 padding, minus the last block.
func encryptForFactoryTransfer(_ plaintext: [UInt8]) throws -> [UInt8] {
    let padding = 8 - plaintext.count % 8
    let padded = plaintext + [UInt8](repeating: UInt8(padding), count: padding)
    return Array(try des(CCOperation(kCCEncrypt), key: factoryTransferKey, .ecb, padded).dropLast(8))
}

/// Port of netmd-js `decryptDataFromFactoryTransfer`: raw DES-ECB.
func decryptFromFactoryTransfer(_ ciphertext: [UInt8]) throws -> [UInt8] {
    guard ciphertext.count % 8 == 0 else {
        throw FactoryError.invalidArgument("Encrypted factory data must be a multiple of 8 bytes")
    }
    return try des(CCOperation(kCCDecrypt), key: factoryTransferKey, .ecb, ciphertext)
}

/// The factory command set of a connected device. Get one with `NetMDInterface.factory()`.
/// Port of netmd-js NetMDFactoryInterface, HiMDFactoryInterface and RH1FactoryInterface.
public final class NetMDFactory: @unchecked Sendable {
    // Commands go through the device actor, which serializes them.
    public enum Kind: Sendable {
        case netmd // Type-R / Type-S portables and decks
        case himd // MZ-NH*, MZ-RH*, DS-HMD1
        case rh1 // MZ-RH1, which reads and writes DRAM through the metadata peripheral
    }

    let device: NetMDInterface
    public let kind: Kind

    init(device: NetMDInterface, kind: Kind) {
        self.device = device
        self.kind = kind
    }

    func sendQuery(_ query: [UInt8]) async throws -> [UInt8] {
        try await device.sendFactoryQuery(query)
    }

    // MARK: Commands

    public func auth() async throws {
        switch kind {
        case .netmd: _ = try await sendQuery(formatQuery("1801 ff0e 4e6574204d442057616c6b6d616e")) // "Net MD Walkman"
        case .himd, .rh1: _ = try await sendQuery(formatQuery("1802 ff04 4d44574d")) // "MDWM"
        }
    }

    public func changeMemoryState(address: Int, length: Int, type: MemoryType, state: MemoryOpenType, encrypted: Bool = false) async throws {
        let opcode: String
        switch kind {
        case .netmd: opcode = "1820"
        case .himd: opcode = "182b"
        case .rh1: return // Not needed for DRAM access
        }
        _ = try await sendQuery(formatQuery(
            "\(opcode) ff %b %<d %b %b %b",
            .init(type.rawValue), .init(address), .init(length), .init(state.rawValue), encrypted ? 1 : 0
        ))
    }

    public func read(address: Int, length: Int, type: MemoryType) async throws -> [UInt8] {
        switch kind {
        case .netmd:
            let reply = try await sendQuery(formatQuery("1821 ff %b %<d %b", .init(type.rawValue), .init(address), .init(length)))
            return Array(try scanQuery(reply, "1821 00 %? %?%?%?%? %? %?%? %*")[0].bytes.dropLast(2))
        case .himd:
            guard length <= 0x1f else { throw FactoryError.invalidArgument("Cannot read more than 0x1F bytes at a time.") }
            let reply = try await sendQuery(formatQuery("182c ff %b %<d", .init((length & 0x1f) | (Int(type.rawValue) << 5)), .init(address)))
            return Array(try scanQuery(reply, "182c 00 %? %?%?%?%? %? %?%? %*")[0].bytes.dropLast(2))
        case .rh1:
            let (block, offset) = try rh1DRAMAddress(address, type: type)
            return try await readMetadataPeripheral(sector: block, offset: offset, length: length)
        }
    }

    public func write(address: Int, data: [UInt8], type: MemoryType) async throws {
        switch kind {
        case .netmd:
            _ = try await sendQuery(formatQuery(
                "1822 ff %b %<d %b 0000 %* %<w",
                .init(type.rawValue), .init(address), .init(data.count), .bytes(data), .init(factoryChecksum(data, as16Bit: false))
            ))
        case .himd:
            guard data.count <= 0x1f else { throw FactoryError.invalidArgument("Cannot write more than 0x1F bytes at a time.") }
            _ = try await sendQuery(formatQuery(
                "182d ff %b %<d %b 0000 %* %<w",
                .init((data.count & 0x1f) | (Int(type.rawValue) << 5)), .init(address), .init(data.count), .bytes(data),
                .init(factoryChecksum(data, as16Bit: false, seed: 0xa596))
            ))
        case .rh1:
            let (block, offset) = try rh1DRAMAddress(address, type: type)
            try await writeMetadataPeripheral(sector: block, offset: offset, data: data)
        }
    }

    private func rh1DRAMAddress(_ address: Int, type: MemoryType) throws -> (Int, Int) {
        guard type == .mapped, address >= 0x0200_0000 else { throw FactoryError.invalidArgument("Invalid address!") }
        let relative = address - 0x0200_0000
        return (relative / 2368, relative % 2368)
    }

    public func readMetadataPeripheral(sector: Int, offset: Int, length: Int) async throws -> [UInt8] {
        let reply = try await sendQuery(formatQuery("1824 ff %<w %<w %b", .init(sector), .init(offset), .init(length)))
        return try scanQuery(reply, "1824 00 %?%?%?%? %b %*")[1].bytes
    }

    public func writeMetadataPeripheral(sector: Int, offset: Int, data: [UInt8]) async throws {
        _ = try await sendQuery(formatQuery("1825 ff %<w %<w %z", .init(sector), .init(offset), .bytes(data)))
    }

    public func setDisplayMode(_ mode: DisplayMode) async throws {
        _ = try await sendQuery(formatQuery("1851 ff %b", .init(mode.rawValue)))
    }

    /// Shows up to 8 characters (or 9 raw bytes) on the player's display.
    public func setDisplayOverride(_ text: String, blink: Bool) async throws {
        guard text.count < 9 else { throw FactoryError.invalidArgument("The text provided has to be at most 8 characters long") }
        try await setDisplayOverride(bytes: encodeToSJIS(text), blink: blink)
    }

    public func setDisplayOverride(bytes: [UInt8], blink: Bool) async throws {
        guard bytes.count < 10 else { throw FactoryError.invalidArgument("At most 9 bytes can be displayed") }
        let full = bytes + [UInt8](repeating: 0, count: 10 - bytes.count)
        // The first argument is a buffer index whose meaning is unknown; netmd-js always sends 0.
        _ = try await sendQuery(formatQuery("1852 ff %b %b 00 %*", 0, blink ? 1 : 0, .bytes(full)))
    }

    /// The firmware version as a BCD number (e.g. 16 for 1.6). netmd-js's version of this
    /// call throws on every reply, so nothing in Web MiniDisc depends on it.
    public func getDeviceVersion() async throws -> Int {
        let reply = try await sendQuery(formatQuery("1813 ff"))
        return try scanQuery(reply, "1813 00 00 %B")[0].int
    }

    public func getDeviceCode() async throws -> DeviceCode {
        let reply = try await sendQuery(formatQuery("1812 ff"))
        let res = try scanQuery(reply, "1812 00 %b %b %b %B")
        return DeviceCode(chipType: res[0].int, hwid: res[1].int, version: res[3].int, subversion: res[2].int)
    }

    public func getSwitchStatus() async throws -> [Int] {
        let reply = try await sendQuery(formatQuery("1853 ff"))
        return try scanQuery(reply, "1853 ff %w %b %b %w").map(\.int)
    }

    // MARK: Helpers (netmd-js netmd-factory-commands.ts)

    public func display(_ text: String, blink: Bool = false) async throws {
        try await setDisplayMode(.override)
        try await setDisplayOverride(text, blink: blink)
    }

    public func cleanRead(address: Int, length: Int, type: MemoryType, encrypted: Bool = false, autoDecrypt: Bool = true) async throws -> [UInt8] {
        try await changeMemoryState(address: address, length: length, type: type, state: .read, encrypted: encrypted)
        var response = try await read(address: address, length: length, type: type)
        try await changeMemoryState(address: address, length: length, type: type, state: .close, encrypted: encrypted)
        if encrypted && autoDecrypt {
            response = try decryptFromFactoryTransfer(response)
        }
        return response
    }

    public func cleanWrite(address: Int, data: [UInt8], type: MemoryType, encrypted: Bool = false, autoEncrypt: Bool = true) async throws {
        let payload = encrypted && autoEncrypt ? try encryptForFactoryTransfer(data) : data
        try await changeMemoryState(address: address, length: payload.count, type: type, state: .write, encrypted: encrypted)
        try await write(address: address, data: payload, type: type)
        try await changeMemoryState(address: address, length: payload.count, type: type, state: .close, encrypted: encrypted)
    }

    public func writeOfAnyLength(address: Int, data: [UInt8], type: MemoryType, encrypted: Bool = false) async throws {
        let size = 0x10
        var offset = 0
        repeat {
            let chunk = Array(data[offset..<min(offset + size, data.count)])
            try await cleanWrite(address: address + offset, data: chunk, type: type, encrypted: encrypted)
            offset += size
        } while offset < data.count
    }

    public func readPatch(_ number: Int, base: PatchPeripheralBase = .netmd) async throws -> (address: Int, data: [UInt8]) {
        let slot = base.rawValue + number * 0x10
        let address = try scanQuery(try await cleanRead(address: slot + 4, length: 4, type: .mapped), "%<d")[0].int
        let data = try await cleanRead(address: slot + 8, length: 4, type: .mapped)
        return (address, data)
    }

    /// Loads a 4-byte firmware patch into a patch slot. Original method written by Sir68k.
    public func patch(address: Int, value: [UInt8], number: Int, totalPatches: Int, base: PatchPeripheralBase = .netmd) async throws {
        guard value.count == 4 else { throw FactoryError.invalidArgument("A patch value is 4 bytes") }
        let slot = base.rawValue + number * 0x10
        let control = base.rawValue + totalPatches * 0x10

        // Write 5, 12 to main control
        try await cleanWrite(address: control, data: [5], type: .mapped)
        try await cleanWrite(address: control, data: [12], type: .mapped)

        // AND 0xFE with patch control
        var patchControl = try await cleanRead(address: slot, length: 4, type: .mapped)
        patchControl[0] &= 0xfe
        try await cleanWrite(address: slot, data: patchControl, type: .mapped)

        // AND 0xFD with patch control
        patchControl = try await cleanRead(address: slot, length: 4, type: .mapped)
        patchControl[0] &= 0xfd
        try await cleanWrite(address: slot, data: patchControl, type: .mapped)

        // Write patch ADDRESS
        try await cleanWrite(address: slot + 4, data: try formatQuery("%<d", .init(address)), type: .mapped)

        // Write patch VALUE
        try await cleanWrite(address: slot + 8, data: value, type: .mapped)

        // OR 1 with patch control
        patchControl = try await cleanRead(address: slot, length: 4, type: .mapped)
        patchControl[0] |= 1
        try await cleanWrite(address: slot, data: patchControl, type: .mapped)

        // Write 5, 9 to main control
        try await cleanWrite(address: control, data: [5], type: .mapped)
        try await cleanWrite(address: control, data: [9], type: .mapped)
    }

    public func unpatch(number: Int, totalPatches: Int, base: PatchPeripheralBase = .netmd) async throws {
        let slot = base.rawValue + number * 0x10
        let control = base.rawValue + totalPatches * 0x10

        try await cleanWrite(address: control, data: [5], type: .mapped)
        try await cleanWrite(address: control, data: [12], type: .mapped)

        var patchControl = try await cleanRead(address: slot, length: 4, type: .mapped)
        patchControl[0] &= 0xfe
        try await cleanWrite(address: slot, data: patchControl, type: .mapped)

        try await cleanWrite(address: control, data: [5], type: .mapped)
        try await cleanWrite(address: control, data: [9], type: .mapped)
    }

    /// Reads one 2352-byte UTOC sector from the player's disc cache.
    public func readUTOCSector(_ sector: Int) async throws -> [UInt8] {
        var out: [UInt8] = []
        for i in 0..<147 { // 147 * 16 = 2352 - sector length
            out += try await readMetadataPeripheral(sector: sector, offset: i * 16, length: 16)
        }
        return out
    }

    public func writeUTOCSector(_ sector: Int, data: [UInt8]) async throws {
        guard data.count == 2352 else { throw FactoryError.invalidArgument("The data provided is not a valid TOC Sector") }
        for i in stride(from: 0, to: data.count, by: 16) {
            try await writeMetadataPeripheral(sector: sector, offset: i, data: Array(data[i..<i + 16]))
        }
    }

    public func descriptiveDeviceCode() async throws -> String {
        try await getDeviceCode().descriptive
    }
}

extension NetMDInterface {
    /// Sends a factory-set command (vendor requests 0xff) and reads its reply.
    func sendFactoryQuery(_ query: [UInt8], test: Bool = false, acceptInterim: Bool = false) async throws -> [UInt8] {
        await lock()
        defer { unlock() }
        let statusByte = test ? Status.specificInquiry.rawValue : Status.control.rawValue
        try netMD.sendCommand([statusByte] + query, factory: true)
        return try await readReply(acceptInterim: acceptInterim, factory: true)
    }

    /// Authenticates to the factory command set, picking the right variant for the device.
    /// Port of netmd-js `NetMDInterface.factory()`. This only identifies the device; it changes nothing.
    public func factory() async throws -> NetMDFactory {
        let name = deviceName
        let isHiMD = name.contains("MZ-RH") || name.contains("MZ-NH") || name.contains("DS-HMD1")
        _ = try await getNetMDLevel()
        var factory = NetMDFactory(device: self, kind: isHiMD ? .himd : .netmd)
        try await factory.auth()
        if try await factory.descriptiveDeviceCode().hasPrefix("Hx") {
            // This is an MZ-RH1 - switch to the other interface
            factory = NetMDFactory(device: self, kind: .rh1)
        }
        return factory
    }
}
