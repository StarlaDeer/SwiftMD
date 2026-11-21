import AppKit
import Foundation
import NetMDKit

extension DeviceModel {
    /// Tells inserted discs apart cheaply (before reading the TOC), so archive mode starts once per disc.
    var discKey: String? {
        guard let disc else { return nil }
        return "\(disc.title)|\(disc.trackCount)|" + disc.tracks.map { "\($0.duration)" }.joined(separator: ",")
    }

    /// Turning archive mode on doesn't start on the disc already in the player, so the settings
    /// can be chosen first; "Archive This Disc" starts it. Discs inserted after that start by themselves.
    func setArchiveMode(_ on: Bool) {
        if on && eraseMode { setEraseMode(false) }
        archiveMode = on
        lastHandledDiscKey = on ? discKey : nil
        archiveStatus = !on ? nil
            : disc?.tracks.isEmpty == false ? "Archive mode is on. Choose your settings, then click Archive This Disc."
            : "Archive mode is on. Insert a disc to archive it."
    }

    /// The inserted disc can be archived with the button (it's in the player but wasn't started).
    var canArchiveInsertedDisc: Bool {
        archiveMode && !isBusy && disc?.tracks.isEmpty == false
    }

    func archiveInsertedDisc() {
        lastHandledDiscKey = nil
        archiveIfNew()
    }

    /// Starts archiving the inserted disc if archive mode is on and this disc hasn't been started yet.
    func archiveIfNew() {
        guard archiveMode, archiveFolder != nil, !isBusy else { return }
        guard let disc, let key = discKey else {
            // Keep "Archived … Insert the next disc." showing after the disc comes out.
            if archiveStatus == nil { archiveStatus = "Archive mode is on. Insert a disc to archive it." }
            lastHandledDiscKey = nil
            return
        }
        guard key != lastHandledDiscKey else { return }
        lastHandledDiscKey = key
        guard !disc.tracks.isEmpty else {
            // Right after erasing, keep saying what was archived.
            if !(archiveStatus?.hasPrefix("Archived") ?? false) { archiveStatus = "This disc is blank. Insert the next one." }
            return
        }
        archive(disc)
    }

    private func archive(_ disc: Disc) {
        guard let service = currentService, let root = archiveFolder else { return }
        guard Self.folderIsAvailable(root) else {
            archiveStatus = Self.folderMissingMessage(root)
            lastHandledDiscKey = nil
            return
        }
        let name = disc.title.isEmpty ? "this disc" : "“\(disc.title)”"
        isBackingUp = true
        stopRequest.reset()
        errorMessage = nil
        archiveStatus = "Archiving \(name)…"
        setActivity("Reading the disc's table of contents…", progress: 0)

        uploadTask = Task {
            do {
                let info = try await service.archiveInfo()
                guard AtracDownloader.testedFirmware.contains(info.firmware) || allowedFirmware.contains(info.firmware) else {
                    archiveStatus = "Waiting for your OK to try this player's firmware."
                    lastHandledDiscKey = nil
                    needsFirmwareOK(info.firmware) { [weak self] in self?.archiveInsertedDisc() }
                    finishUpload()
                    await refresh()
                    return
                }
                guard let fingerprint = discFingerprint(info.toc) else {
                    archiveStatus = "\(name.prefix(1).uppercased() + name.dropFirst()) has no track table SwiftMD can read (pre-recorded discs aren't supported yet). Insert the next disc."
                    finishUpload()
                    return
                }
                guard info.toc.trackCount == disc.trackCount else {
                    archiveStatus = "The disc changed while SwiftMD was reading it. Click Archive This Disc to try again."
                    finishUpload()
                    await refresh()
                    return
                }
                var index = try ArchiveIndex.load(from: root)
                var sameLayoutNote = ""
                let candidates = index.entries(for: fingerprint)
                if !candidates.isEmpty {
                    // The fingerprint only covers the track list, so compare some of the audio too.
                    setActivity("Comparing the disc's audio with your archive…", progress: nil)
                    let existing: ArchiveIndex.Entry?
                    do {
                        existing = try await archivedCopy(among: candidates, root: root, using: service)
                    } catch {
                        archiveStatus = "\(name.prefix(1).uppercased() + name.dropFirst()) looks archived already, in “\(candidates[0].folder)”, but SwiftMD couldn't compare its audio\(eraseAfterArchiving ? ", so it wasn't erased" : ""). Insert the next disc."
                        errorMessage = "Comparing the audio failed: \(error)"
                        finishUpload()
                        await refresh()
                        return
                    }
                    if existing == nil {
                        sameLayoutNote = " (Your archive has a different disc with the same track layout, in “\(candidates[0].folder)”.)"
                    }
                    if let existing {
                        archiveStatus = "\(name.prefix(1).uppercased() + name.dropFirst()) is already archived, in “\(existing.folder)”. Insert the next disc."
                        if eraseAfterArchiving {
                            setActivity("Checking the archive before erasing…", progress: 1)
                            if let erased = await eraseIfSafe(disc, fingerprint: fingerprint, folder: root.appendingPathComponent(existing.folder), using: service) {
                                archiveStatus = "\(name.prefix(1).uppercased() + name.dropFirst()) was already archived, in “\(existing.folder)”. \(erased)\(self.isPortable ? "" : " Insert the next disc.")"
                            }
                        }
                        finishUpload()
                        if ejectAfterArchiving && !isPortable { try? await service.ejectDisc() }
                        await refresh()
                        return
                    }
                }

                // An unfinished archive of this disc carries on where it stopped, once a track it
                // already saved shows it's the same disc.
                var resumed: (folder: URL, record: DiscRecord)?
                if let partial = index.discs.last(where: { $0.fingerprint == fingerprint && !$0.complete }) {
                    let partialFolder = root.appendingPathComponent(partial.folder)
                    if var old = DiscRecord.load(from: partialFolder), old.fingerprint == fingerprint, old.tracks.count == disc.trackCount {
                        archiveStatus = "Checking the unfinished archive “\(partial.folder)”…"
                        setActivity("Checking the tracks already archived…", progress: nil)
                        old = await keepingOnlyGoodTracks(old, in: partialFolder)
                        var sameDisc = true
                        if old.tracks.contains(where: { !$0.files.isEmpty }) {
                            setActivity("Comparing the disc's audio with the unfinished archive…", progress: nil)
                            do {
                                sameDisc = try await audioMatches(old, folder: partialFolder, using: service)
                            } catch {
                                archiveStatus = "SwiftMD couldn't compare \(name) with its unfinished archive, “\(partial.folder)”. Insert it again to try again."
                                errorMessage = "Comparing the audio failed: \(error)"
                                finishUpload()
                                await refresh()
                                return
                            }
                        }
                        if sameDisc { resumed = (partialFolder, old) }
                    }
                }

                let folder: URL
                var record: DiscRecord
                if let resumed {
                    folder = resumed.folder
                    record = resumed.record
                    // Anything not counted as done (copies that stopped early, or failed to decode)
                    // goes to the Trash, so each track ends up with one clean set of files.
                    moveUnlistedTrackFilesToTrash(in: folder, keeping: Set(record.tracks.flatMap(\.files)))
                } else {
                    folder = uniqueFolderURL(in: root, name: archiveFolderName(title: disc.title))
                    try FileManager.default.createDirectory(at: folder.appendingPathComponent("TOC"), withIntermediateDirectories: true)
                    record = DiscRecord(fingerprint: fingerprint, disc: disc, toc: info.toc, player: deviceName ?? "", firmware: info.firmware)
                    for (i, sector) in info.toc.sectors(updateSignature: false).enumerated() {
                        if let sector { try Data(sector).write(to: folder.appendingPathComponent("TOC/utoc-sector-\(i).bin")) }
                    }
                }
                record.complete = false
                try record.write(to: folder)
                let archivedAt = record.archivedAt
                let entry = { (complete: Bool) in
                    ArchiveIndex.Entry(fingerprint: fingerprint, folder: folder.lastPathComponent, title: disc.title,
                                       archivedAt: archivedAt, complete: complete)
                }
                index.record(entry(false))
                try index.save(to: root)

                // Only the tracks that aren't done yet.
                let todo = disc.tracks.filter { track in
                    record.tracks.first { $0.number == track.index + 1 }?.files.isEmpty ?? true
                }
                let indexes = todo.map(\.index)
                if resumed != nil {
                    archiveStatus = "Carrying on with “\(folder.lastPathComponent)”: \(indexes.count) of \(disc.trackCount) tracks to go…"
                }
                let result = indexes.isEmpty ? CopyResult() : await copyTracks(indexes, titles: todo.map(\.title), to: folder, using: service)
                let failure = result.failure
                let cancelled = stopRequest.isSet
                // Make sure the disc wasn't swapped while it was being copied (not when SwiftMD's
                // code may still be on the player: then it waits for an unplug).
                var sameDisc = false
                if !Self.needsUnplug(failure) {
                    setActivity("Checking it's still the same disc…", progress: 1)
                    let after = try? await service.archiveInfo()
                    sameDisc = after.map { discFingerprint($0.toc) == fingerprint } ?? false
                }
                // Tracks done this time count only if it's certainly the same disc.
                if sameDisc {
                    for i in record.tracks.indices {
                        if let files = result.files[record.tracks[i].number - 1] { record.tracks[i].files = files }
                    }
                }
                let missing = record.tracks.filter { $0.files.isEmpty }.map(\.number)
                record.complete = failure == nil && !cancelled && sameDisc && missing.isEmpty
                try record.write(to: folder)
                index = try ArchiveIndex.load(from: root)
                index.record(entry(record.complete))
                try index.save(to: root)

                let again = "Insert the disc again (another player may read it better) and SwiftMD will copy only what's missing."
                if let failure, Self.needsUnplug(failure) {
                    archiveStatus = "Archiving “\(folder.lastPathComponent)” stopped. Unplug the player for a few seconds, plug it back in, then insert the disc again to carry on."
                    errorMessage = "Archiving failed: \(failure)"
                } else if !sameDisc && !indexes.isEmpty {
                    archiveStatus = "The disc changed (or couldn't be read again) while it was being archived, so the tracks copied this time weren't kept and nothing was erased. Insert the disc again to carry on."
                    if let failure { errorMessage = "Archiving failed: \(failure)" }
                } else if cancelled {
                    archiveStatus = "Stopped. “\(folder.lastPathComponent)” has \(record.tracks.count - missing.count) of \(record.tracks.count) tracks; insert the disc again to carry on where it stopped."
                } else if let failure = failure as? BackupError {
                    archiveStatus = "“\(folder.lastPathComponent)” has \(record.tracks.count - missing.count) of \(record.tracks.count) tracks. \(again)"
                    errorMessage = "\(failure)"
                    NSSound(named: "Funk")?.play()
                } else if let failure {
                    archiveStatus = "Archiving “\(folder.lastPathComponent)” stopped partway (\(record.tracks.count - missing.count) of \(record.tracks.count) tracks). \(again)"
                    errorMessage = "Archiving failed: \(failure)"
                } else if !missing.isEmpty {
                    archiveStatus = "“\(folder.lastPathComponent)” has \(record.tracks.count - missing.count) of \(record.tracks.count) tracks: some playable copies had trouble, so it wasn't erased. \(again)"
                    errorMessage = "Some playable copies had trouble: \(result.problems.joined(separator: "; "))"
                } else if !record.complete {
                    archiveStatus = "SwiftMD couldn't read the disc again to make sure it's the one archived in “\(folder.lastPathComponent)”, so it isn't marked complete. Insert it again to finish."
                } else {
                    archiveStatus = "Archived “\(folder.lastPathComponent)” (\(disc.trackCount) tracks).\(sameLayoutNote) Insert the next disc."
                    lastBackupFolder = nil
                    if eraseAfterArchiving {
                        setActivity("Checking the archive before erasing…", progress: 1)
                        if let erased = await eraseIfSafe(disc, fingerprint: fingerprint, folder: folder, using: service) {
                            archiveStatus = "Archived “\(folder.lastPathComponent)” (\(disc.trackCount) tracks). \(erased)\(self.isPortable ? "" : " Insert the next disc.")"
                        }
                    }
                    NSSound(named: "Glass")?.play()
                    NSApp.requestUserAttention(.informationalRequest)
                    finishUpload()
                    if ejectAfterArchiving && !isPortable { try? await service.ejectDisc() }
                    await refresh()
                    return
                }
            } catch {
                archiveStatus = "Archiving stopped."
                errorMessage = "Archiving failed: \(error)"
            }
            finishUpload()
            await refresh()
        }
    }

    /// Of `candidates` (archives whose fingerprint matches the inserted disc), the one whose audio
    /// matches the disc (audioMatches). Nil if none does: a different disc with the same track layout.
    func archivedCopy(among candidates: [ArchiveIndex.Entry], root: URL, using service: any DeviceService) async throws -> ArchiveIndex.Entry? {
        for candidate in candidates {
            let folder = root.appendingPathComponent(candidate.folder)
            // Only an archive that's really all there counts (its folder may have been moved or
            // deleted, or an older index restored).
            guard let record = DiscRecord.load(from: folder), record.complete, record.fingerprint == candidate.fingerprint,
                  record.missingFiles(in: folder).isEmpty else { continue }
            if try await audioMatches(record, folder: folder, using: service) { return candidate }
        }
        return nil
    }

    /// Reads the start of the first and last archived tracks off the disc and compares it byte for
    /// byte with the archived copies. False if nothing is archived to compare with.
    func audioMatches(_ record: DiscRecord, folder: URL, using service: any DeviceService) async throws -> Bool {
        let saved = record.tracks.compactMap { track in
            archivedAudioFile(track).map { (track: track.number - 1, url: folder.appendingPathComponent($0)) }
        }
        guard let first = saved.first, let last = saved.last else { return false }
        let files = first.track == last.track ? [first] : [first, last]
        let samples = try await service.sampleTracks(files.map(\.track), sectors: 32, alsoAllowedFirmware: allowedFirmware)
        return files.allSatisfy { file in
            guard let sample = samples[file.track], let handle = try? FileHandle(forReadingFrom: file.url) else { return false }
            defer { try? handle.close() }
            let start = (try? handle.read(upToCount: sample.data.count)) ?? nil
            return start.map { sampleMatchesArchivedFile(sample: sample.data, file: $0) } ?? false
        }
    }

    /// For carrying on with an unfinished archive: a track only stays done if all its files are
    /// there and not empty and its exact copy still decodes without a single error (archives made
    /// before SwiftMD 0.9.1 also listed tracks whose playable copies had trouble).
    func keepingOnlyGoodTracks(_ record: DiscRecord, in folder: URL) async -> DiscRecord {
        var record = record
        for i in record.tracks.indices where !record.tracks[i].files.isEmpty {
            let track = record.tracks[i]
            let present = track.files.allSatisfy { file in
                ((try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file).path)[.size] as? Int) ?? 0) > 0
            }
            var decodes = false
            if present, let raw = archivedAudioFile(track) {
                let url = folder.appendingPathComponent(raw)
                decodes = await Task.detached(priority: .utility) {
                    guard let data = try? Data(contentsOf: url),
                          let decoded = try? decodeBackup(Array(data), fileExtension: url.pathExtension) else { return false }
                    return decoded.badFrames == 0
                }.value
            }
            if !decodes { record.tracks[i].files = [] }
        }
        return record
    }

    /// Moves track files (exact and playable copies) that the archive doesn't list to the Trash.
    func moveUnlistedTrackFilesToTrash(in folder: URL, keeping: Set<String>) {
        let fm = FileManager.default
        var paths = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        paths += ((try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("Playable").path)) ?? []).map { "Playable/" + $0 }
        for path in unlistedTrackFiles(paths, keeping: keeping) {
            try? fm.trashItem(at: folder.appendingPathComponent(path), resultingItemURL: nil)
        }
    }

    /// The archive folder is there (not on a drive that's unplugged, for example).
    static func folderIsAvailable(_ root: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    static func folderMissingMessage(_ root: URL) -> String {
        "Your archive folder, “\(root.lastPathComponent)”, can't be found\(root.path.hasPrefix("/Volumes/") ? " (is its drive plugged in?)" : ""). Nothing was done. Connect it, or choose another folder, then click the button again."
    }

    static func needsUnplug(_ error: Error?) -> Bool {
        guard let error = error as? ExploitError else { return false }
        if case .needsUnplug = error { return true }
        if case .bulkTransferFailed = error { return true }
        return false
    }

    /// Erases the disc, but only if everything checks out: the archive in `folder` says it's complete,
    /// every file it lists is there and not empty, and the disc in the player is still the one that
    /// was archived (its table of contents is read again and compared). Returns what happened, or nil
    /// if it erased nothing (the reason goes in errorMessage).
    func eraseIfSafe(_ disc: Disc, fingerprint: String, folder: URL, using service: any DeviceService) async -> String? {
        func refuse(_ why: String) -> String? {
            errorMessage = "The disc was archived but not erased: \(why)"
            return nil
        }
        if disc.writeProtected { return refuse("it's write-protected.") }
        guard let record = DiscRecord.load(from: folder) else {
            return refuse("its disc.json couldn't be read.")
        }
        guard record.complete, record.fingerprint == fingerprint else {
            return refuse("the archive isn't complete.")
        }
        if let missing = record.missingFiles(in: folder).first {
            return refuse("\(missing) is missing or empty.")
        }
        do {
            let now = try await service.archiveInfo()
            guard discFingerprint(now.toc) == fingerprint else { return refuse("the disc in the player isn't the one that was archived.") }
            guard record.tracks.count == now.toc.trackCount else { return refuse("the archive doesn't have every track.") }
            // Read fresh, not the listing from when the disc went in.
            if try await service.listContent().writeProtected { return refuse("it's write-protected.") }
            setActivity("Erasing the disc…", progress: 1)
            try await service.wipeDisc()
        } catch {
            return refuse("\(error)")
        }
        if isPortable {
            return "Now unplug the USB cable, keeping the player on power, so it writes the erase to the disc. When “TOC Edit” is done, swap discs and plug it back in."
        }
        if !ejectAfterArchiving { hasUnwrittenChanges = true }
        return "The disc is now blank."
    }

    /// Asks where the archive lives. Returns nil if the user cancels.
    func chooseArchiveFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Archive Folder"
        panel.message = "Choose a folder for your MiniDisc archive. Each disc gets its own folder inside it."
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
