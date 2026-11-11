// SwiftMD - port of netmd-js src/netmd-interface.ts (read-only and status queries)
// Original: Copyright (C) Stefano Brilli, Asivery (https://github.com/cybercase/netmd-js)
// Licensed under the GNU General Public License v2.0.

import Foundation

public enum DiscFormat: Int, Sendable {
    case lp4 = 0
    case lp2 = 2
    case spMono = 4
    case spStereo = 6
}

public enum Encoding: Int, Sendable {
    case sp = 0x90
    case lp2 = 0x92
    case lp4 = 0x93
}

public enum Channels: Int, Sendable {
    case stereo = 0x00
    case mono = 0x01
}

public enum TrackFlag: Int, Sendable {
    case unprotected = 0x00
    case protected = 0x03
}

public struct DiscFlag {
    public static let writable = 0x10
    public static let writeProtected = 0x40
}

public enum NetMDLevel: Int, Sendable {
    case level1 = 0x20 // Network MD
    case level2 = 0x50 // Program play MD
    case level3 = 0x70 // Editing MD
}

enum Descriptor: String {
    // TD - text database
    case discTitleTD = "10 1801"
    case audioUTOC1TD = "10 1802"
    case audioUTOC4TD = "10 1803"
    case dsiTD = "10 1804"
    case audioContentsTD = "10 1001"
    case rootTD = "10 1000"

    case discSubunitIdentifier = "00"
    case operatingStatusBlock = "80 00" // Real name unknown
}

enum DescriptorAction: String {
    case openRead = "01"
    case openWrite = "03"
    case close = "00"
}

enum Status: UInt8 {
    // NetMD Protocol return status (first byte of request)
    case control = 0x00
    case status = 0x01
    case specificInquiry = 0x02
    case notify = 0x03
    case generalInquiry = 0x04
    //  ... (first byte of response)
    case notImplemented = 0x08
    case accepted = 0x09
    case rejected = 0x0a
    case inTransition = 0x0b
    case implemented = 0x0c
    case changed = 0x0d
    case interim = 0x0f
}

/// A track group parsed from the disc title: (half-width name, full-width name, zero-based track indexes).
public struct RawTrackGroup: Equatable, Sendable {
    public var title: String?
    public var fullWidthTitle: String?
    public var tracks: [Int]
}

public actor NetMDInterface {
    static let maxInterimReadAttempts = 4
    static let interimResponseRetryInterval: Duration = .milliseconds(100)

    let netMD: NetMD

    public nonisolated let deviceName: String
    public nonisolated let vendorID: Int
    public nonisolated let productID: Int

    init(netMD: NetMD) {
        self.netMD = netMD
        deviceName = netMD.deviceName
        vendorID = netMD.vendorID
        productID = netMD.productID
    }

    /// Opens a NetMD device over the given transport and drains any stale reply.
    public static func open(transport: USBTransport, vendorID: Int, productID: Int) async throws -> NetMDInterface {
        let netMD = NetMD(transport: transport, vendorID: vendorID, productID: productID)
        try await netMD.initialize()
        return NetMDInterface(netMD: netMD)
    }

    /// Opens the first connected NetMD device.
    public static func openFirstDevice() async throws -> NetMDInterface {
        guard let info = IOUSBHostTransport.connectedDevices().first else { throw USBError.noDeviceFound }
        let transport = try IOUSBHostTransport(device: info)
        return try await open(transport: transport, vendorID: info.vendorID, productID: info.productID)
    }

    public func close() {
        netMD.finalize()
    }

    // MARK: - Query plumbing

    func changeDescriptorState(_ descriptor: Descriptor, _ action: DescriptorAction) async {
        // Errors are ignored, as in netmd-js: some devices reject these harmlessly.
        _ = try? await sendQuery(formatQuery("1808 \(descriptor.rawValue) \(action.rawValue) 00"))
    }

    func sendQuery(_ query: [UInt8], test: Bool = false, acceptInterim: Bool = false) async throws -> [UInt8] {
        await lock()
        defer { unlock() }
        try sendCommand(query, test: test)
        return try await readReply(acceptInterim: acceptInterim)
    }

    // The actor alone doesn't keep exchanges apart: it is re-entered while a query sleeps
    // waiting for its reply, and a second command sent then would get the first one's reply.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    func unlock() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume() // Hand the lock straight to the next waiter
        }
    }

    func sendCommand(_ query: [UInt8], test: Bool = false) throws {
        let statusByte = test ? Status.specificInquiry.rawValue : Status.control.rawValue
        try netMD.sendCommand([statusByte] + query)
    }

    func readReply(acceptInterim: Bool = false, patient: Bool = false, factory: Bool = false) async throws -> [UInt8] {
        var attempt = 0
        while attempt < Self.maxInterimReadAttempts {
            let data = try await netMD.readReply(factory: factory, patient: patient)
            guard let status = data.first else { throw NetMDError.noReply }
            switch Status(rawValue: status) {
            case .notImplemented:
                throw NetMDError.notImplemented("Not implemented")
            case .rejected:
                throw NetMDError.rejected(data.map { String(format: "%02x", $0) }.joined())
            case .interim where !acceptInterim:
                try await Task.sleep(for: Self.interimResponseRetryInterval * ((1 << attempt) - 1))
                attempt += 1
                continue // Retry
            default:
                return Array(data.dropFirst())
            }
        }
        throw NetMDError.rejected("Max read attempts for interim status reached")
    }

    // MARK: - Device info

    public func getNetMDLevel() async throws -> NetMDLevel? {
        await changeDescriptorState(.discSubunitIdentifier, .openRead)
        let reply = try await sendQuery(formatQuery("1809 00 ff00 0000 0000"))
        let res = try scanQuery(reply, "1809 00 1000 %?%? %?%? %w %b %b %b %b %w %*")
        let sizeOfListID = res[2].int
        let rootObjectListCount = res[5].int
        let buffer = res[6].bytes
        var offset = 0

        func readByte() throws -> Int {
            guard offset < buffer.count else { throw QueryError.truncated(format: "disc subunit identifier") }
            defer { offset += 1 }
            return Int(buffer[offset])
        }
        func readMultibyte(_ n: Int) throws -> Int {
            var output = 0
            for _ in 0..<n { output = (output << 8) | (try readByte()) }
            return output
        }

        for _ in 0..<rootObjectListCount { _ = try readMultibyte(sizeOfListID) }
        _ = try readMultibyte(2) // subunit dependent length
        _ = try readMultibyte(2) // subunit fields length
        _ = try readByte() // attributes
        _ = try readByte() // disc subunit version

        var profiles: [Int: Int] = [:]
        let supportedMediaTypes = try readByte()
        for _ in 0..<supportedMediaTypes {
            let mediaType = try readMultibyte(2)
            let implementationProfileID = try readByte()
            _ = try readByte() // media type attributes
            _ = try readMultibyte(2) // type dependent length
            _ = try readByte() // MD audio version
            _ = try readByte() // supports MD clip
            profiles[mediaType] = implementationProfileID
        }
        await changeDescriptorState(.discSubunitIdentifier, .close)
        guard let profile = profiles[0x301] else {
            throw NetMDError.unsupportedDevice("This Minidisc recorder doesn't support Minidiscs")
        }
        return NetMDLevel(rawValue: profile)
    }

    // MARK: - Status

    public func getStatus() async throws -> [UInt8] {
        await changeDescriptorState(.operatingStatusBlock, .openRead)
        let reply = try await sendQuery(formatQuery("1809 8001 0230 8800 0030 8804 00 ff00 00000000"))
        let res = try scanQuery(reply, "1809 8001 0230 8800 0030 8804 00 1000 00090000 %x")
        await changeDescriptorState(.operatingStatusBlock, .close)
        return res[0].bytes
    }

    public func isDiscPresent() async throws -> Bool {
        let status = try await getStatus()
        return status.count > 4 && status[4] == 0x40
    }

    func getPlaybackStatus(_ p1: Int, _ p2: Int) async throws -> [UInt8] {
        await changeDescriptorState(.operatingStatusBlock, .openRead)
        let reply = try await sendQuery(formatQuery("1809 8001 0330 %w 0030 8805 0030 %w 00 ff00 00000000", .init(p1), .init(p2)))
        let res = try scanQuery(reply, "1809 8001 0330 %?%? %?%? %?%? %?%? %?%? %? 1000 00%?0000 %x %?") // Fix MZ-RH1 not launching
        await changeDescriptorState(.operatingStatusBlock, .close)
        return res[0].bytes
    }

    public func getPlaybackStatus1() async throws -> [UInt8] { try await getPlaybackStatus(0x8801, 0x8807) }
    public func getPlaybackStatus2() async throws -> [UInt8] { try await getPlaybackStatus(0x8802, 0x8806) }

    /// Returns [track, hour, minute, second, frame], or nil if the device rejects the query.
    public func getPosition() async throws -> [Int]? {
        await changeDescriptorState(.operatingStatusBlock, .openRead)
        let reply: [UInt8]
        do {
            reply = try await sendQuery(formatQuery("1809 8001 0430 8802 0030 8805 0030 0003 0030 0002 00 ff00 00000000"))
        } catch NetMDError.rejected {
            return nil
        }
        let res = try scanQuery(
            reply,
            "1809 8001 0430 %?%? %?%? %?%? " + "%?%? %?%? %?%? %?%? %? %?00 00%?0000 " + "000b 0002 0007 00 %w %B %B %B %B"
        )
        await changeDescriptorState(.operatingStatusBlock, .close)
        return res.map(\.int)
    }

    // MARK: - Disc contents

    public func getDiscFlags() async throws -> Int {
        await changeDescriptorState(.rootTD, .openRead)
        let reply = try await sendQuery(formatQuery("1806 01101000 ff00 0001000b"))
        let res = try scanQuery(reply, "1806 01101000 1000 0001000b %b")
        await changeDescriptorState(.rootTD, .close)
        return res[0].int
    }

    public func getTrackCount() async throws -> Int {
        await changeDescriptorState(.audioContentsTD, .openRead)
        let reply = try await sendQuery(formatQuery("1806 02101001 3000 1000 ff00 00000000"))
        let res = try scanQuery(reply, "1806 02101001 %?%? %?%? 1000 00%?0000 0006 0010000200%b")
        await changeDescriptorState(.audioContentsTD, .close)
        return res[0].int
    }

    func rawDiscTitle(wchar: Bool = false) async throws -> String {
        await changeDescriptorState(.audioContentsTD, .openRead)
        await changeDescriptorState(.discTitleTD, .openRead)
        let wcharValue: QueryValue = wchar ? 1 : 0
        var done = 0
        var remaining = 0
        var total = 1
        // Titles arrive in chunks; decode the bytes together so multi-byte characters are never split.
        var bytes: [UInt8] = []
        while done < total {
            let reply = try await sendQuery(formatQuery(
                "1806 02201801 00%b 3000 0a00 ff00 %w%w", wcharValue, .init(remaining), .init(done)
            ))
            var chunkSize: Int
            if remaining == 0 {
                let res = try scanQuery(reply, "1806 02201801 00%? 3000 0a00 1000 %w0000 %?%?000a %w %*")
                chunkSize = res[0].int
                total = res[1].int
                bytes += res[2].bytes
                chunkSize -= 6
            } else {
                let res = try scanQuery(reply, "1806 02201801 00%? 3000 0a00 1000 %w%?%? %*")
                chunkSize = res[0].int
                bytes += res[1].bytes
            }
            guard chunkSize > 0 else { break }
            done += chunkSize
            remaining = total - done
        }
        await changeDescriptorState(.discTitleTD, .close)
        await changeDescriptorState(.audioContentsTD, .close)
        return decodeFromSJIS(bytes)
    }

    public func getDiscTitle(wchar: Bool = false) async throws -> String {
        try parseDiscTitle(await rawDiscTitle(wchar: wchar), wchar: wchar)
    }

    public func getTrackGroupList() async throws -> [RawTrackGroup] {
        let rawTitle = try await rawDiscTitle()
        let trackCount = try await getTrackCount()
        let rawFullTitle = try await rawDiscTitle(wchar: true)
        return try parseTrackGroups(rawTitle: rawTitle, rawFullWidthTitle: rawFullTitle, trackCount: trackCount)
    }

    public func getTrackTitle(_ track: Int, wchar: Bool = false) async throws -> String {
        let descriptor: Descriptor = wchar ? .audioUTOC4TD : .audioUTOC1TD
        await changeDescriptorState(descriptor, .openRead)
        let reply = try await sendQuery(formatQuery("1806 022018%b %w 3000 0a00 ff00 00000000", wchar ? 3 : 2, .init(track)))
        let res = try scanQuery(reply, "1806 022018%? %?%? %?%? %?%? 1000 00%?0000 00%?000a %x")
        await changeDescriptorState(descriptor, .close)
        return decodeFromSJIS(res[0].bytes)
    }

    func trackInfo(_ track: Int, _ p1: Int, _ p2: Int) async throws -> [UInt8] {
        await changeDescriptorState(.audioContentsTD, .openRead)
        let reply = try await sendQuery(formatQuery("1806 02201001 %w %w %w ff00 00000000", .init(track), .init(p1), .init(p2)))
        let res = try scanQuery(reply, "1806 02201001 %?%? %?%? %?%? 1000 00%?0000 %x")
        await changeDescriptorState(.audioContentsTD, .close)
        return res[0].bytes
    }

    /// Returns [hour, minute, second, frame].
    public func getTrackLength(_ track: Int) async throws -> [Int] {
        let raw = try await trackInfo(track, 0x3000, 0x0100)
        return try scanQuery(raw, "0001 0006 0000 %B %B %B %B").map(\.int)
    }

    /// Returns (codec, channel).
    public func getTrackEncoding(_ track: Int) async throws -> (Int, Int) {
        let raw = try await trackInfo(track, 0x3080, 0x0700)
        let res = try scanQuery(raw, "8007 0004 0110 %b %b")
        return (res[0].int, res[1].int)
    }

    public func getTrackFlags(_ track: Int) async throws -> Int {
        await changeDescriptorState(.audioContentsTD, .openRead)
        let reply = try await sendQuery(formatQuery("1806 01201001 %w ff00 00010008", .init(track)))
        let res = try scanQuery(reply, "1806 01201001 %?%? 10 00 00010008 %b")
        await changeDescriptorState(.audioContentsTD, .close)
        return res[0].int
    }

    /// Returns [used, total, left], each as [hour, minute, second, frame].
    public func getDiscCapacity() async throws -> [[Int]] {
        await changeDescriptorState(.rootTD, .openRead)
        let reply = try await sendQuery(formatQuery("1806 02101000 3080 0300 ff00 00000000"))
        // 8003 changed to %?03 - Panasonic returns 0803 instead. This byte's meaning is unknown
        let res = try scanQuery(
            reply,
            "1806 02101000 3080 0300 1000 001d0000 001b %?03 0017 8000 0005 %W %B %B %B 0005 %W %B %B %B 0005 %W %B %B %B"
        ).map(\.int)
        await changeDescriptorState(.rootTD, .close)
        return [Array(res[0..<4]), Array(res[4..<8]), Array(res[8..<12])]
    }
}

// MARK: - Title parsing (pure, so it can be tested without a device)

func parseDiscTitle(_ rawTitle: String, wchar: Bool) -> String {
    let delim = wchar ? "／／" : "//"
    let titleMarker = wchar ? "０；" : "0;"
    guard rawTitle.hasSuffix(delim) else { return rawTitle }
    let firstEntry = rawTitle.components(separatedBy: delim)[0]
    return firstEntry.hasPrefix(titleMarker) ? String(firstEntry.dropFirst(2)) : ""
}

func parseTrackGroups(rawTitle: String, rawFullWidthTitle: String, trackCount: Int) throws -> [RawTrackGroup] {
    let groupList = rawTitle.components(separatedBy: "//")
    let fullWidthGroupList = rawFullWidthTitle.components(separatedBy: "／／")
    var trackOwners: [Int: String] = [:]
    var result: [RawTrackGroup] = []

    for group in groupList {
        if group.isEmpty { continue }
        if group.hasPrefix("0;") || !group.contains(";") || !rawTitle.contains("//") { continue }
        let trackRange = String(group.prefix { $0 != ";" })
        if trackRange.isEmpty { continue }
        let groupName = String(group.dropFirst(trackRange.count + 1))

        let fullWidthRange = halfWidthToFullWidthRange(trackRange)
        let fullWidthGroupName = fullWidthGroupList
            .first { $0.hasPrefix(fullWidthRange) }
            .map { String($0.dropFirst(fullWidthRange.count + 1)) }

        let bounds = trackRange.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard let trackMin = bounds.first ?? nil, let parsedMax = bounds.last ?? nil else {
            throw NetMDError.rejected("Unparsable group range \(trackRange)")
        }
        let trackMax = min(parsedMax, trackCount) // Groups might not updated when a song is deleted
        guard trackMin >= 0, trackMin <= trackMax else {
            throw NetMDError.rejected("Invalid group range \(trackRange)")
        }

        var tracks: [Int] = []
        for track in (trackMin - 1)..<trackMax {
            if let owner = trackOwners[track] {
                throw NetMDError.rejected("Track \(track) is in 2 groups: \(owner)")
            }
            trackOwners[track] = groupName
            tracks.append(track)
        }
        result.append(RawTrackGroup(title: groupName, fullWidthTitle: fullWidthGroupName, tracks: tracks))
    }

    let ungrouped = (0..<trackCount).filter { trackOwners[$0] == nil }
    if !ungrouped.isEmpty {
        result.insert(RawTrackGroup(title: nil, fullWidthTitle: nil, tracks: ungrouped), at: 0)
    }
    return result
}
