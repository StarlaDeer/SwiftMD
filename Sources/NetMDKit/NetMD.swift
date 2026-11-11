// SwiftMD - port of netmd-js src/netmd.ts
// Original: Copyright (C) Stefano Brilli, Asivery (https://github.com/cybercase/netmd-js)
// Licensed under the GNU General Public License v2.0.

import Foundation

public enum NetMDError: Error, Equatable, CustomStringConvertible {
    case notImplemented(String)
    case rejected(String)
    case noReply
    case unsupportedDevice(String)

    public var description: String {
        switch self {
        case .notImplemented(let m): return "Not implemented: \(m)"
        case .rejected(let m): return "Rejected: \(m)"
        case .noReply: return "The device did not reply."
        case .unsupportedDevice(let m): return m
        }
    }
}

/// Low-level NetMD framing over the USB vendor interface: poll for reply length,
/// send a command, read the reply, and bulk transfers.
/// Only ever used from its owning `NetMDInterface` actor, which serializes access.
final class NetMD: @unchecked Sendable {
    static let readReplyRetryInterval: Duration = .milliseconds(10)
    static let maxReplyRetryInterval: Duration = .milliseconds(500)
    /// netmd-js retries forever with an ever-doubling wait. SwiftMD caps the wait between polls
    /// and gives up after a timeout: short for ordinary queries, long when the device is writing a track.
    static let replyTimeout: Duration = .seconds(10)
    static let patientReplyTimeout: Duration = .seconds(600)

    let transport: USBTransport
    let vendorID: Int
    let productID: Int

    init(transport: USBTransport, vendorID: Int, productID: Int) {
        self.transport = transport
        self.vendorID = vendorID
        self.productID = productID
    }

    var definition: DeviceDefinition? {
        knownDevices.first { $0.vendorID == vendorID && $0.productID == productID }
    }

    var deviceName: String { definition?.name ?? "Unknown Device" }

    func initialize() async throws {
        let len = try getReplyLength()
        if len > 0 {
            _ = try await readReply()
        }
    }

    func finalize() {
        transport.close()
    }

    func getReplyLength() throws -> Int {
        let data = try transport.controlIn(request: 0x01, length: 4)
        return data.count > 2 ? Int(data[2]) : 0
    }

    /// Set SWIFTMD_TRACE=1 to log every command, reply and bulk transfer to stderr.
    static let tracing = ProcessInfo.processInfo.environment["SWIFTMD_TRACE"] != nil

    static func trace(_ message: @autoclosure () -> String) {
        guard tracing else { return }
        FileHandle.standardError.write(Data("[netmd \(Date().formatted(.iso8601.time(includingFractionalSeconds: true)))] \(message())\n".utf8))
    }

    static func hex(_ bytes: [UInt8], limit: Int = 96) -> String {
        let shown = bytes.prefix(limit).map { String(format: "%02x", $0) }.joined()
        return bytes.count > limit ? "\(shown)… (\(bytes.count) bytes)" : shown
    }

    func sendCommand(_ command: [UInt8], factory: Bool = false) throws {
        Self.trace(">> \(Self.hex(command))")
        try transport.controlOut(request: factory ? 0xff : 0x80, data: command)
    }

    func readReply(factory: Bool = false, overrideLength: Int? = nil, patient: Bool = false) async throws -> [UInt8] {
        var len: Int
        if let overrideLength {
            len = overrideLength
        } else {
            len = try getReplyLength()
            let deadline = ContinuousClock.now + (patient ? Self.patientReplyTimeout : Self.replyTimeout)
            var wait = Self.readReplyRetryInterval
            while len == 0 {
                guard ContinuousClock.now < deadline else { throw NetMDError.noReply }
                try await Task.sleep(for: wait)
                wait = min(wait * 2, Self.maxReplyRetryInterval) // Double wait time every attempt, up to a limit
                len = try getReplyLength()
            }
        }
        let result = try transport.controlIn(request: factory ? 0xff : 0x81, length: len)
        Self.trace("<< \(Self.hex(result))")
        _ = try getReplyLength()
        return result
    }

    /// How long a bulk read may go without receiving any data before giving up.
    static let bulkStallTimeout: Duration = .seconds(30)

    /// Reads `length` bytes from the bulk IN endpoint. Like netmd-js's readBulkToArray, a transfer
    /// that completes with no data (a zero-length packet) just means "read again"; SwiftMD gives up
    /// only after `bulkStallTimeout` without any data.
    func readBulk(length: Int, chunkSize: Int = 0x10000, progress: ((Int, Int) -> Void)? = nil) throws -> [UInt8] {
        var buffer: [UInt8] = []
        buffer.reserveCapacity(length)
        var lastData = ContinuousClock.now
        var emptyReads = 0
        while buffer.count < length {
            let chunk = try transport.bulkIn(length: min(length - buffer.count, chunkSize))
            if chunk.isEmpty {
                emptyReads += 1
                guard ContinuousClock.now - lastData < Self.bulkStallTimeout else {
                    throw USBError.io("No bulk data for \(Self.bulkStallTimeout) (\(buffer.count) of \(length) bytes, \(emptyReads) empty reads)")
                }
                continue
            }
            lastData = ContinuousClock.now
            buffer.append(contentsOf: chunk)
            progress?(length, buffer.count)
        }
        if emptyReads > 0 { Self.trace("bulk read: \(emptyReads) zero-length transfers skipped") }
        return buffer
    }

    private var bulkBytesWritten = 0

    func writeBulk(_ data: [UInt8]) throws {
        try transport.bulkOut(data)
        // 1 KiB writes would flood the trace; log the first and then every MiB.
        if bulkBytesWritten % 0x100000 < data.count || bulkBytesWritten == 0 {
            Self.trace("bulk out \(data.count) bytes (\(bulkBytesWritten + data.count) so far)")
        }
        bulkBytesWritten += data.count
    }
}
