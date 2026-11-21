// Turns disc backups (exact ATRAC copies) back into PCM, so they can be saved as playable files.

import CAtrac3Dec
import Foundation

public enum AtracDecodingError: Error, CustomStringConvertible {
    case notATRAC3WAV
    case unsupported(String)

    public var description: String {
        switch self {
        case .notATRAC3WAV: return "This isn't an ATRAC3 WAV file."
        case .unsupported(let s): return s
        }
    }
}

/// Decodes an ATRAC3 WAV (as SwiftMD's LP backups are saved) to 44.1 kHz stereo float PCM.
/// Frames that can't be decoded come out as silence; `badFrames` counts them.
public func decodeATRAC3WAV(_ file: [UInt8]) throws -> (audio: PCMAudio, badFrames: Int) {
    func le16(_ o: Int) -> Int { Int(file[o]) | Int(file[o + 1]) << 8 }
    func le32(_ o: Int) -> Int { le16(o) | le16(o + 2) << 16 }
    guard file.count >= 12, Array(file[0..<4]) == Array("RIFF".utf8), Array(file[8..<12]) == Array("WAVE".utf8) else {
        throw AtracDecodingError.notATRAC3WAV
    }
    var offset = 12
    var blockAlign = 0
    var jointStereo = false
    var data: ArraySlice<UInt8>?
    while offset + 8 <= file.count {
        let id = String(decoding: file[offset..<offset + 4], as: UTF8.self)
        let size = le32(offset + 4)
        let body = offset + 8
        if id == "fmt " {
            guard le16(body) == 0x270 else { throw AtracDecodingError.notATRAC3WAV }
            guard le16(body + 2) == 2 else { throw AtracDecodingError.unsupported("Only stereo ATRAC3 is supported.") }
            blockAlign = le16(body + 12)
            if size >= 32 { jointStereo = le16(body + 24) != 0 } // extradata coding mode
        } else if id == "data" {
            data = file[body..<min(body + size, file.count)]
        }
        offset = body + size + (size & 1)
    }
    guard blockAlign > 0, let data else { throw AtracDecodingError.notATRAC3WAV }
    guard let decoder = atrac3_decoder_create(Int32(blockAlign), jointStereo ? 1 : 0) else {
        throw AtracDecodingError.unsupported("Unsupported ATRAC3 frame size \(blockAlign).")
    }
    defer { atrac3_decoder_free(decoder) }

    let frames = data.count / blockAlign
    var left = [Float](repeating: 0, count: frames * 1024)
    var right = [Float](repeating: 0, count: frames * 1024)
    var bad = 0
    data.withUnsafeBufferPointer { bytes in
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                for f in 0..<frames {
                    if atrac3_decode_frame(decoder, bytes.baseAddress! + f * blockAlign, l.baseAddress! + f * 1024, r.baseAddress! + f * 1024) != 0 {
                        bad += 1
                    }
                }
            }
        }
    }
    var interleaved = [Float](repeating: 0, count: frames * 2048)
    for i in 0..<left.count {
        interleaved[2 * i] = left[i]
        interleaved[2 * i + 1] = right[i]
    }
    return (PCMAudio(samples: interleaved), bad)
}

/// Decodes an AEA file (ATRAC1, as SwiftMD's SP backups are saved) to 44.1 kHz stereo float PCM.
/// Mono is duplicated to both channels. Frames that can't be decoded come out as silence.
public func decodeAEA(_ file: [UInt8]) throws -> (audio: PCMAudio, badFrames: Int) {
    let headerSize = 2048
    guard file.count >= headerSize,
          Int(file[0]) | Int(file[1]) << 8 | Int(file[2]) << 16 | Int(file[3]) << 24 == headerSize else {
        throw AtracDecodingError.unsupported("This isn't an AEA (ATRAC1) file.")
    }
    let channels = Int(file[264])
    guard channels == 1 || channels == 2, let decoder = atrac1_decoder_create(Int32(channels)) else {
        throw AtracDecodingError.unsupported("Unsupported AEA channel count \(file[264]).")
    }
    defer { atrac1_decoder_free(decoder) }

    let frameSize = 212 * channels
    let frames = (file.count - headerSize) / frameSize
    var samples = [Float](repeating: 0, count: frames * 512 * 2)
    var left = [Float](repeating: 0, count: 512)
    var right = [Float](repeating: 0, count: 512)
    var bad = 0
    file.withUnsafeBufferPointer { bytes in
        for f in 0..<frames {
            if atrac1_decode_frame(decoder, bytes.baseAddress! + headerSize + f * frameSize, &left, &right) != 0 {
                bad += 1
            }
            for i in 0..<512 {
                samples[(f * 512 + i) * 2] = left[i]
                samples[(f * 512 + i) * 2 + 1] = channels == 2 ? right[i] : left[i]
            }
        }
    }
    return (PCMAudio(samples: samples), bad)
}

/// Decodes a disc backup (.aea or ATRAC3 .wav) to PCM.
public func decodeBackup(_ file: [UInt8], fileExtension: String) throws -> (audio: PCMAudio, badFrames: Int) {
    fileExtension.lowercased() == "aea" ? try decodeAEA(file) : try decodeATRAC3WAV(file)
}

import AVFoundation

public enum PlayableCopyError: Error, Equatable, CustomStringConvertible {
    case noBuffer
    case short(written: Int, expected: Int)

    public var description: String {
        switch self {
        case .noBuffer: return "the Mac ran out of memory for the audio"
        case .short(let written, let expected):
            return "the playable copy came out \(String(format: "%.1f", Double(expected - written) / 44100)) s shorter than the track"
        }
    }
}

/// Saves 44.1 kHz stereo PCM as an AAC .m4a file with Apple's encoder, then reads it back to make
/// sure it's all there (AVAudioFile only finishes the file when it's released, and says nothing if
/// that fails).
public func writeM4A(_ audio: PCMAudio, to url: URL, bitRate: Int = 256_000) throws {
    try encodeM4A(audio, to: url, bitRate: bitRate)
    let written = Int(try AVAudioFile(forReading: url).length)
    // AAC works in 1024-sample packets, so allow a few packets either way.
    guard abs(written - audio.frameCount) <= 4096 else {
        throw PlayableCopyError.short(written: written, expected: audio.frameCount)
    }
}

private func encodeM4A(_ audio: PCMAudio, to url: URL, bitRate: Int) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: bitRate,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = file.processingFormat
    let chunk = 44100
    var start = 0
    while start < audio.frameCount {
        let count = min(chunk, audio.frameCount - start)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { throw PlayableCopyError.noBuffer }
        buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<count {
            channels[0][i] = audio.samples[(start + i) * 2]
            channels[1][i] = audio.samples[(start + i) * 2 + 1]
        }
        try file.write(from: buffer)
        start += count
    }
}

/// Decodes a disc backup and saves a playable .m4a next to it. Returns the number of frames that
/// couldn't be decoded (written as silence).
@discardableResult
public func makePlayableCopy(of backup: [UInt8], fileExtension: String, to url: URL) throws -> Int {
    let (audio, bad) = try decodeBackup(backup, fileExtension: fileExtension)
    try writeM4A(audio, to: url)
    return bad
}
