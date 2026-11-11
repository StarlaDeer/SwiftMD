import CommonCrypto
import Foundation
@testable import NetMDKit

/// A simulated NetMD recorder behind a USBTransport. It answers the vendor control
/// requests the same way real hardware does: poll (0x01) reports the pending reply
/// length, write (0x80) submits a command, read (0x81) returns the reply.
final class FakeNetMDDevice: USBTransport, @unchecked Sendable {
    struct FakeTrack {
        var title: String
        var fullWidthTitle: String = ""
        var length: [Int] // hour, minute, second, frame
        var encoding: Encoding = .sp
        var channels: Channels = .stereo
        var protected = false
        /// Decrypted audio, for tracks sent with an upload session.
        var uploadedData: [UInt8]? = nil
        var wireformat: Int? = nil
        var discFormat: Int? = nil
    }

    var rawTitle: String
    var rawFullWidthTitle: String
    var tracks: [FakeTrack]
    var capacity: [[Int]] = [[0, 10, 0, 0], [1, 20, 0, 0], [1, 10, 0, 0]]
    var discFlags = DiscFlag.writable
    var positionRejected = false
    /// Like the MZ-N910, leave off the trailing byte of playback-status replies.
    var shortPlaybackStatus = false
    var operatingStatus = 50687 // ready
    /// Make each reply take one extra poll, so a waiting query yields to other tasks like real hardware.
    var slowReplies = false
    private(set) var commands: [[UInt8]] = []
    /// Problems a real deck could choke on, such as a title write whose length fields don't match its data.
    private(set) var writeErrors: [String] = []
    private(set) var playActions: [Int] = []
    private(set) var currentTrack = 0
    private(set) var stopped = false
    private(set) var ejected = false
    private var pending: [UInt8]?
    private var pollsBeforeReply = 0

    // Secure session state
    var leafID: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
    let deviceNonce: [UInt8] = [0xde, 0xad, 0xbe, 0xef, 0x10, 0x20, 0x30, 0x40]
    /// Reject every recording after receiving it, as a deck does with a disc it can't write.
    var failRecording = false
    private(set) var acquired = false
    private(set) var inSecureSession = false
    private(set) var sessionKey: [UInt8]?
    private(set) var downloadSetUp = false
    private(set) var committedTracks: [Int] = []
    private(set) var receivedEKBID: Int?
    private var pendingTransfer: (wireformat: Int, discFormat: Int, frames: Int, totalBytes: Int)?
    private var bulkBuffer: [UInt8] = []

    init(rawTitle: String, rawFullWidthTitle: String = "", tracks: [FakeTrack]) {
        self.rawTitle = rawTitle
        self.rawFullWidthTitle = rawFullWidthTitle
        self.tracks = tracks
    }

    // MARK: USBTransport

    func controlIn(request: UInt8, length: Int) throws -> [UInt8] {
        switch request {
        case 0x01:
            if pollsBeforeReply > 0 {
                pollsBeforeReply -= 1
                return [0, 0, 0, 0]
            }
            return [0, 0, UInt8(pending?.count ?? 0), 0]
        case 0x81:
            defer { pending = nil }
            return Array((pending ?? []).prefix(length))
        default:
            throw USBError.io("Unexpected control-in request \(request)")
        }
    }

    func controlOut(request: UInt8, data: [UInt8]) throws {
        guard request == 0x80 else { throw USBError.io("Unexpected control-out request \(request)") }
        commands.append(data)
        pending = try respond(to: Array(data.dropFirst()))
        pollsBeforeReply = slowReplies ? 1 : 0
        precondition(pending!.count < 256, "Fake replies must fit the one-byte length field")
    }

    func bulkIn(length: Int) throws -> [UInt8] { throw USBError.io("No bulk data") }

    func bulkOut(_ data: [UInt8]) throws {
        guard let transfer = pendingTransfer else { throw USBError.io("Unexpected bulk data") }
        bulkBuffer += data
        guard bulkBuffer.count >= transfer.totalBytes else { return }
        pendingTransfer = nil
        if failRecording {
            // Like an MZ-N910 with a worn disc: everything received, then the transfer is rejected.
            bulkBuffer = []
            pending = [Self.rejected] + (try formatQuery(
                "1800 080046 f0030103 28 ff 000100 1001 0001 00 %b %b %d %d",
                .init(transfer.wireformat), .init(transfer.discFormat), .init(transfer.frames), .init(transfer.totalBytes)
            ))
            return
        }
        let index = try receiveTrack(bulkBuffer, transfer: transfer)
        bulkBuffer = []
        pending = [Self.accepted] + (try formatQuery(
            "1800 080046 f0030103 28 00 000100 1001 %w 00 0000 00000000 00000000 %*",
            .init(index), .bytes([UInt8](repeating: 0x55, count: 32))
        ))
    }

    /// Unwraps the data key with the KEK and decrypts the track, as a real deck does.
    private func receiveTrack(_ stream: [UInt8], transfer: (wireformat: Int, discFormat: Int, frames: Int, totalBytes: Int)) throws -> Int {
        guard downloadSetUp else { writeErrors.append("track sent before setupDownload"); return 0 }
        let header = Array(stream[0..<24])
        let length = header[4..<8].reduce(0) { $0 << 8 | Int($1) }
        if header[0..<4] != [0, 0, 0, 0] { writeErrors.append("bad stream header") }
        if length != transfer.totalBytes - 24 { writeErrors.append("header says \(length) bytes, command says \(transfer.totalBytes - 24)") }
        let dataKey = try des(CCOperation(kCCEncrypt), key: MDTrack.kek, .ecb, Array(header[8..<16]))
        let plain = try des(CCOperation(kCCDecrypt), key: dataKey, .cbc(iv: Array(header[16..<24])), Array(stream[24...]))
        tracks.append(FakeTrack(title: "", length: [0, 0, 1, 0], uploadedData: plain,
                                wireformat: transfer.wireformat, discFormat: transfer.discFormat))
        return tracks.count - 1
    }
    func close() {}

    // MARK: Command handling

    private static let accepted: UInt8 = 0x09
    private static let rejected: UInt8 = 0x0a

    private func respond(to query: [UInt8]) throws -> [UInt8] {
        func match(_ format: String) -> [QueryValue]? { try? scanQuery(query, format) }

        if match("1808 %*") != nil {
            return [Self.accepted] + query
        }
        if match("1806 01101000 ff00 0001000b") != nil {
            return [Self.accepted] + (try formatQuery("1806 01101000 1000 0001000b %b", .init(discFlags)))
        }
        if let v = match("1806 02201801 00%b 3000 0a00 ff00 %w%w") {
            return [Self.accepted] + (try discTitleReply(wchar: v[0].int, remaining: v[1].int, done: v[2].int))
        }
        if match("1806 02101001 3000 1000 ff00 00000000") != nil {
            return [Self.accepted] + (try formatQuery(
                "1806 02101001 3000 1000 1000 00000000 0006 0010000200%b", .init(tracks.count)
            ))
        }
        if match("1806 02101000 3080 0300 ff00 00000000") != nil {
            var args: [QueryValue] = []
            for time in capacity { args += time.map { QueryValue($0) } }
            let format = "1806 02101000 3080 0300 1000 001d0000 001b 8003 0017 8000"
                + " 0005 %W %B %B %B 0005 %W %B %B %B 0005 %W %B %B %B"
            return [Self.accepted] + (try formatQuery(format, args))
        }
        if let v = match("1806 02201001 %w %w %w ff00 00000000") {
            guard let track = track(v[0]) else { return [Self.rejected] + query }
            let info: [UInt8]
            switch (v[1].int, v[2].int) {
            case (0x3000, 0x0100):
                info = try formatQuery("0001 0006 0000 %B %B %B %B", track.length.map { QueryValue($0) })
            case (0x3080, 0x0700):
                info = try formatQuery("8007 0004 0110 %b %b", .init(track.encoding.rawValue), .init(track.channels.rawValue))
            default:
                return [Self.rejected] + query
            }
            return [Self.accepted] + (try formatQuery(
                "1806 02201001 %w %w %w 1000 00000000 %x", v[0], v[1], v[2], .bytes(info)
            ))
        }
        if let v = match("1806 01201001 %w ff00 00010008") {
            guard let track = track(v[0]) else { return [Self.rejected] + query }
            let flag = track.protected ? TrackFlag.protected : .unprotected
            return [Self.accepted] + (try formatQuery("1806 01201001 %w 10 00 00010008 %b", v[0], .init(flag.rawValue)))
        }
        if let v = match("1806 022018%b %w 3000 0a00 ff00 00000000") {
            guard let track = track(v[1]) else { return [Self.rejected] + query }
            let title = v[0].int == 3 ? track.fullWidthTitle : track.title
            return [Self.accepted] + (try formatQuery(
                "1806 022018%b %w 3000 0a00 1000 00000000 0000000a %x", v[0], v[1], .bytes(encodeToSJIS(title))
            ))
        }
        if match("1809 8001 0230 8800 0030 8804 00 ff00 00000000") != nil {
            return [Self.accepted] + (try formatQuery(
                "1809 8001 0230 8800 0030 8804 00 1000 00090000 %x", .bytes([0, 0, 0, 0, 0x40, 0])
            ))
        }
        if let v = match("1809 8001 0330 %w 0030 8805 0030 %w 00 ff00 00000000") {
            let status: [UInt8] = [0, 0, 0, 0, UInt8(operatingStatus >> 8), UInt8(operatingStatus & 0xff)]
            return [Self.accepted] + (try formatQuery(
                "1809 8001 0330 %w 0030 8805 0030 %w 00 1000 00000000 %x" + (shortPlaybackStatus ? "" : " 00"), v[0], v[1], .bytes(status)
            ))
        }
        if match("1809 8001 0430 8802 0030 8805 0030 0003 0030 0002 00 ff00 00000000") != nil {
            if positionRejected { return [Self.rejected] + query }
            return [Self.accepted] + (try formatQuery(
                "1809 8001 0430 8802 0030 8805 0030 0003 0030 0002 00 1000 00000000 000b 0002 0007 00 %w %B %B %B %B",
                2, 0, 1, 30, 42
            ))
        }
        if let reply = try respondToEdit(query) { return reply }
        if let reply = try respondToSession(query) { return reply }
        return [Self.rejected] + query
    }

    private func respondToEdit(_ query: [UInt8]) throws -> [UInt8]? {
        func match(_ format: String) -> [QueryValue]? { try? scanQuery(query, format) }

        if let v = match("1807 02201801 00%b 3000 0a00 5000 %w 0000 %w %*") {
            let wchar = v[0].int == 1
            let bytes = v[3].bytes
            let current = encodeToSJIS(wchar ? rawFullWidthTitle : rawTitle)
            checkLengths(what: "disc title", newLength: v[1].int, oldLength: v[2].int, data: bytes, current: current)
            if wchar { rawFullWidthTitle = decodeFromSJIS(bytes) } else { rawTitle = decodeFromSJIS(bytes) }
            return [Self.accepted] + (try formatQuery("1807 02201801 00%b 3000 0a00 5000 %w 0000 %w", v[0], v[1], v[2]))
        }
        if let v = match("1807 022018%b %w 3000 0a00 5000 %w 0000 %w %*") {
            guard tracks.indices.contains(v[1].int) else { return [Self.rejected] + query }
            let wchar = v[0].int == 3
            let index = v[1].int
            let bytes = v[4].bytes
            let current = encodeToSJIS(wchar ? tracks[index].fullWidthTitle : tracks[index].title)
            checkLengths(what: "track \(index) title", newLength: v[2].int, oldLength: v[3].int, data: bytes, current: current)
            if wchar { tracks[index].fullWidthTitle = decodeFromSJIS(bytes) } else { tracks[index].title = decodeFromSJIS(bytes) }
            return [Self.accepted] + (try formatQuery("1807 022018%b %w 3000 0a00 5000 %w 0000 %w", v[0], v[1], v[2], v[3]))
        }
        if let v = match("1840 ff01 00 201001 %w") {
            guard tracks.indices.contains(v[0].int) else { return [Self.rejected] + query }
            tracks.remove(at: v[0].int)
            return [Self.accepted] + (try formatQuery("1840 0001 00 201001 %w", v[0]))
        }
        if match("1840 ff 0000") != nil {
            tracks = []
            rawTitle = ""
            rawFullWidthTitle = ""
            return [Self.accepted] + (try formatQuery("1840 00 0000"))
        }
        if let v = match("1843 ff00 00 201001 %w 201001 %w") {
            let (src, dst) = (v[0].int, v[1].int)
            guard tracks.indices.contains(src), tracks.indices.contains(dst) else { return [Self.rejected] + query }
            tracks.insert(tracks.remove(at: src), at: dst)
            return [Self.accepted] + (try formatQuery("1843 0000 00 201001 %w 201001 %w", v[0], v[1]))
        }
        if let v = match("18c3 ff %b 000000") {
            playActions.append(v[0].int)
            stopped = false
            return [Self.accepted] + (try formatQuery("18c3 00 %b 000000", v[0]))
        }
        if match("18c5 ff 00000000") != nil {
            stopped = true
            return [Self.accepted] + (try formatQuery("18c5 00 00000000"))
        }
        if let v = match("1850 ff010000 0000 %w") {
            currentTrack = v[0].int
            return [Self.accepted] + (try formatQuery("1850 00010000 0000 %w", v[0]))
        }
        if let v = match("1850 ff10 00000000 %w") {
            switch v[0].int {
            case TrackChange.next.rawValue: currentTrack += 1
            case TrackChange.previous.rawValue: currentTrack = max(currentTrack - 1, 0)
            default: break
            }
            return [Self.accepted] + (try formatQuery("1850 0010 00000000 %w", v[0]))
        }
        if match("18c1 ff 6000") != nil {
            ejected = true
            return [Self.accepted] + (try formatQuery("18c1 00 6000"))
        }
        return nil
    }

    private func respondToSession(_ query: [UInt8]) throws -> [UInt8]? {
        func match(_ format: String) -> [QueryValue]? { try? scanQuery(query, format) }
        let prefix = "1800 080046 f0030103"

        if match("ff 010c ffff ffff ffff ffff ffff ffff") != nil { acquired = true; return [Self.accepted] + query }
        if match("ff 0100 ffff ffff ffff ffff ffff ffff") != nil { acquired = false; return [Self.accepted] + query }
        if let v = match("\(prefix) 2b ff %w") {
            return [Self.accepted] + (try formatQuery("\(prefix) 2b 00 %w", v[0]))
        }
        if match("\(prefix) 80 ff") != nil {
            inSecureSession = true
            return [Self.accepted] + (try formatQuery("\(prefix) 80 00"))
        }
        if match("\(prefix) 81 ff") != nil {
            guard inSecureSession else { return [Self.rejected] + query }
            inSecureSession = false
            return [Self.accepted] + (try formatQuery("\(prefix) 81 00"))
        }
        if match("\(prefix) 11 ff") != nil {
            return [Self.accepted] + (try formatQuery("\(prefix) 11 00 %*", .bytes(leafID)))
        }
        if let v = match("\(prefix) 12 ff %w 0000 %w %d %d %d 00000000 %*") {
            receivedEKBID = v[4].int
            if v[0].int != 16 + 16 * v[2].int + 24 { writeErrors.append("EKB data length mismatch") }
            return [Self.accepted] + (try formatQuery("\(prefix) 12 01 0000 00000000"))
        }
        if let v = match("\(prefix) 20 ff 000000 %*") {
            let hostNonce = v[0].bytes
            sessionKey = try retailMAC(key: EKB.openSource.rootKey, value: hostNonce + deviceNonce)
            return [Self.accepted] + (try formatQuery("\(prefix) 20 00 000000 %*", .bytes(deviceNonce)))
        }
        if match("\(prefix) 21 ff 000000") != nil {
            guard sessionKey != nil else { return [Self.rejected] + query }
            sessionKey = nil
            return [Self.accepted] + (try formatQuery("\(prefix) 21 00 000000"))
        }
        if let v = match("\(prefix) 22 ff 0000 %*") {
            guard let sessionKey else { return [Self.rejected] + query }
            let message = try des(CCOperation(kCCDecrypt), key: sessionKey, .cbc(iv: [UInt8](repeating: 0, count: 8)), v[0].bytes)
            downloadSetUp = message == [1, 1, 1, 1] + MDTrack.contentID + MDTrack.kek
            if !downloadSetUp { writeErrors.append("setupDownload message didn't decrypt correctly") }
            return [Self.accepted] + (try formatQuery("\(prefix) 22 00 0000"))
        }
        if let v = match("\(prefix) 28 ff 000100 1001 ffff 00 %b %b %d %d") {
            pendingTransfer = (v[0].int, v[1].int, v[2].int, v[3].int)
            return [Self.accepted] + (try formatQuery("\(prefix) 28 00 000100 1001 ffff 00 %b %b %d %d", v[0], v[1], v[2], v[3]))
        }
        if let v = match("\(prefix) 48 ff 00 1001 %w %*") {
            guard let sessionKey else { return [Self.rejected] + query }
            let expected = try des(CCOperation(kCCEncrypt), key: sessionKey, .ecb, [UInt8](repeating: 0, count: 8))
            if v[1].bytes != expected { writeErrors.append("commitTrack authentication mismatch") }
            committedTracks.append(v[0].int)
            downloadSetUp = false
            return [Self.accepted] + (try formatQuery("\(prefix) 48 00 00 1001 %w", v[0]))
        }
        return nil
    }

    private func checkLengths(what: String, newLength: Int, oldLength: Int, data: [UInt8], current: [UInt8]) {
        if newLength != data.count {
            writeErrors.append("\(what): says \(newLength) new bytes but sends \(data.count)")
        }
        if oldLength != current.count {
            writeErrors.append("\(what): says old length \(oldLength) but it is \(current.count)")
        }
    }

    private func track(_ index: QueryValue) -> FakeTrack? {
        tracks.indices.contains(index.int) ? tracks[index.int] : nil
    }

    private func discTitleReply(wchar: Int, remaining: Int, done: Int) throws -> [UInt8] {
        let bytes = encodeToSJIS(wchar == 1 ? rawFullWidthTitle : rawTitle)
        if remaining == 0 {
            return try formatQuery(
                "1806 02201801 00%b 3000 0a00 1000 %w0000 0000000a %w %*",
                .init(wchar), .init(bytes.count + 6), .init(bytes.count), .bytes(bytes)
            )
        }
        let chunk = Array(bytes[done...])
        return try formatQuery(
            "1806 02201801 00%b 3000 0a00 1000 %w0000 %*", .init(wchar), .init(chunk.count), .bytes(chunk)
        )
    }
}

private func formatQuery(_ format: String, _ args: [QueryValue]) throws -> [UInt8] {
    // Splices an argument array into the variadic formatQuery by formatting one placeholder at a time.
    var output: [UInt8] = []
    var remainingArgs = args[...]
    var pieces = format.components(separatedBy: "%")
    output += try NetMDKit.formatQuery(pieces.removeFirst())
    for piece in pieces {
        let specifierLength = piece.first == "<" || piece.first == ">" ? 2 : 1
        let specifier = String(piece.prefix(specifierLength))
        output += try NetMDKit.formatQuery("%" + specifier, remainingArgs.removeFirst())
        output += try NetMDKit.formatQuery(String(piece.dropFirst(specifierLength)))
    }
    return output
}
