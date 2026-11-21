import AppKit
import Foundation
import NetMDKit

/// Erase mode: for blanking a stack of discs that are already archived. Each disc inserted is
/// looked up in the archive by its fingerprint and erased only if eraseIfSafe's checks all pass
/// (complete archive, every file there, same disc). Anything not archived is left alone.
extension DeviceModel {
    func setEraseMode(_ on: Bool) {
        if on && archiveMode { setArchiveMode(false) }
        eraseMode = on
        unarchivedDisc = nil
        lastHandledDiscKey = on ? discKey : nil
        eraseStatus = !on ? nil
            : disc?.tracks.isEmpty == false ? "Erase mode is on. Click Erase This Disc to check it against your archive and erase it."
            : "Erase mode is on. Insert a disc you've archived."
    }

    var canEraseInsertedDisc: Bool {
        eraseMode && !isBusy && disc?.tracks.isEmpty == false
    }

    func eraseInsertedDisc() {
        lastHandledDiscKey = nil
        eraseIfNew()
    }

    /// Erase Anyway is only offered for the disc that was just found not to be archived.
    var canEraseUnarchivedDisc: Bool {
        guard eraseMode, !isBusy, let unarchivedDisc, let discKey else { return false }
        return unarchivedDisc.key == discKey && disc?.tracks.isEmpty == false
    }

    /// Erases the inserted disc although it isn't in the archive, after the user confirmed it.
    /// Still refuses write-protected discs, and re-reads the table of contents first so it only
    /// erases the disc that was checked.
    func eraseUnarchivedDisc() {
        guard canEraseUnarchivedDisc, let service = currentService, let disc, let checked = unarchivedDisc else { return }
        unarchivedDisc = nil
        let name = disc.title.isEmpty ? "this disc" : "“\(disc.title)”"
        errorMessage = nil
        if disc.writeProtected {
            eraseStatus = "\(name.prefix(1).uppercased() + name.dropFirst()) is write-protected, so it wasn't erased. Insert the next disc."
            return
        }
        setActivity("Erasing the disc…", progress: nil)
        uploadTask = Task {
            do {
                let now = try await service.archiveInfo()
                guard discFingerprint(now.toc) == checked.fingerprint else {
                    eraseStatus = "The disc in the player changed, so nothing was erased. Insert the next disc."
                    finishUpload()
                    await refresh()
                    return
                }
                if try await service.listContent().writeProtected {
                    eraseStatus = "\(name.prefix(1).uppercased() + name.dropFirst()) is write-protected, so it wasn't erased. Insert the next disc."
                    finishUpload()
                    await refresh()
                    return
                }
                try await service.wipeDisc()
                eraseStatus = "Erased \(name) (it wasn't archived). " + (isPortable
                    ? "Now unplug the USB cable, keeping the player on power, so it writes the erase to the disc. When “TOC Edit” is done, swap discs and plug it back in."
                    : "The disc is now blank. Insert the next disc.")
                NSSound(named: "Glass")?.play()
                if !isPortable { try? await service.ejectDisc() }
            } catch {
                eraseStatus = "Couldn't erase \(name)."
                errorMessage = "Erase mode: \(error)"
            }
            finishUpload()
            await refresh()
        }
    }

    /// Starts on the inserted disc if erase mode is on and this disc hasn't been handled yet.
    func eraseIfNew() {
        guard eraseMode, !isBusy else { return }
        guard let disc, let key = discKey else {
            lastHandledDiscKey = nil
            return
        }
        guard key != lastHandledDiscKey else { return }
        lastHandledDiscKey = key
        unarchivedDisc = nil
        guard !disc.tracks.isEmpty else {
            if !(eraseStatus?.hasPrefix("Erased") ?? false) { eraseStatus = "This disc is blank. Insert the next one." }
            return
        }
        guard let root = archiveFolder else {
            eraseStatus = "Choose your archive folder first (Erase menu)."
            return
        }
        erase(disc, archive: root)
    }

    private func erase(_ disc: Disc, archive root: URL) {
        guard let service = currentService else { return }
        guard Self.folderIsAvailable(root) else {
            eraseStatus = Self.folderMissingMessage(root)
            lastHandledDiscKey = nil
            return
        }
        let name = disc.title.isEmpty ? "this disc" : "“\(disc.title)”"
        let capitalName = name.prefix(1).uppercased() + name.dropFirst()
        errorMessage = nil
        eraseStatus = "Checking \(name) against your archive…"
        setActivity("Checking \(name) against your archive…", progress: nil)

        uploadTask = Task {
            do {
                let info = try await service.archiveInfo()
                let fingerprint = discFingerprint(info.toc)
                let candidates = try fingerprint.map { try ArchiveIndex.load(from: root).entries(for: $0) } ?? []
                var entry: ArchiveIndex.Entry?
                if !candidates.isEmpty {
                    // The fingerprint only covers the track list, so compare some of the audio too.
                    eraseStatus = "Comparing \(name)'s audio with your archive…"
                    setActivity("Comparing \(name)'s audio with your archive…", progress: nil)
                    entry = try await archivedCopy(among: candidates, root: root, using: service)
                }
                guard let fingerprint, let entry else {
                    if let fingerprint, let key = discKey {
                        unarchivedDisc = (key, fingerprint)
                    }
                    eraseStatus = candidates.isEmpty
                        ? "\(capitalName) isn't in your archive, so it was left alone. Insert the next disc, or choose Erase Anyway if you've copied it some other way."
                        : "\(capitalName) matches “\(candidates[0].folder)” in your archive by its track list, but that archive is missing files or its audio is different, so it was left alone. Insert the next disc, or choose Erase Anyway if you've copied it some other way."
                    NSSound(named: "Funk")?.play()
                    finishUpload()
                    await refresh()
                    return
                }
                if let erased = await eraseIfSafe(disc, fingerprint: fingerprint, folder: root.appendingPathComponent(entry.folder), using: service) {
                    eraseStatus = "Erased \(name) (archived in “\(entry.folder)”). " + erased
                    NSSound(named: "Glass")?.play()
                    NSApp.requestUserAttention(.informationalRequest)
                    if !isPortable { try? await service.ejectDisc() }
                } else {
                    eraseStatus = "\(capitalName) wasn't erased (the reason is shown above). Insert the next disc."
                }
            } catch {
                eraseStatus = "Couldn't check \(name)."
                errorMessage = "Erase mode: \(error)"
            }
            finishUpload()
            await refresh()
        }
    }
}
