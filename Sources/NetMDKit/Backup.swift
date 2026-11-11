// Disc backup for the app: copies tracks off the disc with AtracDownloader, one homebrew-mode
// session for the whole batch (as Web MiniDisc Pro's exploitDownloadTracks does).

import Foundation

public enum BackupError: Error, Equatable, CustomStringConvertible {
    /// The player kept returning unreadable sectors, so the copy stopped early to spare its laser.
    case incomplete(track: Int)

    public var description: String {
        switch self {
        case .incomplete(let track):
            return "Track \(track + 1) couldn't be read completely: the player kept returning unreadable sectors. What was read has been saved."
        }
    }
}

extension NetMDInterface {
    /// Copies `tracks` (zero-based) off the disc. Each finished track goes to `save` with its position
    /// in `tracks`. Checks `isCancelled` between sectors; a cancelled track isn't saved.
    public func backUp(
        tracks: [Int],
        alsoAllowedFirmware: Set<String>,
        progress: @escaping @Sendable (Int, DownloadProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool,
        save: @escaping @Sendable (Int, DownloadedTrack) async throws -> Void
    ) async throws {
        try checkBackupSupported()
        try await stop()
        let factory = try await factory()
        guard factory.kind == .netmd else { throw ExploitError.unsupportedDevice(deviceName) }
        // Read-only: which firmware, before anything is loaded on the player.
        let version = try await factory.descriptiveDeviceCode()
        if !AtracDownloader.testedFirmware.contains(version) && !alsoAllowedFirmware.contains(version) {
            throw ExploitError.untestedFirmware(version)
        }
        let session = try await ExploitSession.create(device: self, factory: factory)
        var downloader: AtracDownloader?
        do {
            let reader = try await AtracDownloader.fastest(session: session)
            downloader = reader
            for (i, track) in tracks.enumerated() {
                if isCancelled() { break }
                let result = try await reader.downloadTrack(track, progress: { progress(i, $0) }, isCancelled: isCancelled)
                if isCancelled() { break }
                try await save(i, result)
                if !result.complete { throw BackupError.incomplete(track: track) }
            }
            try await reader.finish()
            try await session.close()
        } catch let error as ExploitError {
            // The player is stuck streaming or SwiftMD's code is still on it: talking to it more
            // won't help, and an unplug undoes everything.
            if case .bulkTransferFailed = error { throw error }
            if case .needsUnplug = error { throw error }
            try await tidyUp(downloader, session, after: error)
        } catch {
            try await tidyUp(downloader, session, after: error)
        }
    }

    /// After a failure: takes SwiftMD's code back out of the player. If that fails too, the error
    /// says to unplug the player; otherwise it's the original error.
    private func tidyUp(_ downloader: AtracDownloader?, _ session: ExploitSession, after error: Error) async throws -> Never {
        do {
            try await downloader?.finish()
            try await session.close()
        } catch let cleanup as ExploitError {
            if case .needsUnplug = cleanup { throw cleanup }
            throw ExploitError.needsUnplug("\(error); then \(cleanup)")
        } catch let cleanup as SlotMergeError {
            throw cleanup
        } catch let cleanup {
            throw ExploitError.needsUnplug("\(error); then \(cleanup)")
        }
        throw error
    }

    /// Backups use Sony's factory mode, so only Sony NetMD recorders.
    func checkBackupSupported() throws {
        guard vendorID == 0x054c else { throw ExploitError.unsupportedDevice(deviceName) }
    }
}

/// A file name for a backed-up track: "03 - Title.aea", without characters Finder dislikes.
public func backupFileName(trackNumber: Int, title: String?, fileExtension: String) -> String {
    let cleaned = (title ?? "")
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    let number = String(format: "%02d", trackNumber)
    return (cleaned.isEmpty ? number : "\(number) - \(cleaned)") + ".\(fileExtension)"
}

/// `name` in `folder`, or "name (2)", "name (3)"… if that file already exists.
public func uniqueURL(in folder: URL, name: String) -> URL {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var url = folder.appendingPathComponent(name)
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
        n += 1
    }
    return url
}
