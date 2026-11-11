import NetMDKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = DeviceModel()
    @State private var confirmWipe = false
    @State private var showImporter = false
    @State private var pendingUploads: [PendingUpload] = []
    @AppStorage("backupExplained") private var backupExplained = false
    @State private var showArchiveExplanation = false
    @State private var confirmEraseMode = false

    var body: some View {
        Group {
            switch model.phase {
            case .disconnected, .connecting:
                ConnectView(model: model)
            case .connected, .loading:
                if let disc = model.disc {
                    DiscView(model: model, disc: disc)
                        .dropDestination(for: URL.self) { urls, _ in
                            guard model.canEdit else { return false }
                            Task { await queue(urls) }
                            return true
                        }
                } else {
                    ContentUnavailableView(
                        "No Disc",
                        systemImage: "opticaldisc",
                        description: Text("Insert a MiniDisc into \(model.deviceName ?? "the recorder"), then refresh.")
                    )
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isUploading {
                UploadProgressBar(model: model)
            } else if model.archiveMode && model.isConnected {
                ArchiveBar(model: model) { model.setArchiveMode(false) }
            } else if model.eraseMode && model.isConnected {
                EraseBar(model: model)
            } else if let folder = model.lastBackupFolder {
                BackupDoneBar(folder: folder) { model.lastBackupFolder = nil }
            } else if model.hasUnwrittenChanges && model.isConnected {
                UnwrittenChangesBar { model.hasUnwrittenChanges = false }
            }
        }
        .frame(minWidth: 620, minHeight: 440)
        .navigationTitle(model.deviceName ?? "SwiftMD")
        .navigationSubtitle(model.activity ?? "")
        .toolbar {
            if model.isConnected {
                ToolbarItemGroup(placement: .navigation) {
                    PlaybackControls(model: model)
                }
                ToolbarItemGroup {
                    if model.isBusy {
                        // A fixed frame keeps the spinner centred in the toolbar's capsule.
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                            .frame(width: 18, height: 18)
                            .padding(.horizontal, 4)
                    }
                    Button(model.archiveMode ? "Archive Mode On" : "Archive Mode",
                           systemImage: model.archiveMode ? "archivebox.fill" : "archivebox") {
                        if model.archiveMode {
                            model.setArchiveMode(false)
                        } else if backupExplained {
                            enableArchiveMode()
                        } else {
                            showArchiveExplanation = true
                        }
                    }
                    .help("Back up every disc you insert into its own folder")
                    .disabled(model.isBusy && !model.archiveMode)
                    Button(model.eraseMode ? "Erase Mode On" : "Erase Mode",
                           systemImage: model.eraseMode ? "eraser.fill" : "eraser") {
                        if model.eraseMode { model.setEraseMode(false) } else { confirmEraseMode = true }
                    }
                    .help("Erase every disc you insert that's already in your archive")
                    .disabled(model.isBusy && !model.eraseMode)
                    Button("Add Music", systemImage: "plus") { showImporter = true }
                        .help("Send audio files to the MiniDisc")
                        .disabled(!model.canEdit)
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                    .disabled(model.isBusy)
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Back Up Disc…", systemImage: "square.and.arrow.down") {
                            model.backupRequest = model.disc?.tracks.map(\.index)
                        }
                        .disabled(model.disc?.tracks.isEmpty ?? true || model.isBusy)
                        Divider()
                        Button("Eject Disc", systemImage: "eject") {
                            Task { await model.perform("Ejecting…", changesDisc: false) { try await $0.ejectDisc() } }
                        }
                        .disabled(model.disc == nil || model.isBusy)
                        Divider()
                        Button("Erase Entire Disc…", systemImage: "trash", role: .destructive) {
                            confirmWipe = true
                        }
                        .disabled(!model.canEdit)
                        Divider()
                        Button("Disconnect", systemImage: "cable.connector.slash") {
                            Task { await model.disconnect() }
                        }
                    }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await queue(urls) }
            }
        }
        .sheet(isPresented: Binding(get: { !pendingUploads.isEmpty }, set: { if !$0 { pendingUploads = [] } })) {
            UploadSheet(files: $pendingUploads, secondsLeft: model.secondsLeft) { format in
                model.upload(pendingUploads, format: format)
                pendingUploads = []
            }
        }
        .alert(
            "Back up tracks to your Mac?",
            isPresented: Binding(
                get: { model.backupRequest != nil && !backupExplained },
                set: { if !$0 && !backupExplained { model.backupRequest = nil } }
            )
        ) {
            Button("Continue") {
                backupExplained = true
                startRequestedBackup()
            }
            Button("Cancel", role: .cancel) { model.backupRequest = nil }
        } message: {
            Text("""
            NetMD recorders can't normally send music back to a computer, so SwiftMD briefly runs a small \
            program on the recorder, the same method Web MiniDisc Pro uses. The disc is only read. The \
            change lives in the recorder's memory and is undone when the backup ends or the recorder is unplugged. \
            If anything goes wrong, SwiftMD will ask you to unplug the recorder for a few seconds, which undoes it.

            Use at your own risk: backups have been tested on the MZ-N910 and MZ-N505, and SwiftMD asks first on \
            other firmware. Copying on Type-R players takes about as long as playing the tracks. Each track is saved twice: an exact copy of the \
            disc (.aea for SP, ATRAC3 .wav for LP), and a playable .m4a in a Playable folder.
            """)
        }
        .alert("Archive your MiniDiscs?", isPresented: $showArchiveExplanation) {
            Button("Continue") {
                backupExplained = true
                DispatchQueue.main.async { enableArchiveMode() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            In archive mode, SwiftMD backs up every disc you insert into its own folder, then ejects it \
            so you can insert the next. Discs already in the archive are skipped.

            NetMD recorders can't normally send music back to a computer, so SwiftMD briefly runs a small \
            program on the recorder, the same method Web MiniDisc Pro uses. Discs are only read, and the \
            changes are undone after each disc or when the recorder is unplugged. If anything goes wrong, \
            SwiftMD will ask you to unplug the recorder for a few seconds, which undoes it.
            """)
        }
        .alert(
            "This player's firmware hasn't been tested",
            isPresented: Binding(
                get: { model.untestedFirmwarePrompt != nil },
                set: { if !$0 { model.untestedFirmwarePrompt = nil; model.afterFirmwareOK = nil } }
            )
        ) {
            Button("Back Up Anyway") { model.allowFirmware() }
            Button("Cancel", role: .cancel) {
                model.untestedFirmwarePrompt = nil
                model.afterFirmwareOK = nil
                if model.archiveMode { model.archiveStatus = "Not archived: this player's firmware wasn't OK'd. Insert another disc, or turn off Archive Mode." }
            }
        } message: {
            Text("""
            Backing up has been tested on firmware S1.600 (MZ-N910) and R1.400 (MZ-N505). This player has \
            \(model.untestedFirmwarePrompt ?? "another version"). The same method works in Web MiniDisc Pro on \
            this firmware, and SwiftMD only ever changes the player's memory, never its firmware, but it \
            hasn't been tried with SwiftMD yet.

            If something goes wrong, unplug the player for a few seconds. SwiftMD will remember your answer \
            for this firmware.
            """)
        }
        .alert("Turn on Erase Mode?", isPresented: $confirmEraseMode) {
            Button("Turn On Erase Mode", role: .destructive) {
                if model.archiveFolder == nil {
                    guard let folder = model.chooseArchiveFolder() else { return }
                    model.archiveFolder = folder
                }
                model.setEraseMode(true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            In Erase Mode, SwiftMD erases each disc you insert, so you can record on it again, but only if \
            it's in your archive: archived completely, every file still in the archive folder, and the disc \
            unchanged since. Discs that aren't archived are left alone. Erasing can't be undone.

            On a portable, unplug the USB cable after each erase (keep the player on power) so it writes the \
            change to the disc. SwiftMD reconnects when you plug it back in.
            """)
        }
        .onChange(of: model.backupRequest) { _, request in
            if request != nil && backupExplained { startRequestedBackup() }
        }
        .confirmationDialog("Erase the entire disc?", isPresented: $confirmWipe) {
            Button("Erase Disc", role: .destructive) {
                Task { await model.perform("Erasing disc…") { try await $0.wipeDisc() } }
            }
        } message: {
            Text("Every track and title on this MiniDisc will be deleted. This can't be undone.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            actions: { Button("OK") {} },
            message: { Text(model.errorMessage ?? "") }
        )
    }
}

extension ContentView {
    private func enableArchiveMode() {
        if model.archiveFolder == nil {
            guard let folder = model.chooseArchiveFolder() else { return }
            model.archiveFolder = folder
        }
        model.setArchiveMode(true)
    }

    private func startRequestedBackup() {
        guard let indexes = model.backupRequest else { return }
        model.backupRequest = nil
        // Let the alert close before the folder panel opens.
        DispatchQueue.main.async {
            if let folder = model.chooseBackupFolder() {
                model.backUp(indexes, to: folder)
            }
        }
    }

    private func queue(_ urls: [URL]) async {
        let files = await model.pendingUploads(for: urls)
        if !files.isEmpty { pendingUploads = files }
    }
}

struct UnwrittenChangesBar: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Your recorder saves these changes to the disc when you unplug it (its screen may show \u{201C}TOC Edit\u{201D} until then). Keep it powered until it returns to its normal screen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("OK", action: dismiss)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct ArchiveBar: View {
    let model: DeviceModel
    let turnOff: () -> Void
    @AppStorage("ejectAfterArchiving") private var ejectWhenDone = true
    @AppStorage("eraseAfterArchiving") private var eraseWhenDone = false
    @State private var confirmErase = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "archivebox.fill")
                .foregroundStyle(.secondary)
            Text(model.archiveStatus ?? "Archive mode is on.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Toggle("Erase when done", isOn: Binding(
                get: { eraseWhenDone },
                set: { on in if on { confirmErase = true } else { eraseWhenDone = false } }
            ))
            .toggleStyle(.checkbox)
            .font(.callout)
            .help("Erase each disc after it has been archived completely")
            if !model.isPortable {
                Toggle("Eject when done", isOn: $ejectWhenDone)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
            if model.canArchiveInsertedDisc {
                Button("Archive This Disc") { model.archiveInsertedDisc() }
                    .keyboardShortcut(.defaultAction)
            }
            Menu("Archive") {
                if let folder = model.archiveFolder {
                    Button("Show Archive in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    Text(folder.path)
                }
                Button("Change Folder…") {
                    if let folder = model.chooseArchiveFolder() { model.archiveFolder = folder }
                }
                Divider()
                Button("Turn Off Archive Mode", action: turnOff)
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .alert("Erase each disc after archiving it?", isPresented: $confirmErase) {
            Button("Erase After Archiving", role: .destructive) { eraseWhenDone = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Once a disc has been archived, SwiftMD will make it blank so you can record on it again. It only erases when every track was copied without a problem, every file is in the archive folder, and the disc in the player is still the one that was archived. Discs that were already archived are erased too when you insert them. Erasing can't be undone.")
        }
    }
}

struct EraseBar: View {
    let model: DeviceModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "eraser.fill")
                .foregroundStyle(.secondary)
            Text(model.eraseStatus ?? "Erase mode is on.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.canEraseInsertedDisc {
                Button("Erase This Disc") { model.eraseInsertedDisc() }
                    .keyboardShortcut(.defaultAction)
            }
            Menu("Erase") {
                if let folder = model.archiveFolder {
                    Button("Show Archive in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    Text("Checks discs against \(folder.path)")
                }
                Button("Change Archive Folder…") {
                    if let folder = model.chooseArchiveFolder() { model.archiveFolder = folder }
                }
                Divider()
                Button("Turn Off Erase Mode") { model.setEraseMode(false) }
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct BackupDoneBar: View {
    let folder: URL
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text("Backup saved to \(folder.lastPathComponent).")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            Button("OK", action: dismiss)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct UploadProgressBar: View {
    let model: DeviceModel

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: model.uploadProgress ?? 0)
                .frame(maxWidth: 220)
            Text(model.activity ?? "")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Stop") { model.isBackingUp ? model.cancelBackup() : model.cancelUpload() }
                .help(model.isBackingUp ? "Stops the backup; the track being copied isn't saved" : "Stops after the track being sent")
                .disabled(model.uploadTask == nil || model.uploadTask?.isCancelled == true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct UploadSheet: View {
    @Binding var files: [PendingUpload]
    let secondsLeft: Double
    let send: (UploadFormat) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var format = UploadFormat.sp

    private var needed: Double { files.reduce(0) { $0 + $1.duration * format.discTimeFactor } }
    private var fits: Bool { needed <= secondsLeft }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(files.count == 1 ? "Send 1 Track" : "Send \(files.count) Tracks")
                .font(.title2.bold())
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
            List {
                ForEach($files) { $file in
                    HStack {
                        TextField("Title", text: $file.title)
                            .textFieldStyle(.plain)
                        Spacer()
                        Text(minutes(file.duration))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { files.remove(atOffsets: $0) }
                .onMove { files.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 160)
            Form {
                Picker("Recording mode", selection: $format) {
                    ForEach(UploadFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(format.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Disc time needed") {
                    Text("\(minutes(needed)) of \(minutes(secondsLeft)) left")
                        .monospacedDigit()
                        .foregroundStyle(fits ? Color.secondary : Color.red)
                }
                if !fits {
                    Text("Not enough room. Try a longer-playing mode or send fewer tracks.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { files = [] }
                    .keyboardShortcut(.cancelAction)
                Button("Send to MiniDisc") { send(format) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!fits || files.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520, height: 520)
    }
}

struct PlaybackControls: View {
    let model: DeviceModel

    var body: some View {
        let playing = model.status?.state == .playing
        let disabled = model.disc == nil || model.isBusy
        Group {
            Button("Previous Track", systemImage: "backward.end.fill") {
                Task { await model.perform("Skipping back…", reload: false) { try await $0.previousTrack() } }
            }
            Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                Task {
                    await model.perform(playing ? "Pausing…" : "Playing…", reload: false) {
                        playing ? try await $0.pause() : try await $0.play()
                    }
                }
            }
            Button("Stop", systemImage: "stop.fill") {
                Task { await model.perform("Stopping…", reload: false) { try await $0.stop() } }
            }
            Button("Next Track", systemImage: "forward.end.fill") {
                Task { await model.perform("Skipping ahead…", reload: false) { try await $0.nextTrack() } }
            }
        }
        .disabled(disabled)
    }
}

struct ConnectView: View {
    let model: DeviceModel

    var body: some View {
        ContentUnavailableView {
            Label("Connect a NetMD Recorder", systemImage: "cable.connector")
        } description: {
            if model.archiveMode || model.eraseMode {
                Text(((model.eraseMode ? model.eraseStatus : model.archiveStatus).map { $0 + "\n\n" } ?? "")
                     + "Waiting for the recorder. Plug it back in and SwiftMD carries on by itself.")
            } else {
                Text("Plug in your MiniDisc recorder with a USB cable, then connect. Quit ElectronWMD first if it's open.")
            }
        } actions: {
            Button {
                Task { await model.connect() }
            } label: {
                if model.phase == .connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.phase == .connecting)
        }
    }
}

// MARK: - Disc

/// Something being renamed, shown in the rename sheet.
enum RenameTarget: Identifiable {
    case disc(Disc)
    case track(Track)
    case group(NetMDKit.Group)
    case newGroup(begin: Int, length: Int)

    var id: String {
        switch self {
        case .disc: return "disc"
        case .track(let t): return "track-\(t.index)"
        case .group(let g): return "group-\(g.index)"
        case .newGroup(let b, let l): return "new-\(b)-\(l)"
        }
    }
}

struct DiscView: View {
    let model: DeviceModel
    let disc: Disc
    @State private var selection = Set<Int>()
    @State private var renaming: RenameTarget?
    @State private var confirmDelete: [Int]?

    var body: some View {
        List(selection: $selection) {
            Section {
                DiscHeader(disc: disc, canEdit: model.canEdit) { renaming = .disc(disc) }
            }
            ForEach(disc.groups) { group in
                Section {
                    ForEach(group.tracks) { track in
                        TrackRow(track: track, isCurrent: model.status?.track == track.index && model.status?.state == .playing)
                            .tag(track.index)
                            .contextMenu { trackMenu(track) }
                    }
                    .onMove { offsets, destination in
                        move(in: group, from: offsets, to: destination)
                    }
                    .moveDisabled(!model.canEdit)
                } header: {
                    if let title = group.title {
                        GroupHeader(title: title, fullWidthTitle: group.fullWidthTitle)
                            .contextMenu {
                                Button("Rename Group…") { renaming = .group(group) }
                                Button("Ungroup") {
                                    Task { await model.perform("Removing group…") { try await $0.deleteGroup(group.index) } }
                                }
                            }
                            .disabled(!model.canEdit)
                    }
                }
            }
        }
        .onKeyPress(.return) {
            guard model.canEdit, selection.count == 1, let track = disc.tracks.first(where: { $0.index == selection.first }) else {
                return .ignored
            }
            renaming = .track(track)
            return .handled
        }
        .onDeleteCommand {
            if model.canEdit, !selection.isEmpty { confirmDelete = selection.sorted() }
        }
        .overlay {
            if disc.tracks.isEmpty {
                ContentUnavailableView("Blank Disc", systemImage: "opticaldisc", description: Text("This disc has no tracks."))
            }
        }
        .sheet(item: $renaming) { target in
            RenameSheet(target: target) { title, fullWidth in
                save(target, title: title, fullWidth: fullWidth)
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                let indexes = confirmDelete ?? []
                selection = []
                Task { await model.perform("Deleting \(indexes.count == 1 ? "track" : "tracks")…") { try await $0.deleteTracks(indexes) } }
            }
        } message: {
            Text("This removes the audio from the MiniDisc. It can't be undone.")
        }
    }

    private var deleteTitle: String {
        let count = confirmDelete?.count ?? 0
        return count == 1 ? "Delete track \((confirmDelete?.first ?? 0) + 1)?" : "Delete \(count) tracks?"
    }

    /// The selected tracks, if they're a run of neighbouring ungrouped tracks that can become a group.
    private var groupableSelection: (begin: Int, length: Int)? {
        let indexes = selection.sorted()
        guard let first = indexes.first,
              indexes.last! - first + 1 == indexes.count,
              let ungrouped = disc.groups.first(where: { $0.isUngrouped }),
              indexes.allSatisfy({ i in ungrouped.tracks.contains { $0.index == i } })
        else { return nil }
        return (first, indexes.count)
    }

    @ViewBuilder
    private func trackMenu(_ track: Track) -> some View {
        Button("Play") {
            Task {
                await model.perform("Playing track \(track.index + 1)…", reload: false) {
                    try await $0.gotoTrack(track.index)
                    try await $0.play()
                }
            }
        }
        .disabled(model.isBusy)
        Button(backupTitle(for: track)) {
            model.backupRequest = selection.contains(track.index) ? selection.sorted() : [track.index]
        }
        .disabled(model.isBusy)
        Divider()
        Group {
            Button("Rename…") { renaming = .track(track) }
            Button("Move Up") { moveTrack(track.index, to: track.index - 1) }
                .disabled(track.index == 0)
            Button("Move Down") { moveTrack(track.index, to: track.index + 1) }
                .disabled(track.index == disc.trackCount - 1)
            if let run = groupableSelection, selection.contains(track.index) {
                Button(run.length == 1 ? "Make Group…" : "Group \(run.length) Tracks…") {
                    renaming = .newGroup(begin: run.begin, length: run.length)
                }
            }
            Divider()
            Button("Delete…", role: .destructive) {
                confirmDelete = selection.contains(track.index) ? selection.sorted() : [track.index]
            }
        }
        .disabled(!model.canEdit)
    }

    private func backupTitle(for track: Track) -> String {
        let count = selection.contains(track.index) ? selection.count : 1
        return count == 1 ? "Back Up to Mac…" : "Back Up \(count) Tracks to Mac…"
    }

    private func moveTrack(_ source: Int, to dest: Int) {
        Task { await model.perform("Moving track \(source + 1)…") { try await $0.moveTrack(source, to: dest, updateGroups: true) } }
    }

    private func move(in group: NetMDKit.Group, from offsets: IndexSet, to destination: Int) {
        guard offsets.count == 1, let offset = offsets.first else { return }
        let source = group.tracks[offset].index
        // SwiftUI gives the position before removing the moved row; the deck wants the final position.
        var dest = destination < group.tracks.count ? group.tracks[destination].index : group.tracks.last!.index + 1
        if dest > source { dest -= 1 }
        guard dest != source else { return }
        moveTrack(source, to: dest)
    }

    private func save(_ target: RenameTarget, title: String, fullWidth: String) {
        let fw: String? = fullWidth.isEmpty ? nil : fullWidth
        switch target {
        case .disc:
            Task { await model.perform("Renaming disc…") { try await $0.renameDisc(title, fullWidth: fullWidth) } }
        case .track(let track):
            Task { await model.perform("Renaming track \(track.index + 1)…") { try await $0.renameTrack(track.index, title: title, fullWidthTitle: fw) } }
        case .group(let group):
            Task { await model.perform("Renaming group…") { try await $0.renameGroup(group.index, title: title, fullWidthTitle: fullWidth) } }
        case .newGroup(let begin, let length):
            selection = []
            Task { await model.perform("Creating group…") { try await $0.addGroup(begin: begin, length: length, title: title, fullWidthTitle: fullWidth) } }
        }
    }
}

struct DiscHeader: View {
    let disc: Disc
    let canEdit: Bool
    let rename: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(disc.title.isEmpty ? "Untitled Disc" : disc.title)
                    .font(.title2.bold())
                    .foregroundStyle(disc.title.isEmpty ? .secondary : .primary)
                if !disc.fullWidthTitle.isEmpty && disc.fullWidthTitle != disc.title {
                    Text(disc.fullWidthTitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Button("Rename Disc", systemImage: "pencil", action: rename)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!canEdit)
                Spacer()
                if disc.writeProtected {
                    Label("Write-protected", systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(disc.used), total: Double(max(disc.total, 1)))
            Text("\(disc.trackCount) tracks · \(duration(disc.used)) used · \(duration(disc.left)) left of \(duration(disc.total))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

struct GroupHeader: View {
    let title: String
    let fullWidthTitle: String?

    var body: some View {
        HStack {
            Image(systemName: "folder")
            Text(title)
            if let fullWidthTitle, !fullWidthTitle.isEmpty, fullWidthTitle != title {
                Text(fullWidthTitle).foregroundStyle(.secondary)
            }
        }
    }
}

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                } else {
                    Text("\(track.index + 1)").foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Track \(track.index + 1)")
                    .foregroundStyle(track.title?.isEmpty == false ? .primary : .secondary)
                if let full = track.fullWidthTitle, !full.isEmpty, full != track.title {
                    Text(full).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if track.isProtected {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Protected track")
            }
            Text(track.encodingName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            Text(duration(track.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

// MARK: - Rename sheet

struct RenameSheet: View {
    let target: RenameTarget
    let save: (_ title: String, _ fullWidth: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var fullWidth = ""

    private var heading: String {
        switch target {
        case .disc: return "Rename Disc"
        case .track(let t): return "Rename Track \(t.index + 1)"
        case .group: return "Rename Group"
        case .newGroup(_, let length): return length == 1 ? "New Group" : "Group \(length) Tracks"
        }
    }

    var body: some View {
        Form {
            TextField("Title", text: $title, prompt: Text("Title"))
            TextField("Japanese title", text: $fullWidth, prompt: Text("Optional, full-width"))
            Text(preview)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .navigationTitle(heading)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save(title, fullWidth)
                    dismiss()
                }
            }
        }
        .onAppear {
            switch target {
            case .disc(let d): (title, fullWidth) = (d.title, d.fullWidthTitle)
            case .track(let t): (title, fullWidth) = (t.title ?? "", t.fullWidthTitle ?? "")
            case .group(let g): (title, fullWidth) = (g.title ?? "", g.fullWidthTitle ?? "")
            case .newGroup: break
            }
        }
    }

    /// Shows how the title will be stored, since MiniDiscs only hold a limited character set.
    private var preview: String {
        let stored = sanitizeHalfWidthTitle(title)
        return stored == title ? "Saved as typed." : "Will be saved as \u{201C}\(stored)\u{201D}."
    }
}

/// Formats frames (512 per second) as m:ss, or h:mm:ss for an hour or more.
func duration(_ frames: Int) -> String {
    let seconds = frames / framesPerSecond
    let (h, m, s) = (seconds / 3600, (seconds / 60) % 60, seconds % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
