// SwiftMD - the device-facing API the UI talks to. Mirrors the shape of
// webminidisc's src/services/interfaces/netmd.ts so NetMD, Hi-MD and Walkman
// back ends can share one interface as they are added.

public protocol DeviceService: Actor {
    nonisolated var deviceName: String { get }
    func listContent() async throws -> Disc
    func getDeviceStatus() async throws -> DeviceStatus
    func close()

    // Editing
    func renameDisc(_ newName: String, fullWidth: String?) async throws
    func renameTrack(_ index: Int, title: String, fullWidthTitle: String?) async throws
    func renameGroup(_ groupIndex: Int, title: String, fullWidthTitle: String?) async throws
    func addGroup(begin: Int, length: Int, title: String, fullWidthTitle: String) async throws
    func deleteGroup(_ groupIndex: Int) async throws
    func deleteTracks(_ indexes: [Int]) async throws
    func moveTrack(_ source: Int, to dest: Int, updateGroups: Bool) async throws
    func wipeDisc() async throws

    // Playback
    func play() async throws
    func pause() async throws
    func stop() async throws
    func nextTrack() async throws
    func previousTrack() async throws
    @discardableResult func gotoTrack(_ track: Int) async throws -> Int
    func ejectDisc() async throws

    // Uploading
    /// Sends `count` tracks in one secure session; `prepare` supplies each one just before it's sent.
    /// Cancelling stops between tracks.
    func upload(
        count: Int,
        prepare: @escaping @Sendable (Int) async throws -> MDTrack,
        progress: (@Sendable (Int, UploadProgress) -> Void)?
    ) async throws

    // Backing up
    /// Copies tracks off the disc using factory mode. The disc is only read; code is loaded into
    /// the player's RAM while copying. Throws `ExploitError.untestedFirmware` unless the firmware has
    /// been tested or is in `alsoAllowedFirmware` (versions the user agreed to try).
    func backUp(
        tracks: [Int],
        alsoAllowedFirmware: Set<String>,
        progress: @escaping @Sendable (Int, DownloadProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool,
        save: @escaping @Sendable (Int, DownloadedTrack) async throws -> Void
    ) async throws

    /// The disc's TOC and the player's firmware, for archiving. Read-only.
    func archiveInfo() async throws -> (toc: TableOfContents, firmware: String)
}

extension NetMDInterface: DeviceService {
    public func upload(
        count: Int,
        prepare: @escaping @Sendable (Int) async throws -> MDTrack,
        progress: (@Sendable (Int, UploadProgress) -> Void)?
    ) async throws {
        try await UploadSession.upload(count: count, to: self, prepare: prepare, progress: progress)
    }
}
