import Foundation
import NetMDKit
import Observation

@MainActor
@Observable
final class DeviceModel {
    enum Phase: Equatable {
        case disconnected
        case connecting
        case connected
        case loading
    }

    private(set) var phase: Phase = .disconnected
    private(set) var deviceName: String?
    private(set) var disc: Disc?
    private(set) var status: DeviceStatus?
    /// What the device is doing right now, e.g. "Renaming track 3…".
    private(set) var activity: String?
    /// Overall progress of an upload, 0...1, while one is running.
    private(set) var uploadProgress: Double?
    /// Portable recorders keep edits in memory ("TOC Edit") and write them to the disc when unplugged.
    var hasUnwrittenChanges = false
    var errorMessage: String?
    /// Tracks the user asked to back up, waiting for a destination folder.
    var backupRequest: [Int]?
    /// True while tracks are being copied off the disc (the progress bar is shared with uploads).
    var isBackingUp = false
    /// Where the last backup was saved, to offer showing it in Finder.
    var lastBackupFolder: URL?

    // Archive mode (ArchiveModel.swift): every inserted disc is backed up into its own folder.
    var archiveMode = false
    // Erase mode (EraseModel.swift): every inserted disc that's completely archived is erased.
    var eraseMode = false
    var eraseStatus: String?
    /// Portables (MZ-…, Sharp IM-…) keep edits in memory until the USB cable is unplugged, and
    /// their lid is opened by hand, so "eject" does nothing on them.
    var isPortable: Bool {
        guard let name = deviceName else { return true }
        return name.contains("MZ-") || name.contains("IM-") || name.contains("Walkman")
    }
    private var deviceWatch: Task<Void, Never>?
    var archiveStatus: String?
    /// The disc archive mode last started on, so the same inserted disc isn't started twice.
    var lastHandledDiscKey: String?
    var archiveFolder: URL? {
        get { UserDefaults.standard.string(forKey: "archiveFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "archiveFolder") }
    }
    /// Erase each disc once it's archived completely (off unless the user turns it on).
    var eraseAfterArchiving: Bool {
        get { UserDefaults.standard.bool(forKey: "eraseAfterArchiving") }
        set { UserDefaults.standard.set(newValue, forKey: "eraseAfterArchiving") }
    }
    /// Firmware versions backups haven't been tested on, that the user agreed to try anyway.
    var allowedFirmware: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "allowedUntestedFirmware") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "allowedUntestedFirmware") }
    }
    /// Set when a backup needs the user's OK for untested firmware (the version), with what to do after.
    var untestedFirmwarePrompt: String?
    var afterFirmwareOK: (() -> Void)?

    func needsFirmwareOK(_ version: String, then retry: @escaping () -> Void) {
        untestedFirmwarePrompt = version
        afterFirmwareOK = retry
    }

    func allowFirmware() {
        guard let version = untestedFirmwarePrompt else { return }
        allowedFirmware.insert(version)
        untestedFirmwarePrompt = nil
        let retry = afterFirmwareOK
        afterFirmwareOK = nil
        retry?()
    }

    var ejectAfterArchiving: Bool {
        get { UserDefaults.standard.object(forKey: "ejectAfterArchiving") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ejectAfterArchiving") }
    }

    private var service: (any DeviceService)?
    private var statusPolling: Task<Void, Never>?
    var uploadTask: Task<Void, Never>?

    var currentService: (any DeviceService)? { service }
    var isUploading: Bool { uploadProgress != nil }

    func setActivity(_ text: String, progress: Double?) {
        activity = text
        uploadProgress = progress
    }

    func finishUpload() {
        activity = nil
        uploadProgress = nil
        uploadTask = nil
        isBackingUp = false
    }

    var isConnected: Bool { phase == .connected || phase == .loading }
    var isBusy: Bool { phase == .loading || activity != nil }
    var canEdit: Bool { isConnected && !isBusy && disc != nil && disc?.writeProtected == false }

    func connect() async {
        phase = .connecting
        errorMessage = nil
        do {
            let service = try await NetMDInterface.openFirstDevice()
            self.service = service
            deviceName = service.deviceName
            phase = .connected
            await refresh()
            startStatusPolling()
        } catch {
            phase = .disconnected
            errorMessage = String(describing: error)
        }
    }

    func refresh() async {
        await refresh(reconnectIfLost: true)
    }

    private func refresh(reconnectIfLost: Bool) async {
        guard let service else { return }
        phase = .loading
        // Don't clear errorMessage here: operations reload the disc after failing, and the
        // message would vanish before it was shown. Each action clears it when it starts.
        do {
            let status = try await service.getDeviceStatus()
            self.status = status
            disc = status.discPresent ? try await service.listContent() : nil
        } catch where reconnectIfLost && Self.isConnectionLost(error) {
            if await reconnect() {
                await refresh(reconnectIfLost: false)
                return
            }
            if archiveMode || eraseMode {
                // Unplugged on purpose (a portable writes its changes then); carry on when it's back.
                waitForDevice()
            } else {
                errorMessage = "The player stopped answering and couldn't be reconnected. Unplug it for a few seconds, plug it back in, then press Connect."
            }
            return
        } catch {
            // Keep a message that's already showing (it may say to unplug the player).
            if errorMessage == nil { errorMessage = String(describing: error) }
        }
        phase = .connected
        if archiveMode { archiveIfNew() }
        if eraseMode { eraseIfNew() }
    }

    /// The player dropped off USB and came back (it can restart around a bad disc, or the hub
    /// can blink), so the old connection is dead. macOS reports that as an IOUSBHost error.
    static func isConnectionLost(_ error: Error) -> Bool {
        (error as NSError).domain == "IOUSBHostErrorDomain"
    }

    /// Opens the player again after it reappeared on USB. Tries for a few seconds, as it may
    /// still be starting up.
    private func reconnect() async -> Bool {
        await service?.close()
        service = nil
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            if let service = try? await NetMDInterface.openFirstDevice() {
                self.service = service
                deviceName = service.deviceName
                return true
            }
        }
        disc = nil
        status = nil
        statusPolling?.cancel()
        statusPolling = nil
        phase = .disconnected
        return false
    }

    /// In archive or erase mode: connects again by itself when a recorder is plugged in.
    func waitForDevice() {
        deviceWatch?.cancel()
        deviceWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.phase == .disconnected, self.archiveMode || self.eraseMode else { return }
                if !IOUSBHostTransport.connectedDevices().isEmpty {
                    await self.connect()
                    if self.phase != .disconnected { return }
                }
            }
        }
    }

    func disconnect() async {
        hasUnwrittenChanges = false
        statusPolling?.cancel()
        statusPolling = nil
        await service?.close()
        service = nil
        deviceName = nil
        disc = nil
        status = nil
        phase = .disconnected
    }

    /// Runs one device operation at a time, then optionally re-reads the disc.
    func perform(
        _ description: String,
        reload: Bool = true,
        changesDisc: Bool? = nil,
        _ operation: @escaping @Sendable (any DeviceService) async throws -> Void
    ) async {
        guard let service, !isBusy else { return }
        activity = description
        errorMessage = nil
        do {
            try await operation(service)
            if changesDisc ?? reload { hasUnwrittenChanges = true }
        } catch {
            errorMessage = "\(description.trimmingCharacters(in: CharacterSet(charactersIn: "…"))) failed: \(error)"
        }
        activity = nil
        if reload {
            await refresh()
        } else {
            await updateStatus()
        }
    }

    private func updateStatus() async {
        guard let service, !isBusy else { return }
        do {
            let status = try await service.getDeviceStatus()
            let discChanged = status.discPresent != (self.status?.discPresent ?? false)
            self.status = status
            if discChanged { await refresh() }
        } catch where Self.isConnectionLost(error) {
            await refresh() // reconnects
        } catch {}
    }

    /// Keeps the playback state and current track up to date while connected.
    private func startStatusPolling() {
        statusPolling?.cancel()
        statusPolling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isConnected else { return }
                await self.updateStatus()
            }
        }
    }
}
