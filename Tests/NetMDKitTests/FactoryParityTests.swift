import Foundation
import Testing
@testable import NetMDKit

/// Replays a netmd-js transcript: each command SwiftMD sends must match the one netmd-js sent,
/// byte for byte, and gets netmd-js's recorded reply. Record with Tools/record-netmdjs-transcripts.js.
final class ReplayTransport: USBTransport, @unchecked Sendable {
    /// A control command and its reply, or (with `bulkIn`) data read from the bulk IN endpoint.
    struct Exchange: Decodable {
        var request: Int = 0
        var command: String = ""
        var reply: String = ""
        var bulkIn: String?

        enum CodingKeys: String, CodingKey { case request, command, reply, bulkIn }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bulkIn = try c.decodeIfPresent(String.self, forKey: .bulkIn)
            if bulkIn == nil {
                request = try c.decode(Int.self, forKey: .request)
                command = try c.decode(String.self, forKey: .command)
                reply = try c.decode(String.self, forKey: .reply)
            }
        }
    }

    private var exchanges: [Exchange]
    private var pending: [UInt8]?
    private(set) var mismatch: String?
    var remaining: Int { exchanges.count }

    init(_ exchanges: [Exchange]) {
        self.exchanges = exchanges
    }

    func controlOut(request: UInt8, data: [UInt8]) throws {
        let sent = data.map { String(format: "%02x", $0) }.joined()
        guard !exchanges.isEmpty else {
            mismatch = "extra command \(sent)"
            throw USBError.io(mismatch!)
        }
        let expected = exchanges.removeFirst()
        guard expected.bulkIn == nil else {
            mismatch = "sent \(String(format: "%02x", request)):\(sent), netmd-js read bulk data here"
            throw USBError.io(mismatch!)
        }
        guard Int(request) == expected.request, sent == expected.command else {
            mismatch = "sent \(String(format: "%02x", request)):\(sent), netmd-js sent \(String(format: "%02x", expected.request)):\(expected.command)"
            throw USBError.io(mismatch!)
        }
        pending = hexBytes(expected.reply)
    }

    func controlIn(request: UInt8, length: Int) throws -> [UInt8] {
        if request == 0x01 { return [0, 0, UInt8(pending?.count ?? 0), 0] }
        defer { pending = nil }
        return Array((pending ?? []).prefix(length))
    }

    /// Bulk data netmd-js read in one transfer, served to SwiftMD in whatever pieces it asks for.
    private var bulkData: [UInt8] = []

    func bulkIn(length: Int) throws -> [UInt8] {
        if bulkData.isEmpty {
            guard let next = exchanges.first, let data = next.bulkIn else {
                mismatch = "read \(length) bulk bytes, netmd-js didn't read bulk data here"
                throw USBError.io(mismatch!)
            }
            exchanges.removeFirst()
            bulkData = hexBytes(data)
        }
        let out = Array(bulkData.prefix(length))
        bulkData.removeFirst(out.count)
        return out
    }
    func bulkOut(_ data: [UInt8]) throws { throw USBError.io("no bulk in replay") }
    func close() {}
}

func hexBytes(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        out.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    return out
}

struct Transcript: Decodable {
    let exchanges: [ReplayTransport.Exchange]
    let result: Result?

    enum Result: Decodable {
        case string(String)
        case bytes(String)
        case patch(address: Int, data: String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s); return }
            struct Bytes: Decodable { let bytes: String }
            if let b = try? c.decode(Bytes.self) { self = .bytes(b.bytes); return }
            struct Patch: Decodable { let address: Int; let data: String }
            let p = try c.decode(Patch.self)
            self = .patch(address: p.address, data: p.data)
        }
    }
}

let transcripts: [String: Transcript] = {
    let url = Bundle.module.url(forResource: "factory-transcripts", withExtension: "json", subdirectory: "Fixtures")!
    return try! JSONDecoder().decode([String: Transcript].self, from: Data(contentsOf: url))
}()

func hexString(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

@Suite struct FactoryParityTests {
    func run(_ name: String, kind: NetMDFactory.Kind = .netmd,
             _ body: (NetMDFactory) async throws -> Transcript.Result?) async throws {
        let transcript = try #require(transcripts[name], "missing transcript \(name)")
        let transport = ReplayTransport(transcript.exchanges)
        let iface = try await NetMDInterface.open(transport: transport, vendorID: 0x054c, productID: 0x00c7)
        let result: Transcript.Result?
        do {
            result = try await body(NetMDFactory(device: iface, kind: kind))
        } catch {
            Issue.record("\(name): \(transport.mismatch ?? String(describing: error))")
            return
        }
        #expect(transport.remaining == 0, "\(name): \(transport.remaining) netmd-js commands were never sent")
        switch (result, transcript.result) {
        case (nil, nil): break
        case let (.string(a)?, .string(b)?): #expect(a == b, "\(name) result")
        case let (.bytes(a)?, .bytes(b)?): #expect(a == b, "\(name) result")
        case let (.patch(a1, d1)?, .patch(a2, d2)?): #expect(a1 == a2 && d1 == d2, "\(name) result")
        default: Issue.record("\(name): result \(String(describing: result)) vs netmd-js \(String(describing: transcript.result))")
        }
    }

    @Test func auth() async throws {
        try await run("netmd.auth") { try await $0.auth(); return nil }
    }

    @Test func deviceCode() async throws {
        try await run("netmd.deviceCode") { .string(try await $0.descriptiveDeviceCode()) }
    }

    @Test func cleanRead() async throws {
        try await run("netmd.cleanRead") { .bytes(hexString(try await $0.cleanRead(address: 0x0380_2004, length: 4, type: .mapped))) }
    }

    @Test func cleanReadEncrypted() async throws {
        try await run("netmd.cleanReadEncrypted") {
            .bytes(hexString(try await $0.cleanRead(address: 0x1000, length: 16, type: .eeprom2, encrypted: true)))
        }
    }

    @Test func cleanWrite() async throws {
        try await run("netmd.cleanWrite") { try await $0.cleanWrite(address: 0x0200_3ff0, data: [1, 2, 3, 4, 5, 6, 7, 8], type: .mapped); return nil }
    }

    @Test func cleanWriteEncrypted() async throws {
        try await run("netmd.cleanWriteEncrypted") {
            try await $0.cleanWrite(address: 0x1000, data: [9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6], type: .eeprom2, encrypted: true)
            return nil
        }
    }

    @Test func writeOfAnyLength() async throws {
        try await run("netmd.writeOfAnyLength") { try await $0.writeOfAnyLength(address: 0x0200_4000, data: Array(0..<40), type: .mapped); return nil }
    }

    @Test func readPatch() async throws {
        try await run("netmd.readPatch") {
            let p = try await $0.readPatch(3)
            return .patch(address: p.address, data: hexString(p.data))
        }
    }

    @Test func patch() async throws {
        try await run("netmd.patch") {
            try await $0.patch(address: 0xc4, value: [0xdc, 0xff, 0xff, 0xea], number: 7, totalPatches: 8)
            return nil
        }
    }

    @Test func unpatch() async throws {
        try await run("netmd.unpatch") { try await $0.unpatch(number: 7, totalPatches: 8); return nil }
    }

    @Test func display() async throws {
        try await run("netmd.display") { try await $0.display("SwiftMD", blink: true); return nil }
    }

    @Test func readUTOCSector() async throws {
        try await run("netmd.readUTOCSector") { .bytes(hexString(try await $0.readUTOCSector(1))) }
    }

    @Test func writeUTOCSector() async throws {
        try await run("netmd.writeUTOCSector") {
            try await $0.writeUTOCSector(2, data: (0..<2352).map { UInt8(truncatingIfNeeded: $0 * 13) })
            return nil
        }
    }

    // MARK: netmd-exploits

    func safety(_ version: String) -> (NetMDFactory) async throws -> Transcript.Result? {
        { .string(try await SafetyPatches.load(on: $0, version: version, inUse: []).freePatches.map(String.init).joined(separator: ",")) }
    }

    @Test func safetyPatchIsLoadedWhenMissing() async throws {
        try await run("netmd.safetyApply", safety("S1.600"))
    }

    @Test func safetyPatchAlreadyPresentWritesNothing() async throws {
        try await run("netmd.safetyFound", safety("S1.600"))
    }

    @Test func typeRHasNoSafetyPatch() async throws {
        try await run("netmd.safetyTypeR", safety("R1.400"))
    }

    @Test func firmwareDump() async throws {
        try await run("netmd.firmwareDump") {
            let dump = try await FirmwareDumper(factory: $0, version: "S1.600", romSize: 0x40, ramSize: 0x100).dump()
            return .bytes(hexString(dump.ram) + hexString(dump.rom))
        }
    }

    @Test func firmwareDumpWritesOnlyTheRAMBoundsTable() throws {
        // The only write in a dump: 16 zero bytes into RAM, at the read-range table netmd-js found.
        let transcript = try #require(transcripts["netmd.firmwareDump"])
        let writes = transcript.exchanges.filter { $0.command.hasPrefix("001822") }
        #expect(writes.count == 1)
        #expect(writes.first?.command == "001822ff00" + "70000002" + "10" + "0000" + String(repeating: "00", count: 16) + writes.first!.command.suffix(4))
    }

    @Test func himdAuth() async throws {
        try await run("himd.auth", kind: .himd) { try await $0.auth(); return nil }
    }

    @Test func himdCleanRead() async throws {
        try await run("himd.cleanRead", kind: .himd) { .bytes(hexString(try await $0.cleanRead(address: 0x0380_4008, length: 4, type: .mapped))) }
    }

    @Test func himdCleanWrite() async throws {
        try await run("himd.cleanWrite", kind: .himd) { try await $0.cleanWrite(address: 0x0200_3ff0, data: [1, 2, 3, 4], type: .mapped); return nil }
    }
}

@Suite struct DeviceCodeTests {
    @Test func descriptiveCodes() {
        #expect(DeviceCode(chipType: 0x21, hwid: 8, version: 16, subversion: 0).descriptive == "S1.600")
        #expect(DeviceCode(chipType: 0x20, hwid: 4, version: 14, subversion: 0).descriptive == "R1.400")
        #expect(DeviceCode(chipType: 0x25, hwid: 0, version: 10, subversion: 0xa0).descriptive == "Hx1.0A0")
    }
}
