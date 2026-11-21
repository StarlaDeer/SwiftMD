// SwiftMD's command-line tool for developers, handy for checking a real device without the app.
//
// Read-only:
//   netmdcli                              the disc and its tracks (like netmd-js's `netmdcli ls`)
//   netmdcli --identify                   the firmware version, through the factory command set
//   netmdcli --patches                    the firmware patch slots
//   netmdcli --toc                        the disc's table of contents and archive fingerprint
//   netmdcli --decode <in> <out.wav|.m4a> decodes a backup (no player needed)
// Loads code into the player's RAM (undone afterwards, or by unplugging), like the app's backups:
//   netmdcli --download-track <n> [dir]   backs up one track (tested firmware only)
// For developers only, with SWIFTMD_DEV=1 (they change the player's RAM in ways the app never does):
//   --download-track ... --standard|--bulk   forces a transfer method; also allows untested firmware
//   --read-cache <n> <count> <dir>           saves raw sectors from the player's buffer
//   --dump-firmware <dir>                    saves the player's RAM and ROM (Sony's copyright: keep private)
//   --erase-and-write <archive folder>       erases the disc if it's completely archived there, then has
//                                            the player write the change without unplugging (a test)

import Foundation
import NetMDKit

if let flag = CommandLine.arguments.firstIndex(of: "--decode"), flag + 2 < CommandLine.arguments.count {
    // Decodes a backup (.aea or ATRAC3 .wav) to a 16-bit PCM .wav, or to AAC if the output ends in .m4a.
    let args = CommandLine.arguments
    do {
        let input = URL(fileURLWithPath: args[flag + 1])
        let output = URL(fileURLWithPath: args[flag + 2])
        let (audio, bad) = try decodeBackup(Array(try Data(contentsOf: input)), fileExtension: input.pathExtension)
        if output.pathExtension.lowercased() == "m4a" {
            try writeM4A(audio, to: output)
            print("Decoded \(String(format: "%.1f", audio.duration)) s, \(bad) bad frames")
            exit(0)
        }
        var pcm = Data()
        for s in audio.samples {
            let v = Int16(max(-32768, min(32767, (s * 32768).rounded())))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        var wav = Data("RIFF".utf8) + Data(le(36 + pcm.count, 4)) + Data("WAVEfmt ".utf8)
        wav += Data(le(16, 4) + le(1, 2) + le(2, 2) + le(44100, 4) + le(44100 * 4, 4) + le(4, 2) + le(16, 2))
        wav += Data("data".utf8) + Data(le(pcm.count, 4)) + pcm
        try wav.write(to: output)
        print("Decoded \(String(format: "%.1f", audio.duration)) s, \(bad) bad frames")
        exit(0)
    } catch {
        print("Error: \(error)")
        exit(1)
    }
}

let devMode = ProcessInfo.processInfo.environment["SWIFTMD_DEV"] == "1"
if !devMode, let flag = ["--dump-firmware", "--read-cache", "--bulk", "--standard", "--erase-and-write"].first(where: CommandLine.arguments.contains) {
    print("\(flag) is for developers: it changes the player's memory in ways the app never does. Set SWIFTMD_DEV=1 to use it.")
    exit(2)
}

/// After a failure: takes SwiftMD's code back out of the player, or says to unplug it.
func tidyUp(_ downloader: AtracDownloader?, _ session: ExploitSession) async {
    do {
        try await downloader?.finish()
        try await session.close()
    } catch {
        print("Couldn't remove SwiftMD's code from the player (\(error)). Unplug it for a few seconds: that undoes everything.")
    }
}

let devices = IOUSBHostTransport.connectedDevices()
guard let info = devices.first else {
    print("No NetMD device found.")
    exit(1)
}
print(String(format: "Device: %@ (%04x:%04x)", info.name, info.vendorID, info.productID))

do {
    let transport = try IOUSBHostTransport(device: info)
    let iface = try await NetMDInterface.open(transport: transport, vendorID: info.vendorID, productID: info.productID)
    defer { Task { await iface.close() } }

    if CommandLine.arguments.contains("--identify") {
        // Authenticates to the factory command set and reads the firmware code. Writes nothing.
        let factory = try await iface.factory()
        let code = try await factory.getDeviceCode()
        print("Firmware: \(code.descriptive) (chip 0x\(String(code.chipType, radix: 16)), hwid \(code.hwid))")
        exit(0)
    }

    if let flag = CommandLine.arguments.firstIndex(of: "--read-cache") {
        // Diagnostics: saves the first <count> sectors of the player's buffer for a track (1-based).
        let args = CommandLine.arguments
        guard flag + 3 < args.count, let number = Int(args[flag + 1]), let count = Int(args[flag + 2]) else {
            print("Usage: netmdcli --read-cache <track number> <sector count> <dir>")
            exit(2)
        }
        let outDir = URL(fileURLWithPath: args[flag + 3])
        try await iface.stop()
        let factory = try await iface.factory()
        let session = try await ExploitSession.create(device: iface, factory: factory) { print($0) }
        let sectors: [[UInt8]]
        var downloader: AtracDownloader?
        do {
            let reader = try AtracDownloader(session: session, method: args.contains("--bulk") ? .bulk : nil)
            downloader = reader
            sectors = try await reader.readCachedSectors(track: number - 1, count: count)
            try await reader.finish()
            try await session.close()
        } catch {
            await tidyUp(downloader, session)
            throw error
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for (i, sector) in sectors.enumerated() {
            try Data(sector).write(to: outDir.appendingPathComponent(String(format: "cache-%03d.bin", i)))
            print(String(format: "%3d: header %@", i, sector.prefix(20).map { String(format: "%02x", $0) }.joined()))
        }
        exit(0)
    }

    if let flag = CommandLine.arguments.firstIndex(of: "--download-track") {
        // Disc backup of one track (1-based): netmd-exploits' ATRAC download. Reads the disc only;
        // the code-execution patch is removed afterwards, and everything clears on reset.
        let args = CommandLine.arguments
        guard flag + 1 < args.count, let number = Int(args[flag + 1]), number >= 1 else {
            print("Usage: netmdcli --download-track <track number> [output dir]")
            exit(2)
        }
        let outDir = URL(fileURLWithPath: flag + 2 < args.count ? args[flag + 2] : ".")
        guard try await iface.isDiscPresent() else {
            print("No disc in the player.")
            exit(1)
        }
        guard number <= (try await iface.getTrackCount()) else {
            print("The disc has no track \(number).")
            exit(1)
        }
        try await iface.stop()
        let factory = try await iface.factory()
        let version = try await factory.descriptiveDeviceCode()
        guard devMode || AtracDownloader.testedFirmware.contains(version) else {
            print("Backups haven't been tested on firmware \(version). Use the app (it asks first), or SWIFTMD_DEV=1.")
            exit(1)
        }
        let session = try await ExploitSession.create(device: iface, factory: factory) { print($0) }
        print("Firmware: \(session.version), free patch slots: \(session.freePatches.sorted())")
        let start = Date()
        let track: DownloadedTrack
        var activeDownloader: AtracDownloader?
        do {
            final class LastShown: @unchecked Sendable { var percent = -1 }
            let last = LastShown()
            let downloader = args.contains("--standard")
                ? try AtracDownloader(session: session, method: .controlTransfers)
                : args.contains("--bulk") ? try AtracDownloader(session: session, method: .bulk)
                : try await AtracDownloader.fastest(session: session)
            activeDownloader = downloader
            print("Method: \(downloader.method.rawValue)")
            track = try await downloader.downloadTrack(number - 1) { p in
                let percent = p.total == 0 ? 0 : p.read * 100 / p.total
                if p.action == .seek || percent / 5 != last.percent / 5 {
                    print("\(p.action.rawValue): \(p.read) of \(p.total) sectors (\(percent)%)")
                    last.percent = percent
                }
            }
            try await downloader.finish()
            try await session.close()
        } catch {
            if case ExploitError.bulkTransferFailed = error { throw error }
            await tidyUp(activeDownloader, session)
            throw error
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let safeTitle = (track.title ?? "").replacingOccurrences(of: "/", with: "-")
        let name = String(format: "%02d", number) + (safeTitle.isEmpty ? "" : " - \(safeTitle)") + ".\(track.fileExtension)"
        let url = outDir.appendingPathComponent(name)
        try Data(track.data).write(to: url)
        print("\(track.complete ? "Saved" : "Saved INCOMPLETE") \(track.format.rawValue) track to \(url.path) (\(track.data.count) bytes, \(Int(Date().timeIntervalSince(start))) s)")
        exit(track.complete ? 0 : 3)
    }

    if CommandLine.arguments.contains("--toc") {
        // Prints the disc's User TOC as the recorder holds it. Read-only.
        let factory = try await iface.factory()
        let toc = try await factory.readTOC()
        let signer = TableOfContents.signatures[toc.deviceSignature] ?? "unknown"
        print(String(format: "TOC signature 0x%04x (%@), %d tracks, disc title \"%@\"", toc.deviceSignature, signer, toc.trackCount, toc.title(track: 0)))
        print("Archive fingerprint: \(discFingerprint(toc) ?? "none (no track table)")")
        for track in 1...max(1, toc.trackCount) where toc.trackCount > 0 {
            let info = toc.trackInfo(track)
            let fragments = info.fragments.map { f in
                String(format: "%04x.%02x.%x-%04x.%02x.%x mode 0x%02x", f.start.cluster, f.start.sector, f.start.group,
                       f.end.cluster, f.end.sector, f.end.group, f.mode)
            }
            print(String(format: "%3d. %@", track, info.title ?? ""))
            if let t = info.timestamp, t.signature != 0 || t.year != 0 || t.month != 0 {
                let stamp = String(format: "20%02x-%02x-%02x %02x:%02x:%02x", t.year, t.month, t.day, t.hour, t.minute, t.second)
                print("     written \(stamp) by \(info.writtenBy ?? "unknown")")
            } else {
                print("     no recording date")
            }
            for f in fragments { print("     \(f)") }
        }
        exit(0)
    }

    if CommandLine.arguments.contains("--patches") {
        // Lists the firmware patch slots. Read-only.
        let factory = try await iface.factory()
        let version = try await factory.descriptiveDeviceCode()
        guard let total = SafetyPatches.maxPatches(for: version) else { throw ExploitError.unsupportedFirmware(version) }
        let base: PatchPeripheralBase = version.hasPrefix("H") ? .himd : .netmd
        print("Firmware: \(version), \(total) patch slots")
        for i in 0..<total {
            let control = try await factory.cleanRead(address: base.rawValue + i * 0x10, length: 4, type: .mapped)
            let patch = try await factory.readPatch(i, base: base)
            let enabled = control[0] & 1 == 1 ? "enabled " : "disabled"
            print(String(format: "  slot %d: %@ address 0x%08x data %@", i, enabled, patch.address,
                         patch.data.map { String(format: "%02x", $0) }.joined()))
        }
        exit(0)
    }

    if let flag = CommandLine.arguments.firstIndex(of: "--erase-and-write") {
        // Test of ForceTOCEdit. Only erases a disc that's completely archived in the given folder.
        let args = CommandLine.arguments
        guard flag + 1 < args.count else { print("Usage: netmdcli --erase-and-write <archive folder>"); exit(2) }
        let root = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        guard try await iface.isDiscPresent() else { print("No disc in the player."); exit(1) }
        let disc = try await iface.listContent()
        guard !disc.writeProtected else { print("The disc is write-protected."); exit(1) }
        guard disc.trackCount > 0 else { print("The disc is already blank."); exit(1) }
        let info = try await iface.archiveInfo()
        print("Firmware: \(info.firmware)")
        guard NetMDInterface.canWritePendingChanges(firmware: info.firmware) else { print("No TOC write for this firmware."); exit(1) }
        guard let fingerprint = discFingerprint(info.toc), let entry = try ArchiveIndex.load(from: root).entry(for: fingerprint) else {
            print("This disc isn't completely archived in \(root.path). Not erasing it.")
            exit(1)
        }
        print("Archived in “\(entry.folder)” (\(disc.trackCount) tracks). Erasing…")
        try await iface.wipeDisc()
        print("Erased in the player's memory. Writing it to the disc (about 52 s)…")
        let start = Date()
        try await iface.writePendingChangesToDisc { print($0) }
        print(String(format: "Done in %.0f s.", Date().timeIntervalSince(start)))
        let status = try await iface.getDeviceStatus()
        print("State: \(status.state.rawValue), disc present: \(status.discPresent), tracks now: \(try await iface.getTrackCount())")
        exit(0)
    }

    if let flag = CommandLine.arguments.firstIndex(of: "--dump-firmware") {
        // Port of the ElectronWMD firmware dump: load Sony's safety patch where the firmware has one
        // (a patch slot, cleared on reset), then read RAM and ROM. The dump itself writes 16 zero
        // bytes into RAM to lift the factory read limit. Nothing goes to the EEPROM or the disc.
        let args = CommandLine.arguments
        let outDir = URL(fileURLWithPath: flag + 1 < args.count ? args[flag + 1] : ".")
        let factory = try await iface.factory()
        let version = try await factory.descriptiveDeviceCode()
        print("Firmware: \(version)")
        let dumper = try FirmwareDumper(factory: factory, version: version)

        let inUse = try await ExploitSession.activePatchSlots(factory: factory, version: version)
        let report = try await SafetyPatches.load(on: factory, version: version, inUse: inUse) { print("[safety] \($0)") }
        if !report.hfecSupported { print("[safety] No safety patch is known for \(version).") }

        var lastShown = (FirmwareDumper.Region.ram, -1)
        let dump = try await dumper.dump { region, read, total in
            let percent = total == 0 ? 100 : read * 100 / total
            if region != lastShown.0 || percent / 5 != lastShown.1 / 5 {
                print("\(region.rawValue): \(percent)%  (\(read) of \(total) bytes)")
                lastShown = (region, percent)
            }
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let ramURL = outDir.appendingPathComponent("\(version)-ram.bin")
        let romURL = outDir.appendingPathComponent("\(version)-rom.bin")
        try Data(dump.ram).write(to: ramURL)
        try Data(dump.rom).write(to: romURL)
        print("Saved \(ramURL.path) and \(romURL.path)")
        print("The dump lifted the factory read limit in the player's RAM. Unplug the player for a few seconds to put it back.")
        exit(0)
    }

    let status = try await iface.getDeviceStatus()
    print("State: \(status.state.rawValue), disc present: \(status.discPresent)")
    guard status.discPresent else { exit(0) }

    let disc = try await iface.listContent()
    print("Disc: \"\(disc.title)\"" + (disc.fullWidthTitle.isEmpty ? "" : " / \"\(disc.fullWidthTitle)\""))
    print("Write-protected: \(disc.writeProtected)")
    print("Used \(formatTimeFromFrames(disc.used, frames: false)), left \(formatTimeFromFrames(disc.left, frames: false)), total \(formatTimeFromFrames(disc.total, frames: false))")
    print("Tracks: \(disc.trackCount)")
    for group in disc.groups {
        if let title = group.title { print("[\(title)]") }
        for track in group.tracks {
            let lock = track.isProtected ? " 🔒" : ""
            print(String(format: "  %2d. %@  %@  %@%@", track.index + 1, track.title ?? "", track.encodingName,
                         formatTimeFromFrames(track.duration, frames: false), lock))
        }
    }
} catch {
    print("Error: \(error)")
    exit(1)
}
