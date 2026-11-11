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

    /// Starts on the inserted disc if erase mode is on and this disc hasn't been handled yet.
    func eraseIfNew() {
        guard eraseMode, !isBusy else { return }
        guard let disc, let key = discKey else {
            lastHandledDiscKey = nil
            return
        }
        guard key != lastHandledDiscKey else { return }
        lastHandledDiscKey = key
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
        let name = disc.title.isEmpty ? "this disc" : "“\(disc.title)”"
        let capitalName = name.prefix(1).uppercased() + name.dropFirst()
        errorMessage = nil
        eraseStatus = "Checking \(name) against your archive…"
        setActivity("Checking \(name) against your archive…", progress: nil)

        uploadTask = Task {
            do {
                let info = try await service.archiveInfo()
                guard let fingerprint = discFingerprint(info.toc),
                      let entry = ArchiveIndex.load(from: root).entry(for: fingerprint) else {
                    eraseStatus = "\(capitalName) isn't in your archive, so it was left alone. Insert the next disc."
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
