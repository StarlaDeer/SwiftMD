// SwiftMD - turning audio files into NetMD track data.
// Replaces Web MiniDisc's ffmpeg (decode/resample) and atracdenc (WASM) steps with
// AVFoundation and the vendored atracdenc encoder.

@preconcurrency import AVFoundation
import CAtracDEnc
import Foundation

public enum UploadFormat: String, CaseIterable, Identifiable, Sendable {
    case sp = "SP"
    case lp2 = "LP2"
    case lp4 = "LP4"

    public var id: String { rawValue }

    var wireformat: Wireformat {
        switch self {
        case .sp: return .pcm
        case .lp2: return .lp2
        case .lp4: return .lp4
        }
    }

    /// atracdenc --bitrate value, as Web MiniDisc passes it.
    var atracBitrate: UInt32 {
        switch self {
        case .sp: return 0
        case .lp2: return 128
        case .lp4: return 64
        }
    }

    /// How much disc time a second of audio uses (an 80-minute disc holds 160 minutes of LP2).
    public var discTimeFactor: Double {
        switch self {
        case .sp: return 1
        case .lp2: return 0.5
        case .lp4: return 0.25
        }
    }
}

public enum AudioError: Error, CustomStringConvertible {
    case unreadable(String)
    case conversionFailed(String)
    case encoderFailed(Int32)

    public var description: String {
        switch self {
        case .unreadable(let m): return "Couldn't read the audio file: \(m)"
        case .conversionFailed(let m): return "Couldn't convert the audio: \(m)"
        case .encoderFailed(let code): return "The ATRAC3 encoder failed (code \(code))."
        }
    }
}

/// Stereo 44.1 kHz audio, interleaved, samples in -1...1.
public struct PCMAudio: Sendable {
    public var samples: [Float]

    public init(samples: [Float]) {
        self.samples = samples
    }

    public var frameCount: Int { samples.count / 2 }
    public var duration: Double { Double(frameCount) / 44100 }
}

/// Decodes any file AVFoundation can read (MP3, AAC/M4A, WAV, AIFF, FLAC, ALAC…) to CD-format PCM.
public func decodeAudio(at url: URL) throws -> PCMAudio {
    let file: AVAudioFile
    do {
        file = try AVAudioFile(forReading: url)
    } catch {
        throw AudioError.unreadable(error.localizedDescription)
    }
    let source = file.processingFormat
    let isMono = source.channelCount == 1
    guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100,
                                     channels: isMono ? 1 : 2, interleaved: true),
          let converter = AVAudioConverter(from: source, to: target)
    else { throw AudioError.conversionFailed("unsupported format \(source)") }
    converter.downmix = source.channelCount > 2

    let inputCapacity: AVAudioFrameCount = 32768
    guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: inputCapacity) else {
        throw AudioError.conversionFailed("out of memory")
    }
    let outputCapacity = AVAudioFrameCount(Double(inputCapacity) * 44100 / source.sampleRate) + 1024
    var samples: [Float] = []
    samples.reserveCapacity(Int(Double(file.length) * 44100 / source.sampleRate) * 2)

    // The converter calls the input block synchronously; the box just carries a read error out of it.
    final class ErrorBox: @unchecked Sendable { var error: Error? }
    let readError = ErrorBox()
    var finished = false
    while !finished {
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else {
            throw AudioError.conversionFailed("out of memory")
        }
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            do {
                input.frameLength = 0
                // AVAudioFile reports an error, not an empty read, at the end of the file.
                if file.framePosition < file.length {
                    try file.read(into: input, frameCount: inputCapacity)
                }
            } catch {
                readError.error = error
            }
            if input.frameLength == 0 {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }
        if let error = readError.error { throw AudioError.unreadable(error.localizedDescription) }
        if status == .error { throw AudioError.conversionFailed(conversionError?.localizedDescription ?? "unknown error") }

        let channels = Int(target.channelCount)
        let pointer = output.floatChannelData![0]
        let count = Int(output.frameLength)
        if isMono {
            for i in 0..<count { samples.append(pointer[i]); samples.append(pointer[i]) }
        } else {
            samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count * channels))
        }
        finished = status == .endOfStream
    }
    return PCMAudio(samples: samples)
}

/// A file's length in seconds, read from its header without decoding it.
public func audioDuration(at url: URL) throws -> Double {
    do {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    } catch {
        throw AudioError.unreadable(error.localizedDescription)
    }
}

/// Encodes audio for the given format: 16-bit big-endian PCM for SP (the device encodes it),
/// ATRAC3 frames for LP2/LP4.
public func encodeTrackData(_ audio: PCMAudio, format: UploadFormat) throws -> [UInt8] {
    switch format {
    case .sp:
        var out = [UInt8](repeating: 0, count: audio.samples.count * 2)
        for (i, sample) in audio.samples.enumerated() {
            let value = Int16(max(-1, min(1, sample)) * 32767)
            out[i * 2] = UInt8(truncatingIfNeeded: value >> 8)
            out[i * 2 + 1] = UInt8(truncatingIfNeeded: value)
        }
        return out
    case .lp2, .lp4:
        var output: UnsafeMutablePointer<UInt8>?
        var length = 0
        var frameSize = 0
        let status = audio.samples.withUnsafeBufferPointer {
            atracdenc_encode_atrac3($0.baseAddress, UInt64(audio.frameCount), format.atracBitrate, &output, &length, &frameSize)
        }
        guard status == 0, let output else { throw AudioError.encoderFailed(status) }
        defer { atracdenc_free(output) }
        return Array(UnsafeBufferPointer(start: output, count: length))
    }
}

/// A title for a file: its metadata title (with artist, if any), or else its file name.
public func suggestedTitle(for url: URL) async -> String {
    let asset = AVURLAsset(url: url)
    if let metadata = try? await asset.load(.commonMetadata) {
        let title = try? await AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first?.load(.stringValue)
        let artist = try? await AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist).first?.load(.stringValue)
        if let title, !title.isEmpty {
            if let artist, !artist.isEmpty { return "\(artist) - \(title)" }
            return title
        }
    }
    return url.deletingPathExtension().lastPathComponent
}
