import AppKit
import Foundation
import NetMDKit

/// Playable copies being made while the player reads the next track.
/// The files saved for each track, collected from the device's save callbacks.
actor SavedFiles {
    private(set) var files: [Int: [String]] = [:]
    func add(_ index: Int, _ names: [String]) { files[index] = names }
}

actor PlayableCopies {
    private var jobs: [(name: String, task: Task<Int, Error>)] = []

    func add(_ name: String, _ task: Task<Int, Error>) { jobs.append((name, task)) }

    /// Waits for every copy; returns the names that failed or had unreadable stretches.
    func finish() async -> [String] {
        var problems: [String] = []
        for job in jobs {
            do {
                if try await job.task.value > 0 { problems.append("\(job.name) (has silent gaps)") }
            } catch {
                problems.append("\(job.name): \(error)")
            }
        }
        jobs = []
        return problems
    }
}

extension DeviceModel {
    /// Copies tracks (zero-based) off the disc into `folder` as exact ATRAC files, plus a playable
    /// .m4a of each in `folder/Playable`. Returns the files saved for each track (by index) and any
    /// trouble with the playable copies. Shows progress; stops early if the task is cancelled.
    func copyTracks(_ indexes: [Int], titles: [String?], to folder: URL,
                    using service: any DeviceService) async throws -> (files: [Int: [String]], problems: [String]) {
        let count = indexes.count
        let playable = PlayableCopies()
        let playableFolder = folder.appendingPathComponent("Playable", isDirectory: true)
        let saved = SavedFiles()
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
                isCancelled: { Task.isCancelled },
                save: { i, track in
                    let name = backupFileName(trackNumber: indexes[i] + 1, title: titles[i], fileExtension: track.fileExtension)
                    let raw = uniqueURL(in: folder, name: name)
                    try Data(track.data).write(to: raw, options: .atomic)
                    // Make the playable copy in the background while the player reads the next track.
                    try FileManager.default.createDirectory(at: playableFolder, withIntermediateDirectories: true)
                    let m4a = uniqueURL(in: playableFolder, name: backupFileName(trackNumber: indexes[i] + 1, title: titles[i], fileExtension: "m4a"))
                    let job = Task.detached(priority: .utility) {
                        try makePlayableCopy(of: track.data, fileExtension: track.fileExtension, to: m4a)
                    }
                    await playable.add(m4a.lastPathComponent, job)
                    await saved.add(indexes[i], [raw.lastPathComponent, "Playable/" + m4a.lastPathComponent])
                }
            )
        } catch {
            _ = await playable.finish()
            throw error
        }
        setActivity("Making playable copies…", progress: 1)
        let problems = await playable.finish()
        return (await saved.files, problems)
    }

    /// Copies tracks into a folder the user chose.
    func backUp(_ indexes: [Int], to folder: URL) {
        guard let service = currentService, !isBusy, !indexes.isEmpty, let disc else { return }
        let titles = indexes.map { i in disc.tracks.first { $0.index == i }?.title }
        isBackingUp = true
        lastBackupFolder = nil
        errorMessage = nil
        setActivity("Starting backup…", progress: 0)

        uploadTask = Task {
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await copyTracks(indexes, titles: titles, to: folder, using: service)
                if !result.problems.isEmpty {
                    errorMessage = "The backup worked, but some playable copies had trouble: \(result.problems.joined(separator: "; "))"
                }
                if !Task.isCancelled { lastBackupFolder = folder }
            } catch ExploitError.untestedFirmware(let version) {
                needsFirmwareOK(version) { [weak self] in self?.backUp(indexes, to: folder) }
            } catch {
                errorMessage = "Backup failed: \(error)"
            }
            finishUpload()
            await refresh()
        }
    }

    func cancelBackup() {
        uploadTask?.cancel()
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
