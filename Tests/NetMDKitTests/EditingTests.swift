import Testing
@testable import NetMDKit

@Suite struct SanitizeTests {
    @Test func halfWidthKeepsASCIIAndStripsAccents() {
        #expect(sanitizeHalfWidthTitle("Hello, World!") == "Hello, World!")
        #expect(sanitizeHalfWidthTitle("Café Mañana") == "Cafe Manana")
    }

    @Test func halfWidthConvertsKana() {
        #expect(sanitizeHalfWidthTitle("ミニディスク") == "ﾐﾆﾃﾞｨｽｸ")
        #expect(sanitizeHalfWidthTitle("ＡＢＣ　１２３") == "ABC 123")
        // A decomposed dakuten is folded into the kana before converting.
        #expect(sanitizeHalfWidthTitle("カ\u{3099}") == "ｶﾞ")
    }

    @Test func halfWidthReplacesUnsupportedCharacters() {
        #expect(sanitizeHalfWidthTitle("A→B") == "A B")
    }

    @Test func halfWidthLengthCountsDakuten() {
        #expect(getHalfWidthTitleLength("abc") == 3)
        #expect(getHalfWidthTitleLength("ガギ") == 4)
    }

    @Test func fullWidthConvertsASCII() {
        #expect(sanitizeFullWidthTitle("abc 1") == "ａｂｃ　１")
        #expect(sanitizeFullWidthTitle("ﾐﾆ") == "ミニ")
    }

    @Test func fullWidthFallsBackWhenItCantMapEverything() {
        // Shift-JIS has no emoji, so the title can't be all 2-byte characters; keep only ASCII.
        #expect(sanitizeFullWidthTitle("A🎵") == "A")
    }
}

@Suite struct GroupCompileTests {
    func disc(title: String = "Mix", groups: [Group]) -> Disc {
        let count = groups.reduce(0) { $0 + $1.tracks.count }
        return Disc(title: title, fullWidthTitle: "", writable: true, writeProtected: false,
                    used: 0, left: 0, total: 0, trackCount: count, groups: groups)
    }

    func tracks(_ range: ClosedRange<Int>) -> [Track] {
        range.map { Track(index: $0, title: "T\($0)", fullWidthTitle: nil, duration: 0, channel: 0, encoding: 0x90, protected: 0) }
    }

    @Test func titleAndGroups() {
        let d = disc(groups: [
            Group(index: 0, title: nil, fullWidthTitle: nil, tracks: tracks(0...0)),
            Group(index: 1, title: "Side B", fullWidthTitle: nil, tracks: tracks(1...2)),
            Group(index: 2, title: "Bonus", fullWidthTitle: nil, tracks: tracks(3...3)),
        ])
        let compiled = compileDiscTitles(d)
        #expect(compiled.rawTitle == "0;Mix//2-3;Side B//4;Bonus//")
        #expect(compiled.rawFullWidthTitle == "")
    }

    @Test func noGroupsWritesPlainTitle() {
        let compiled = compileDiscTitles(disc(groups: [Group(index: 0, title: nil, fullWidthTitle: nil, tracks: tracks(0...2))]))
        #expect(compiled.rawTitle == "Mix")
    }

    @Test func fullWidthGroupsWhenAnyFullWidthTitleExists() {
        var d = disc(groups: [Group(index: 0, title: "A", fullWidthTitle: "Ａ", tracks: tracks(0...1))])
        d.fullWidthTitle = "ミックス"
        let compiled = compileDiscTitles(d)
        #expect(compiled.rawTitle == "0;Mix//1-2;A//")
        #expect(compiled.rawFullWidthTitle == "０；ミックス／／１－２；Ａ／／")
    }

    @Test func deleteShiftsLaterGroups() {
        let d = disc(groups: [
            Group(index: 0, title: "A", fullWidthTitle: nil, tracks: tracks(0...1)),
            Group(index: 1, title: "B", fullWidthTitle: nil, tracks: tracks(2...4)),
        ])
        let after = recomputeGroupsAfterTrackMove(d, from: 0, to: nil)
        #expect(after.groups.map(\.title) == ["A", "B"])
        #expect(after.groups.map { $0.tracks.map(\.index) } == [[0], [1, 2, 3]])
        #expect(compileDiscTitles(after).rawTitle == "0;Mix//1;A//2-4;B//")
    }

    @Test func deletingAGroupsOnlyTrackRemovesTheGroup() {
        let d = disc(groups: [
            Group(index: 0, title: "A", fullWidthTitle: nil, tracks: tracks(0...0)),
            Group(index: 1, title: "B", fullWidthTitle: nil, tracks: tracks(1...2)),
        ])
        let after = recomputeGroupsAfterTrackMove(d, from: 0, to: nil)
        #expect(after.groups.map(\.title) == ["B"])
        #expect(after.groups[0].tracks.map(\.index) == [0, 1])
    }

    @Test func moveIntoAGroupShiftsItsStart() {
        // Track 0 (ungrouped) moves to the end of group B's range and joins it, as in Web MiniDisc.
        let d = disc(groups: [
            Group(index: 0, title: nil, fullWidthTitle: nil, tracks: tracks(0...0)),
            Group(index: 1, title: "B", fullWidthTitle: nil, tracks: tracks(1...3)),
        ])
        let after = recomputeGroupsAfterTrackMove(d, from: 0, to: 3)
        #expect(compileDiscTitles(after).rawTitle == "0;Mix//1-4;B//")
    }

    @Test func replaceTitleKeepsGroups() {
        #expect(replaceTitle(in: "0;Old//1-2;G//", with: "New", marker: "0;", delimiter: "//") == "0;New//1-2;G//")
        #expect(replaceTitle(in: "1-2;G//", with: "New", marker: "0;", delimiter: "//") == "0;New//1-2;G//")
        #expect(replaceTitle(in: "0;Old//1-2;G//", with: "", marker: "0;", delimiter: "//") == "1-2;G//")
        #expect(replaceTitle(in: "Old", with: "New", marker: "0;", delimiter: "//") == "New")
    }
}

@Suite struct EditingOperationTests {
    func makeDevice() -> FakeNetMDDevice {
        FakeNetMDDevice(
            rawTitle: "0;Road Trip//2-3;Side B//",
            tracks: [
                .init(title: "Intro", length: [0, 1, 0, 0]),
                .init(title: "Highway", length: [0, 2, 0, 0]),
                .init(title: "Exit", length: [0, 3, 0, 0]),
                .init(title: "", length: [0, 4, 0, 0]),
            ]
        )
    }

    func open(_ device: FakeNetMDDevice) async throws -> NetMDInterface {
        try await NetMDInterface.open(transport: device, vendorID: 0x054c, productID: 0x00c7)
    }

    @Test func renameTrack() async throws {
        let device = makeDevice()
        let iface = try await open(device)
        try await iface.renameTrack(3, title: "Encore", fullWidthTitle: "アンコール")
        #expect(device.tracks[3].title == "Encore")
        #expect(device.tracks[3].fullWidthTitle == "アンコール")
        try await iface.renameTrack(0, title: "Café")
        #expect(device.tracks[0].title == "Cafe")
        #expect(device.writeErrors.isEmpty)
    }

    @Test func renameDiscKeepsGroups() async throws {
        let device = makeDevice()
        let iface = try await open(device)
        try await iface.renameDisc("Summer")
        #expect(device.rawTitle == "0;Summer//2-3;Side B//")
        let disc = try await iface.listContent()
        #expect(disc.title == "Summer")
        #expect(disc.groups.map(\.title) == [nil, "Side B"])
        #expect(device.writeErrors.isEmpty)
    }

    @Test func addRenameAndDeleteGroups() async throws {
        let device = makeDevice()
        let iface = try await open(device)

        try await iface.addGroup(begin: 0, length: 1, title: "Opening")
        #expect(device.rawTitle == "0;Road Trip//1;Opening//2-3;Side B//")

        try await iface.renameGroup(2, title: "B-Side")
        #expect(device.rawTitle == "0;Road Trip//1;Opening//2-3;B-Side//")

        try await iface.deleteGroup(1)
        #expect(device.rawTitle == "0;Road Trip//2-3;B-Side//")
        #expect(device.writeErrors.isEmpty)
    }

    @Test func groupingAlreadyGroupedTracksFails() async throws {
        let iface = try await open(makeDevice())
        await #expect(throws: EditError.trackInTwoGroups) {
            try await iface.addGroup(begin: 1, length: 2, title: "Nope")
        }
    }

    @Test func deleteTracksUpdatesGroups() async throws {
        let device = makeDevice()
        let iface = try await open(device)
        try await iface.deleteTracks([0])
        #expect(device.tracks.map(\.title) == ["Highway", "Exit", ""])
        #expect(device.rawTitle == "0;Road Trip//1-2;Side B//")
        #expect(device.writeErrors.isEmpty)
    }

    @Test func moveTrackUpdatesGroups() async throws {
        let device = makeDevice()
        let iface = try await open(device)
        try await iface.moveTrack(3, to: 0, updateGroups: true)
        #expect(device.tracks.map(\.title) == ["", "Intro", "Highway", "Exit"])
        #expect(device.rawTitle == "0;Road Trip//3-4;Side B//")
    }

    @Test func playbackCommands() async throws {
        let device = makeDevice()
        let iface = try await open(device)
        try await iface.play()
        try await iface.pause()
        #expect(device.playActions == [PlayAction.play.rawValue, PlayAction.pause.rawValue])
        try await iface.gotoTrack(2)
        try await iface.nextTrack()
        #expect(device.currentTrack == 3)
        try await iface.stop()
        #expect(device.stopped)
        try await iface.ejectDisc()
        #expect(device.ejected)
    }

    @Test func concurrentQueriesDontGetEachOthersReplies() async throws {
        let device = makeDevice()
        device.slowReplies = true
        let iface = try await open(device)
        async let disc = iface.listContent()
        async let status = iface.getDeviceStatus()
        async let title = iface.getTrackTitle(1)
        let (d, s, t) = try await (disc, status, title)
        #expect(d.tracks.count == 4)
        #expect(s.state == .ready)
        #expect(t == "Highway")
    }
}
