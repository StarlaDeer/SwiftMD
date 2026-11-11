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
        let name = disc.title.isEmpty ? "this disc" : "“\(disc.title)”"
        isBackingUp = true
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
                var index = ArchiveIndex.load(from: root)
                if let existing = index.entry(for: fingerprint) {
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

                let folder = uniqueFolderURL(in: root, name: archiveFolderName(title: disc.title))
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("TOC"), withIntermediateDirectories: true)
                var record = DiscRecord(fingerprint: fingerprint, disc: disc, toc: info.toc, player: deviceName ?? "", firmware: info.firmware)
                try record.write(to: folder)
                for (i, sector) in info.toc.sectors(updateSignature: false).enumerated() {
                    if let sector { try Data(sector).write(to: folder.appendingPathComponent("TOC/utoc-sector-\(i).bin")) }
                }
                let entry = { (complete: Bool) in
                    ArchiveIndex.Entry(fingerprint: fingerprint, folder: folder.lastPathComponent, title: disc.title,
                                       archivedAt: record.archivedAt, complete: complete)
                }
                index.record(entry(false))
                try index.save(to: root)

                let indexes = disc.tracks.map(\.index)
                let titles = disc.tracks.map(\.title)
                var result: (files: [Int: [String]], problems: [String]) = ([:], [])
                var failure: Error?
                do {
                    result = try await copyTracks(indexes, titles: titles, to: folder, using: service)
                } catch {
                    failure = error
                }
                let cancelled = Task.isCancelled
                for i in record.tracks.indices {
                    record.tracks[i].files = result.files[record.tracks[i].number - 1] ?? []
                }
                record.complete = failure == nil && !cancelled && result.files.count == indexes.count && result.problems.isEmpty
                try record.write(to: folder)
                index = ArchiveIndex.load(from: root)
                index.record(entry(record.complete))
                try index.save(to: root)

                if let failure {
                    archiveStatus = "Archiving “\(folder.lastPathComponent)” stopped partway; it will be archived again next time."
                    errorMessage = "Archiving failed: \(failure)"
                } else if cancelled {
                    archiveStatus = "Stopped. “\(folder.lastPathComponent)” is incomplete; it will be archived again next time."
                } else {
                    archiveStatus = "Archived “\(folder.lastPathComponent)” (\(indexes.count) tracks). Insert the next disc."
                    lastBackupFolder = nil
                    if eraseAfterArchiving {
                        if record.complete {
                            setActivity("Checking the archive before erasing…", progress: 1)
                            if let erased = await eraseIfSafe(disc, fingerprint: fingerprint, folder: folder, using: service) {
                                archiveStatus = "Archived “\(folder.lastPathComponent)” (\(indexes.count) tracks). \(erased)\(self.isPortable ? "" : " Insert the next disc.")"
                            }
                        } else {
                            archiveStatus = "Archived “\(folder.lastPathComponent)” (\(indexes.count) tracks), but not erased: some copies had trouble. Insert the next disc."
                        }
                    }
                    if !result.problems.isEmpty {
                        errorMessage = "The disc was archived, but some playable copies had trouble: \(result.problems.joined(separator: "; "))"
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("disc.json")),
              let record = try? decoder.decode(DiscRecord.self, from: data) else {
            return refuse("its disc.json couldn't be read.")
        }
        guard record.complete, record.fingerprint == fingerprint, record.tracks.count == disc.trackCount else {
            return refuse("the archive isn't complete.")
        }
        for track in record.tracks {
            guard !track.files.isEmpty else { return refuse("track \(track.number) has no files.") }
            for file in track.files {
                let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file).path)[.size] as? Int) ?? 0
                guard size > 0 else { return refuse("\(file) is missing or empty.") }
            }
        }
        do {
            let now = try await service.archiveInfo()
            guard discFingerprint(now.toc) == fingerprint else { return refuse("the disc in the player isn't the one that was archived.") }
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
