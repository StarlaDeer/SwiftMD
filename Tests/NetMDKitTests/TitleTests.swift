import Testing
@testable import NetMDKit

@Suite struct DiscTitleTests {
    @Test func plainTitle() {
        #expect(parseDiscTitle("My Disc", wchar: false) == "My Disc")
    }

    @Test func titleWithGroups() {
        #expect(parseDiscTitle("0;My Disc//1-2;Group A//", wchar: false) == "My Disc")
        #expect(parseDiscTitle("1-2;Group A//", wchar: false) == "")
    }

    @Test func fullWidthTitleWithGroups() {
        #expect(parseDiscTitle("０；ディスク／／１－２；グループ／／", wchar: true) == "ディスク")
    }
}

@Suite struct TrackGroupTests {
    @Test func noGroups() throws {
        let groups = try parseTrackGroups(rawTitle: "My Disc", rawFullWidthTitle: "", trackCount: 3)
        #expect(groups == [RawTrackGroup(title: nil, fullWidthTitle: nil, tracks: [0, 1, 2])])
    }

    @Test func groupsAndUngroupedTracks() throws {
        let groups = try parseTrackGroups(
            rawTitle: "0;My Disc//2-3;Group A//5;Single//",
            rawFullWidthTitle: "２－３；グループ／／",
            trackCount: 5
        )
        #expect(groups == [
            RawTrackGroup(title: nil, fullWidthTitle: nil, tracks: [0, 3]),
            RawTrackGroup(title: "Group A", fullWidthTitle: "グループ", tracks: [1, 2]),
            RawTrackGroup(title: "Single", fullWidthTitle: nil, tracks: [4]),
        ])
    }

    @Test func groupClampedToTrackCountAfterDeletion() throws {
        let groups = try parseTrackGroups(rawTitle: "1-4;Group//", rawFullWidthTitle: "", trackCount: 2)
        #expect(groups == [RawTrackGroup(title: "Group", fullWidthTitle: nil, tracks: [0, 1])])
    }

    @Test func overlappingGroupsThrow() {
        #expect(throws: NetMDError.self) {
            try parseTrackGroups(rawTitle: "1-2;A//2-3;B//", rawFullWidthTitle: "", trackCount: 3)
        }
    }

    @Test func fullWidthRange() {
        #expect(halfWidthToFullWidthRange("12-3;") == "１２－３；")
    }
}

@Suite struct TextTests {
    @Test func shiftJISRoundTrip() {
        let title = "ミニディスク Mix"
        #expect(decodeFromSJIS(encodeToSJIS(title)) == title)
        #expect(encodeToSJIS("abc") == [0x61, 0x62, 0x63])
    }

    @Test func time() {
        #expect(timeToFrames([0, 3, 25, 100]) == (3 * 60 + 25) * 512 + 100)
        #expect(formatTimeFromFrames((3 * 60 + 25) * 512 + 100) == "00:03:25+100")
        #expect(formatTimeFromFrames((74 * 60) * 512, frames: false) == "01:14:00")
    }
}
