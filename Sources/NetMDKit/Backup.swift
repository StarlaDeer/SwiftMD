// Disc backup for the app: copies tracks off the disc with AtracDownloader, one homebrew-mode
// session for the whole batch (as Web MiniDisc Pro's exploitDownloadTracks does).

import Foundation

public enum BackupError: Error, Equatable, CustomStringConvertible {
    /// These tracks (zero-based) couldn't be copied completely: the player kept returning unreadable
    /// sectors, so each stopped early to spare its laser. The other tracks were copied.
    case incomplete(tracks: [Int])

    public var description: String {
        switch self {
        case .incomplete(let tracks):
            let names = tracks.map { String($0 + 1) }
            let list = names.count == 1 ? "Track \(names[0])" : "Tracks \(names.dropLast().joined(separator: ", ")) and \(names.last!)"
            return "\(list) couldn't be read completely: the player kept returning unreadable sectors. The other tracks were copied."
        }
    }
}

extension NetMDInterface {
    /// Copies `tracks` (zero-based) off the disc. Each finished track goes to `save` with its position
    /// in `tracks`. Checks `isCancelled` between sectors; a cancelled track isn't saved. A track with
    /// too many unreadable sectors is saved as far as it was read (marked incomplete) and the copy
    /// carries on with the next one; at the end it throws BackupError.incomplete naming them.
    public func backUp(
        tracks: [Int],
        alsoAllowedFirmware: Set<String>,
        progress: @escaping @Sendable (Int, DownloadProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool,
        save: @escaping @Sendable (Int, DownloadedTrack) async throws -> Void
    ) async throws {
        try await download(tracks: tracks, sectorLimit: nil, alsoAllowedFirmware: alsoAllowedFirmware,
                           progress: progress, isCancelled: isCancelled, save: save)
    }

    /// Reads the first `sectors` sectors of each of `tracks` (zero-based), the same way a backup
    /// does, to compare the disc's audio with an archived copy. Read-only, like a backup.
    public func sampleTracks(_ tracks: [Int], sectors: Int, alsoAllowedFirmware: Set<String>) async throws -> [Int: DownloadedTrack] {
        let samples = SampleBox()
        try await download(tracks: tracks, sectorLimit: sectors, alsoAllowedFirmware: alsoAllowedFirmware,
                           progress: { _, _ in }, isCancelled: { false }) { i, track in
            await samples.set(tracks[i], track)
        }
        return await samples.value
    }

    private func download(
        tracks: [Int],
        sectorLimit: Int?,
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
        // Type-S players have a known crash safety net (HFEC) on S1.000 and S1.400-S1.600 only; on
        // other Type-S firmware a crash could scramble the player's settings memory, so SwiftMD
        // doesn't try. (No Type-R firmware has one; Type-R is how Web MiniDisc Pro runs too.)
        if version.hasPrefix("S") && versionStoreLookup(SafetyPatches.hfecAddress, version: version) == nil {
            throw ExploitError.unsupportedFirmware(version)
        }
        if !AtracDownloader.testedFirmware.contains(version) && !alsoAllowedFirmware.contains(version) {
            throw ExploitError.untestedFirmware(version)
        }
        let session = try await ExploitSession.create(device: self, factory: factory)
        var downloader: AtracDownloader?
        var incomplete: [Int] = []
        do {
            let reader = try await AtracDownloader.fastest(session: session)
            downloader = reader
            for (i, track) in tracks.enumerated() {
                if isCancelled() { break }
                let result = try await reader.downloadTrack(track, sectorLimit: sectorLimit, progress: { progress(i, $0) }, isCancelled: isCancelled)
                if isCancelled() { break }
                try await save(i, result)
                if !result.complete && sectorLimit == nil { incomplete.append(track) }
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
        if !incomplete.isEmpty { throw BackupError.incomplete(tracks: incomplete) }
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

private actor SampleBox {
    var value: [Int: DownloadedTrack] = [:]
    func set(_ track: Int, _ sample: DownloadedTrack) { value[track] = sample }
}
