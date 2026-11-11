import Foundation
import Testing
@testable import NetMDKit

/// Round trip through SwiftMD's own encoder (atracdenc) and the ATRAC3 decoder ported from FFmpeg.
/// Bit-exactness against FFmpeg was checked separately on a real LP2 backup.
@Suite struct AtracDecodingTests {
    /// Two seconds of different tones left and right.
    static let tone: PCMAudio = {
        var s = [Float](repeating: 0, count: 44100 * 2 * 2)
        for i in 0..<44100 * 2 {
            s[2 * i] = 0.4 * sin(2 * .pi * 440 * Float(i) / 44100)
            s[2 * i + 1] = 0.3 * sin(2 * .pi * 660 * Float(i) / 44100)
        }
        return PCMAudio(samples: s)
    }()

    /// Correlation between `a` and `b` delayed by the best lag (codec delay), per channel.
    func similarity(_ a: [Float], _ b: [Float], channel: Int) -> Double {
        var best = 0.0
        for lag in stride(from: 0, through: 4096, by: 1) {
            var ab = 0.0, aa = 0.0, bb = 0.0
            for i in stride(from: 20000, to: 70000, by: 5) {
                let x = Double(a[2 * i + channel]), y = Double(b[2 * (i + lag) + channel])
                ab += x * y; aa += x * x; bb += y * y
            }
            best = max(best, ab / (aa * bb).squareRoot())
        }
        return best
    }

    func roundTrip(_ format: UploadFormat) throws -> PCMAudio {
        let encoded = try encodeTrackData(Self.tone, format: format)
        let file = atrac3WavHeader(lp4: format == .lp4, bytes: encoded.count) + encoded
        if let dir = ProcessInfo.processInfo.environment["SWIFTMD_TEST_OUT"] {
            try Data(file).write(to: URL(fileURLWithPath: dir).appendingPathComponent("tone-\(format.rawValue).wav"))
        }
        let (decoded, bad) = try decodeATRAC3WAV(file)
        #expect(bad == 0)
        #expect(abs(decoded.duration - Self.tone.duration) < 0.1)
        return decoded
    }

    @Test func lp2() throws {
        let out = try roundTrip(.lp2)
        #expect(similarity(Self.tone.samples, out.samples, channel: 0) > 0.98)
        #expect(similarity(Self.tone.samples, out.samples, channel: 1) > 0.98)
    }

    @Test func lp4JointStereo() throws {
        let out = try roundTrip(.lp4)
        #expect(similarity(Self.tone.samples, out.samples, channel: 0) > 0.95)
        #expect(similarity(Self.tone.samples, out.samples, channel: 1) > 0.95)
    }

    // MARK: Against FFmpeg (ElectronWMD's build), on files in Fixtures/atrac

    func fixture(_ name: String) throws -> [UInt8] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/atrac"))
        return Array(try Data(contentsOf: url))
    }

    /// FFmpeg's 16-bit output, interleaved.
    func ffmpegPCM(_ name: String) throws -> [Int16] {
        let wav = try fixture(name)
        let dataStart = (0..<wav.count - 4).first { Array(wav[$0..<$0 + 4]) == Array("data".utf8) }! + 8
        return stride(from: dataStart, to: wav.count - 1, by: 2).map { Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8) }
    }

    func expectMatchesFFmpeg(_ audio: PCMAudio, _ reference: [Int16]) {
        #expect(audio.samples.count == reference.count)
        var maxDiff = 0
        for (s, r) in zip(audio.samples, reference) {
            let ours = Int(max(-32768, min(32767, (s * 32768).rounded())))
            maxDiff = max(maxDiff, abs(ours - Int(r)))
        }
        #expect(maxDiff <= 1, "differs from FFmpeg by up to \(maxDiff)")
    }

    @Test func lp2MatchesFFmpeg() throws {
        let (audio, bad) = try decodeATRAC3WAV(try fixture("tone-lp2.wav"))
        #expect(bad == 0)
        expectMatchesFFmpeg(audio, try ffmpegPCM("tone-lp2.ffmpeg.wav"))
    }

    @Test func lp4MatchesFFmpeg() throws {
        let (audio, bad) = try decodeATRAC3WAV(try fixture("tone-lp4.wav"))
        #expect(bad == 0)
        expectMatchesFFmpeg(audio, try ffmpegPCM("tone-lp4.ffmpeg.wav"))
    }

    /// Random valid ATRAC1 frames covering long and short blocks in all three bands.
    @Test func spMatchesFFmpeg() throws {
        let (audio, bad) = try decodeAEA(try fixture("random-sp.aea"))
        #expect(bad == 0)
        expectMatchesFFmpeg(audio, try ffmpegPCM("random-sp.ffmpeg.wav"))
    }

    /// The app makes playable copies of several tracks at once; the shared tables must be safe for that.
    @Test func decodesInParallel() async throws {
        let lp2 = try fixture("tone-lp2.wav"), sp = try fixture("random-sp.aea")
        let lp2Reference = try ffmpegPCM("tone-lp2.ffmpeg.wav"), spReference = try ffmpegPCM("random-sp.ffmpeg.wav")
        try await withThrowingTaskGroup(of: (PCMAudio, Bool).self) { group in
            for i in 0..<8 {
                group.addTask {
                    i % 2 == 0 ? (try decodeATRAC3WAV(lp2).audio, true) : (try decodeAEA(sp).audio, false)
                }
            }
            for try await (audio, isLP2) in group {
                expectMatchesFFmpeg(audio, isLP2 ? lp2Reference : spReference)
            }
        }
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: AtracDecodingError.self) { try decodeATRAC3WAV(Array("RIFF\0\0\0\0WAVEfmt ".utf8)) }
    }
}
