import Foundation
import NetMDKit

/// A file waiting to be sent to the disc.
struct PendingUpload: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    var title: String
    let duration: Double
}

enum UploadError: Error, CustomStringConvertible {
    case notEnoughSpace(needed: Double, available: Double)

    var description: String {
        switch self {
        case let .notEnoughSpace(needed, available):
            return "These tracks need \(minutes(needed)) of disc time, but only \(minutes(available)) is left. Try LP2 or LP4, or send fewer tracks."
        }
    }
}

func minutes(_ seconds: Double) -> String {
    let s = Int(seconds.rounded(.up))
    return String(format: "%d:%02d", s / 60, s % 60)
}

extension DeviceModel {
    /// Seconds of disc time left.
    var secondsLeft: Double { Double(disc?.left ?? 0) / Double(framesPerSecond) }

    /// Reads titles and lengths for dropped or chosen files. Files that can't be read are reported.
    func pendingUploads(for urls: [URL]) async -> [PendingUpload] {
        var result: [PendingUpload] = []
        var unreadable: [String] = []
        for url in urls {
            if let duration = try? audioDuration(at: url) {
                result.append(PendingUpload(url: url, title: await suggestedTitle(for: url), duration: duration))
            } else {
                unreadable.append(url.lastPathComponent)
            }
        }
        if !unreadable.isEmpty {
            errorMessage = "These files couldn't be read as audio: \(unreadable.joined(separator: ", "))"
        }
        return result
    }

    /// Converts each file, then sends them all in one session.
    func upload(_ files: [PendingUpload], format: UploadFormat) {
        guard let service = currentService, !isBusy, !files.isEmpty else { return }
        let needed = files.reduce(0) { $0 + $1.duration * format.discTimeFactor }
        guard needed <= secondsLeft else {
            errorMessage = String(describing: UploadError.notEnoughSpace(needed: needed, available: secondsLeft))
            return
        }

        uploadTask = Task {
            let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftMD-\(UUID())")
            defer { try? FileManager.default.removeItem(at: workDir) }
            do {
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                // Convert everything first, so the device isn't kept waiting in its secure session.
                var encoded: [URL] = []
                for (i, file) in files.enumerated() {
                    try Task.checkCancellation()
                    setActivity("Converting \(i + 1) of \(files.count): \(file.title)…", progress: Double(i) / Double(files.count) * 0.3)
                    let destination = workDir.appendingPathComponent("\(i).bin")
                    try await Task.detached(priority: .userInitiated) {
                        let audio = try decodeAudio(at: file.url)
                        try Data(encodeTrackData(audio, format: format)).write(to: destination)
                    }.value
                    encoded.append(destination)
                }

                setActivity("Sending 1 of \(files.count): \(files[0].title)…", progress: 0.3)
                let titles = files.map(\.title)
                let wireformat = format
                let encodedFiles = encoded
                try await service.upload(
                    count: files.count,
                    prepare: { i in
                        MDTrack(title: titles[i], format: wireformat.wire, data: Array(try Data(contentsOf: encodedFiles[i])))
                    },
                    progress: { [weak self] i, p in
                        let fraction = 0.3 + 0.7 * (Double(i) + Double(p.writtenBytes) / Double(max(p.totalBytes, 1))) / Double(titles.count)
                        let text = p.writtenBytes < p.totalBytes
                            ? "Sending \(i + 1) of \(titles.count): \(titles[i])…"
                            : "Writing \(titles[i]) to disc…"
                        Task { @MainActor in self?.setActivity(text, progress: fraction) }
                    }
                )
                hasUnwrittenChanges = true
            } catch is CancellationError {
                // Stopped before sending; nothing reached the disc.
            } catch {
                errorMessage = "Upload failed: \(error)"
            }
            finishUpload()
            await refresh()
        }
    }

    func cancelUpload() {
        uploadTask?.cancel()
        setActivity("Stopping after the current track…", progress: uploadProgress)
    }
}

extension UploadFormat {
    var wire: Wireformat {
        switch self {
        case .sp: return .pcm
        case .lp2: return .lp2
        case .lp4: return .lp4
        }
    }

    var explanation: String {
        switch self {
        case .sp: return "Best quality. The recorder encodes it, so it plays on any MiniDisc player."
        case .lp2: return "Twice as much music. Plays only on MDLP players (most NetMD models)."
        case .lp4: return "Four times as much music, lower quality. MDLP players only."
        }
    }
}
