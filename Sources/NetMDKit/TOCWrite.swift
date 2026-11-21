// Saving an edited TOC to the disc. Port of netmd-exploits' ForceTOCEdit and Web MiniDisc Pro's
// writeModifiedTOC. Unlike everything else in homebrew mode, this changes the disc.

import Foundation

extension ExploitSession {
    /// Writes all four UTOC sectors to the recorder's memory, then has the firmware save them to
    /// the disc. The TOC keeps its device signature, as in Web MiniDisc Pro.
    func writeTOC(_ toc: TableOfContents) async throws {
        let sectors = toc.sectors(updateSignature: false)
        guard sectors.count == 4, sectors.allSatisfy({ $0 != nil }) else {
            throw FactoryError.invalidArgument("Writing a TOC needs all four sectors.")
        }
        for (i, sector) in sectors.enumerated() {
            try await factory.writeUTOCSector(i, data: sector!)
        }
        try await forceTOCEdit()
    }

    /// Port of ForceTOCEdit.forceTOCEdit: lowers the head, runs the firmware's own TOC write (which
    /// writes the recorder's in-memory TOC to the disc), waits 50 seconds, raises the head.
    func forceTOCEdit() async throws {
        guard let payload = ExploitPayloads.forceTOCEdit[version] else { throw ExploitError.unsupportedFirmware(version) }
        if !isTypeR { try await factory.display("TOCWRT", blink: true) }
        // envelop(USBCodeExecution): loaded just for this unless something else already uses it.
        let wasLoaded = usbExecution != nil
        let exec = try await codeExecution()
        // SwiftMD addition: if the head can't be raised again, only an unplug is safe.
        func raiseHead() async throws {
            do {
                _ = try await exec.execute(payload.raiseHead)
            } catch {
                needsReset = true
                throw ExploitError.needsUnplug("raising the head failed: \(error)")
            }
        }
        do {
            _ = try await exec.execute(payload.lowerHead)
        } catch {
            needsReset = true
            throw ExploitError.needsUnplug("lowering the head failed: \(error)")
        }
        do {
            try await sleep(1000)
            _ = try await exec.execute(payload.trigger)
            try await sleep(50000)
        } catch {
            // SwiftMD addition: don't leave the head down if something fails in between.
            try await raiseHead()
            throw error
        }
        try await raiseHead()
        if !wasLoaded {
            try await exec.unload()
            usbExecution = nil
        }
        if !isTypeR { try await factory.setDisplayMode(.default) }
    }
}

extension NetMDInterface {
    /// Whether this firmware has netmd-exploits' TOC write.
    public static func canWritePendingChanges(firmware: String) -> Bool { ExploitPayloads.forceTOCEdit[firmware] != nil }

    /// Has a portable write its edited TOC (after renaming, deleting or erasing) to the disc now,
    /// instead of when the USB cable is unplugged: the firmware's own TOC write, triggered through
    /// netmd-exploits' ForceTOCEdit. Takes about 52 seconds. Sony NetMD recorders only.
    public func writePendingChangesToDisc(log: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try checkBackupSupported()
        let factory = try await factory()
        guard factory.kind == .netmd else { throw ExploitError.unsupportedDevice(deviceName) }
        let session = try await ExploitSession.create(device: self, factory: factory, log: log)
        do {
            try await session.forceTOCEdit()
            try await session.close()
        } catch {
            if case ExploitError.needsUnplug = error { throw error }
            do {
                try await session.close()
            } catch {
                throw ExploitError.needsUnplug(String(describing: error))
            }
            throw error
        }
    }
}
