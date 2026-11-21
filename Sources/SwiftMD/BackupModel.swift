import AppKit
import os
import Foundation
import NetMDKit

/// The files saved for each track, collected from the device's save callbacks.
actor SavedFiles {
    private(set) var files: [Int: [String]] = [:]
    func add(_ index: Int, _ names: [String]) { files[index] = names }
}

/// Playable copies being made while the player reads the next track.
actor PlayableCopies {
    private var jobs: [(track: Int, name: String, task: Task<Int, Error>)] = []

    func add(track: Int, _ name: String, _ task: Task<Int, Error>) { jobs.append((track, name, task)) }

    /// Waits for every copy; returns what went wrong with the ones that failed or had unreadable
    /// stretches, by track.
    func finish() async -> [(track: Int, problem: String)] {
        var problems: [(track: Int, problem: String)] = []
        for job in jobs {
            do {
                if try await job.task.value > 0 { problems.append((job.track, "\(job.name) (has silent gaps)")) }
            } catch {
                problems.append((job.track, "\(job.name): \(error)"))
            }
        }
        jobs = []
        return problems
    }
}

/// What copyTracks managed, even when it stopped early.
struct CopyResult {
    /// The files of each track (zero-based index) that was copied completely and whose playable
    /// copy decoded without trouble.
    var files: [Int: [String]] = [:]
    /// Trouble with playable copies (those tracks aren't in `files`).
    var problems: [String] = []
    /// Why the copy stopped, or BackupError.incomplete for tracks that couldn't be read completely.
    var failure: Error?
}

extension DeviceModel {
    /// Copies tracks (zero-based) off the disc into `folder` as exact ATRAC files, plus a playable
    /// .m4a of each in `folder/Playable`. Returns the tracks that are done (copied completely, and
    /// their playable copy decoded cleanly) and what went wrong, even if it stopped early. A track
    /// that couldn't be read completely is saved as "… (incomplete)" for what it's worth, but isn't
    /// done. Shows progress; stops early when Stop is clicked.
    func copyTracks(_ indexes: [Int], titles: [String?], to folder: URL,
                    using service: any DeviceService) async -> CopyResult {
        let count = indexes.count
        let playable = PlayableCopies()
        let playableFolder = folder.appendingPathComponent("Playable", isDirectory: true)
        let saved = SavedFiles()
        var failure: Error?
        do {
            try await service.backUp(
                tracks: indexes,
                alsoAllowedFirmware: allowedFirmware,
                progress: { [weak self] i, p in
                    let label = "Backing up \(count == 1 ? "track \(indexes[i] + 1)" : "\(i + 1) of \(count)")"
                        + (titles[i].map { ": \($0)" } ?? "")
                    let text = p.action == .seek ? "\(label) (waiting for the player)…" : "\(label)…"
                    let fraction = (Double(i) + Double(p.read) / Double(max(p.total, 1))) / Double(count)
                    Task { @MainActor in self?.setActivity(text, progress: min(fraction, 1)) }
                },
                isCancelled: { [stopRequest] in stopRequest.isSet },
                save: { i, track in
                    let name = backupFileName(trackNumber: indexes[i] + 1, title: titles[i], fileExtension: track.fileExtension)
                    guard track.complete else {
                        // Keep what was read, clearly marked; it isn't counted as backed up.
                        let partial = (name as NSString).deletingPathExtension + " (incomplete)." + track.fileExtension
                        try Data(track.data).write(to: uniqueURL(in: folder, name: partial), options: .atomic)
                        return
                    }
                    let raw = uniqueURL(in: folder, name: name)
                    try Data(track.data).write(to: raw, options: .atomic)
                    // Make the playable copy in the background while the player reads the next track.
                    try FileManager.default.createDirectory(at: playableFolder, withIntermediateDirectories: true)
                    let m4a = uniqueURL(in: playableFolder, name: backupFileName(trackNumber: indexes[i] + 1, title: titles[i], fileExtension: "m4a"))
                    let job = Task.detached(priority: .utility) {
                        try makePlayableCopy(of: track.data, fileExtension: track.fileExtension, to: m4a)
                    }
                    await playable.add(track: indexes[i], m4a.lastPathComponent, job)
                    await saved.add(indexes[i], [raw.lastPathComponent, "Playable/" + m4a.lastPathComponent])
                }
            )
        } catch {
            failure = error
        }
        setActivity("Making playable copies…", progress: 1)
        let problems = await playable.finish()
        var files = await saved.files
        for problem in problems { files[problem.track] = nil }
        return CopyResult(files: files, problems: problems.map(\.problem), failure: failure)
    }

    /// Copies tracks into a folder the user chose.
    func backUp(_ indexes: [Int], to folder: URL) {
        guard let service = currentService, !isBusy, !indexes.isEmpty, let disc else { return }
        let titles = indexes.map { i in disc.tracks.first { $0.index == i }?.title }
        isBackingUp = true
        stopRequest.reset()
        lastBackupFolder = nil
        errorMessage = nil
        setActivity("Starting backup…", progress: 0)

        uploadTask = Task {
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            do {
                let result = await copyTracks(indexes, titles: titles, to: folder, using: service)
                if let failure = result.failure { throw failure }
                if !result.problems.isEmpty {
                    errorMessage = "The backup worked, but some playable copies had trouble: \(result.problems.joined(separator: "; "))"
                }
                if !stopRequest.isSet { lastBackupFolder = folder }
            } catch ExploitError.untestedFirmware(let version) {
                needsFirmwareOK(version) { [weak self] in self?.backUp(indexes, to: folder) }
            } catch let error as BackupError {
                errorMessage = "The backup finished with trouble: \(error)"
                lastBackupFolder = folder
            } catch {
                errorMessage = "Backup failed: \(error)"
            }
            finishUpload()
            await refresh()
        }
    }

    /// Asks the backup to stop after the current sector. The task isn't cancelled: that would cut
    /// the player's clean-up short (see uninterruptibleSleep), and SwiftMD's code must come out first.
    func cancelBackup() {
        stopRequest.set()
        setActivity("Stopping…", progress: uploadProgress)
    }

    /// Asks where to save a backup. Returns nil if the user cancels.
    func chooseBackupFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Back Up to Mac"
        panel.message = "Choose a folder for the backed-up tracks."
        panel.prompt = "Back Up Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// A stop request that the backup checks from the player's side of the app.
final class StopFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
    func reset() { state.withLock { $0 = false } }
}
