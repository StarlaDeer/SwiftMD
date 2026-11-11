import AVFoundation
import CommonCrypto
import Foundation
import Testing
@testable import NetMDKit

@Suite struct CryptoTests {
    @Test func desMatchesFIPSVector() throws {
        // FIPS 46 / Stinson worked example.
        let out = try des(CCOperation(kCCEncrypt), key: [0x13, 0x34, 0x57, 0x79, 0x9b, 0xbc, 0xdf, 0xf1], .ecb,
                          [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef])
        #expect(out == [0x85, 0xe8, 0x13, 0x54, 0x0f, 0x0a, 0xb4, 0x05])
    }

    @Test func retailMACMatchesOpenSSL() throws {
        // Computed independently with `openssl enc -des-cbc` then `-des-ede-cbc` (two-key 3DES).
        let mac = try retailMAC(key: EKB.openSource.rootKey, value: Array(0..<16))
        #expect(mac == [0x4e, 0xaf, 0x5d, 0xa7, 0x59, 0x3a, 0xe4, 0xd6])
    }

    @Test func encryptedStreamRoundTrips() throws {
        let data: [UInt8] = (0..<5000).map { UInt8($0 % 251) }
        let track = MDTrack(title: "x", format: .lp4, data: data)
        #expect(track.totalSize == 5088) // padded to a multiple of 96
        #expect(track.frameCount == 53)

        let dataKey: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let stream = try track.encryptedStream(dataKey: dataKey)
        #expect(stream.count == 24 + 5088)
        #expect(Array(stream[0..<8]) == [0, 0, 0, 0, 0x00, 0x00, 0x13, 0xe0]) // big-endian 5088
        let unwrapped = try des(CCOperation(kCCEncrypt), key: MDTrack.kek, .ecb, Array(stream[8..<16]))
        #expect(unwrapped == dataKey)
        let plain = try des(CCOperation(kCCDecrypt), key: dataKey, .cbc(iv: Array(stream[16..<24])), Array(stream[24...]))
        #expect(Array(plain.prefix(5000)) == data)
        #expect(plain.suffix(88).allSatisfy { $0 == 0 })
    }
}

@Suite struct AudioTests {
    /// Writes a 48 kHz stereo WAV: 440 Hz left, 660 Hz right.
    static func makeTone(seconds: Double, sampleRate: Double = 48000, channels: AVAudioChannelCount = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftmd-tone-\(UUID()).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
        ])
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            let freq = ch == 0 ? 440.0 : 660.0
            for i in 0..<Int(frames) {
                buffer.floatChannelData![ch][i] = Float(0.4 * sin(2 * .pi * freq * Double(i) / sampleRate))
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test func decodesAndResamplesTo44100Stereo() throws {
        let url = try Self.makeTone(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = try decodeAudio(at: url)
        #expect(abs(audio.frameCount - 88200) < 64)
        let peak = audio.samples.map(abs).max() ?? 0
        #expect(peak > 0.35 && peak < 0.45)
    }

    @Test func monoIsCopiedToBothChannels() throws {
        let url = try Self.makeTone(seconds: 0.5, sampleRate: 44100, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = try decodeAudio(at: url)
        for i in stride(from: 0, to: 2000, by: 2) {
            #expect(audio.samples[i] == audio.samples[i + 1])
        }
    }

    @Test func spIsBigEndian16Bit() throws {
        let audio = PCMAudio(samples: [0.5, -0.5, 1.0, -1.0])
        let data = try encodeTrackData(audio, format: .sp)
        #expect(data == [0x3f, 0xff, 0xc0, 0x01, 0x7f, 0xff, 0x80, 0x01])
    }

    @Test(arguments: [(UploadFormat.lp2, 384), (UploadFormat.lp4, 192)])
    func atrac3FramesLookRight(format: UploadFormat, frameSize: Int) throws {
        let url = try Self.makeTone(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = try decodeAudio(at: url)
        let data = try encodeTrackData(audio, format: format)

        // One frame per 1024 samples, plus the encoder's delay.
        let frames = data.count / frameSize
        #expect(data.count % frameSize == 0)
        #expect(frames >= audio.frameCount / 1024 && frames <= audio.frameCount / 1024 + 4)
        // Bitrate: 44100 / 1024 frames per second.
        let kbps = Double(frameSize * 8) * 44100 / 1024 / 1000
        #expect(abs(kbps - (format == .lp2 ? 132.3 : 66.2)) < 0.5)
        // Every ATRAC3 sound unit (192 bytes in LP2, one per channel; the whole LP4 frame) starts with ID 0x28.
        for unit in stride(from: 0, to: data.count, by: 192) {
            #expect(data[unit] >> 2 == 0x28, "sound unit at \(unit) has header \(String(data[unit], radix: 16))")
        }
        #expect(data.contains { $0 != 0 })
    }
}

@Suite struct UploadSessionTests {
    func makeDevice() -> FakeNetMDDevice {
        FakeNetMDDevice(rawTitle: "", tracks: [.init(title: "Existing", length: [0, 3, 0, 0])])
    }

    @Test func uploadsAnSPTrack() async throws {
        let device = makeDevice()
        let iface = try await NetMDInterface.open(transport: device, vendorID: 0x054c, productID: 0x00c7)
        let pcm = (0..<10_000).map { UInt8(truncatingIfNeeded: $0 * 7) }

        let session = try await UploadSession.start(on: iface)
        #expect(device.acquired)
        #expect(device.inSecureSession)
        #expect(device.receivedEKBID == 0x2642_2642)

        let progress = ProgressLog()
        let index = try await session.send(MDTrack(title: "Café Tone", format: .pcm, data: pcm)) { progress.add($0) }
        await session.close()

        #expect(index == 1)
        #expect(device.writeErrors.isEmpty)
        #expect(device.committedTracks == [1])
        let track = device.tracks[1]
        #expect(track.title == "Cafe Tone")
        #expect(track.wireformat == Wireformat.pcm.rawValue)
        #expect(track.discFormat == DiscFormat.spStereo.rawValue)
        #expect(Array(track.uploadedData!.prefix(pcm.count)) == pcm)
        #expect(track.uploadedData!.count == 10_240) // padded to a whole 2048-byte frame
        #expect(!device.inSecureSession)
        #expect(!device.acquired)
        #expect(progress.last?.writtenBytes == progress.last?.totalBytes)
    }

    @Test func uploadsSeveralLPTracksInOneSession() async throws {
        let device = makeDevice()
        let iface = try await NetMDInterface.open(transport: device, vendorID: 0x054c, productID: 0x00c7)
        let session = try await UploadSession.start(on: iface)
        try await session.send(MDTrack(title: "A", format: .lp2, data: [UInt8](repeating: 0xa0, count: 384 * 10)))
        try await session.send(MDTrack(title: "B", fullWidthTitle: "ビー", format: .lp4, data: [UInt8](repeating: 0xa1, count: 192 * 10)))
        await session.close()

        #expect(device.writeErrors.isEmpty)
        #expect(device.committedTracks == [1, 2])
        #expect(device.tracks[1].discFormat == DiscFormat.lp2.rawValue)
        #expect(device.tracks[2].wireformat == Wireformat.lp4.rawValue)
        #expect(device.tracks[2].fullWidthTitle == "ビー")
    }

    @Test func rejectedRecordingIsReportedPlainly() async throws {
        let device = makeDevice()
        device.failRecording = true
        let iface = try await NetMDInterface.open(transport: device, vendorID: 0x054c, productID: 0x00c7)
        await #expect(throws: UploadFailure.recorderRejectedTrack) {
            try await UploadSession.upload(count: 1, to: iface, prepare: { _ in
                MDTrack(title: "X", format: .pcm, data: [UInt8](repeating: 1, count: 4096))
            })
        }
        #expect(device.tracks.count == 1)
        #expect(device.committedTracks.isEmpty)
        // The session is still closed properly.
        #expect(!device.inSecureSession)
        #expect(!device.acquired)
    }

    @Test func largeTrackIsSentInChunks() async throws {
        let device = makeDevice()
        let iface = try await NetMDInterface.open(transport: device, vendorID: 0x054c, productID: 0x00c7)
        let session = try await UploadSession.start(on: iface)
        let data = (0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        try await session.send(MDTrack(title: "Long", format: .pcm, data: data))
        await session.close()
        #expect(device.writeErrors.isEmpty)
        #expect(Array(device.tracks[1].uploadedData!.prefix(data.count)) == data)
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UploadProgress] = []
    func add(_ p: UploadProgress) { lock.withLock { entries.append(p) } }
    var last: UploadProgress? { lock.withLock { entries.last } }
}
