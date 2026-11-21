// SwiftMD - disc editing.
// Ported from netmd-js src/netmd-commands.ts (titles and groups) and
// webminidisc src/services/interfaces/netmd.ts + src/utils.ts (track/group operations).
// Original: Copyright (C) Stefano Brilli, Asivery. Licensed under the GNU General Public License v2.0.

import Foundation

public enum EditError: Error, Equatable, CustomStringConvertible {
    case trackInTwoGroups
    case tracksNotSequential
    case noSuchGroup

    public var description: String {
        switch self {
        case .trackInTwoGroups: return "A track cannot be in 2 groups!"
        case .tracksNotSequential: return "Groups must be a run of neighbouring tracks."
        case .noSuchGroup: return "That group no longer exists."
        }
    }
}

// MARK: - Title space accounting (a disc has 255 title cells of 7 bytes)
// See https://www.minidisc.org/md_toc.html

private let cellLimit = 255
private func charsToCells(_ length: Int) -> Int { (length + 6) / 7 }

public func getCellsForTitle(_ track: Track) -> (halfWidth: Int, fullWidth: Int) {
    // Sometimes 'LP: ' is added to track names even if the title is '' (+1 cell for non-sp tracks)
    let encodingNameCorrection = track.encoding == Encoding.sp.rawValue ? 0 : 1
    let fullWidthLength = charsToCells((track.fullWidthTitle?.utf16.count ?? 0) * 2)
    let halfWidthLength = charsToCells(getHalfWidthTitleLength(track.title ?? ""))
    return (max(encodingNameCorrection, halfWidthLength), max(encodingNameCorrection, fullWidthLength))
}

/// Characters still free for titles, counting the disc title, group list and every track title.
public func getRemainingCharactersForTitles(_ disc: Disc, includeGroups: Bool = true) -> (halfWidth: Int, fullWidth: Int) {
    // Assume worst-case scenario
    var fullWidthTitle = disc.fullWidthTitle + "0;//"
    var halfWidthTitle = disc.title + "0;//"
    if includeGroups {
        for group in disc.groups where group.title != nil && !group.tracks.isEmpty {
            let indexes = group.tracks.map(\.index)
            let lower = indexes.min()! + 1, upper = indexes.max()! + 1
            let range = (group.tracks.count > 1 ? "\(lower)-\(upper)" : "\(lower)") + "//"
            // The order of these characters doesn't matter. It's for length only
            fullWidthTitle += (group.fullWidthTitle ?? "") + range
            halfWidthTitle += (group.title ?? "") + range
        }
    }

    var usedHalfWidth = charsToCells(getHalfWidthTitleLength(halfWidthTitle))
    var usedFullWidth = charsToCells(fullWidthTitle.utf16.count * 2)
    for track in disc.tracks {
        let cells = getCellsForTitle(track)
        usedHalfWidth += cells.halfWidth
        usedFullWidth += cells.fullWidth
    }
    return (max(cellLimit - usedHalfWidth, 0) * 7, max(cellLimit - usedFullWidth, 0) * 7)
}

/// Builds the raw disc titles ("0;Title//1-3;Group//") for a disc's title and groups,
/// dropping groups that don't fit in the remaining title space.
public func compileDiscTitles(_ disc: Disc) -> (rawTitle: String, rawFullWidthTitle: String) {
    var withoutTitles = disc
    withoutTitles.title = ""
    withoutTitles.fullWidthTitle = ""
    let (availableHalfWidth, availableFullWidth) = getRemainingCharactersForTitles(withoutTitles, includeGroups: false)

    // If the disc or any of the groups, or any track has a full-width title, provide support for them
    let useFullWidth = !disc.fullWidthTitle.isEmpty
        || disc.groups.contains { !($0.fullWidthTitle ?? "").isEmpty }
        || disc.tracks.contains { !($0.fullWidthTitle ?? "").isEmpty }

    var rawTitle = disc.title.isEmpty ? "" : "0;\(disc.title)//"
    var rawFullWidthTitle = useFullWidth ? "０；\(disc.fullWidthTitle)／／" : ""
    var groupHits = 0

    for group in disc.groups {
        guard let title = group.title, !group.tracks.isEmpty else { continue }
        groupHits += 1
        let first = group.tracks.map(\.index).min()!
        var range = "\(first + 1)"
        if group.tracks.count != 1 {
            range += "-\(first + group.tracks.count)"
        }

        let titleAfterGroup = rawTitle + "\(range);\(title)//"
        let fullWidthAfterGroup = rawFullWidthTitle + halfWidthToFullWidthRange(range) + "；\(group.fullWidthTitle ?? "")／／"

        // Try to fit as many groups as possible.
        if useFullWidth, availableFullWidth - charsToCells(fullWidthAfterGroup.utf16.count * 2) * 7 >= 0 {
            rawFullWidthTitle = fullWidthAfterGroup
        }
        if availableHalfWidth - charsToCells(getHalfWidthTitleLength(titleAfterGroup)) * 7 >= 0 {
            rawTitle = titleAfterGroup
        }
    }

    if groupHits == 0 {
        // If there's no real groups, switch to original titles.
        rawTitle = disc.title
        rawFullWidthTitle = disc.fullWidthTitle
    }

    // If the titles without the groups already take too much space, don't write them.
    // (netmd-js leaves out the "* 7" on the full-width check; both are counted in characters here.)
    if availableHalfWidth - charsToCells(getHalfWidthTitleLength(rawTitle)) * 7 < 0 {
        rawTitle = ""
    }
    if availableFullWidth - charsToCells(rawFullWidthTitle.utf16.count * 2) * 7 < 0 {
        rawFullWidthTitle = ""
    }
    return (rawTitle, useFullWidth ? rawFullWidthTitle : "")
}

/// Shifts group boundaries after a track moves from `trackIndex` to `targetIndex`,
/// or is deleted when `targetIndex` is nil.
public func recomputeGroupsAfterTrackMove(_ disc: Disc, from trackIndex: Int, to targetIndex: Int?) -> Disc {
    let deleteMode = targetIndex == nil
    let target = targetIndex ?? disc.trackCount
    let offset = deleteMode ? -1 : (trackIndex > target ? 1 : -1)
    let boundsStart = min(trackIndex, target)
    let boundsEnd = max(trackIndex, target)

    var allTracks = disc.tracks.sorted { $0.index < $1.index }
    if deleteMode {
        allTracks.removeAll { $0.index == trackIndex }
    }

    struct Boundary { var title: String?; var fullWidthTitle: String?; var start: Int; var end: Int }
    var boundaries = disc.groups.filter { $0.title != nil && !$0.tracks.isEmpty }.map {
        Boundary(title: $0.title, fullWidthTitle: $0.fullWidthTitle, start: $0.tracks[0].index, end: $0.tracks[0].index + $0.tracks.count - 1)
    }

    var anyChanges = false
    for i in boundaries.indices {
        if boundaries[i].start > boundsStart && boundaries[i].start <= boundsEnd {
            boundaries[i].start += offset
            anyChanges = true
        }
        if boundaries[i].end >= boundsStart && boundaries[i].end < boundsEnd {
            boundaries[i].end += offset
            anyChanges = true
        }
    }
    if !anyChanges && !deleteMode { return disc }

    if deleteMode {
        for i in allTracks.indices { allTracks[i].index = i }
    }

    var newDisc = disc
    if deleteMode { newDisc.trackCount = allTracks.count }
    newDisc.groups = boundaries.compactMap { b in
        let lower = max(b.start, 0), upper = min(b.end, allTracks.count - 1)
        guard lower <= upper else { return nil }
        return Group(index: lower, title: b.title, fullWidthTitle: b.fullWidthTitle, tracks: Array(allTracks[lower...upper]))
    }
    let grouped = Set(newDisc.groups.flatMap { $0.tracks.map(\.index) })
    let ungrouped = allTracks.filter { !grouped.contains($0.index) }
    if !ungrouped.isEmpty {
        newDisc.groups.insert(Group(index: 0, title: nil, fullWidthTitle: nil, tracks: ungrouped), at: 0)
    }
    for i in newDisc.groups.indices { newDisc.groups[i].index = i }
    return newDisc
}

func isSequential(_ numbers: [Int]) -> Bool {
    zip(numbers, numbers.dropFirst()).allSatisfy { $1 == $0 + 1 }
}

// MARK: - Operations

extension NetMDInterface {
    /// Writes the disc's group list (and title) from `disc`.
    public func rewriteDiscGroups(_ disc: Disc) async throws {
        let compiled = compileDiscTitles(disc)
        try await setDiscTitle(compiled.rawTitle)
        try await setDiscTitle(compiled.rawFullWidthTitle, wchar: true)
    }

    public func renameDisc(_ newName: String, fullWidth newFullWidthName: String? = nil) async throws {
        let newName = sanitizeHalfWidthTitle(newName)
        let newFullWidthName = newFullWidthName.map { sanitizeFullWidthTitle($0) }

        let oldName = try await getDiscTitle()
        let oldFullWidthName = try await getDiscTitle(wchar: true)
        let oldRawName = try await rawDiscTitle()
        let oldRawFullWidthName = try await rawDiscTitle(wchar: true)

        if let newFullWidthName, newFullWidthName != oldFullWidthName {
            // netmd-js looks for the full-width group markers in the half-width title here;
            // they live in the full-width one.
            try await setDiscTitle(
                replaceTitle(in: oldRawFullWidthName, with: newFullWidthName, marker: "０；", delimiter: "／／"),
                wchar: true
            )
        }
        if newName != oldName {
            try await setDiscTitle(replaceTitle(in: oldRawName, with: newName, marker: "0;", delimiter: "//"))
        }
    }

    public func renameTrack(_ index: Int, title: String, fullWidthTitle: String? = nil) async throws {
        try await setTrackTitle(index, title)
        if let fullWidthTitle {
            try await setTrackTitle(index, fullWidthTitle, wchar: true)
        }
    }

    public func renameGroup(_ groupIndex: Int, title: String, fullWidthTitle: String? = nil) async throws {
        var disc = try await listContent()
        guard let i = disc.groups.firstIndex(where: { $0.index == groupIndex && $0.title != nil }) else {
            throw EditError.noSuchGroup
        }
        disc.groups[i].title = title
        if let fullWidthTitle { disc.groups[i].fullWidthTitle = fullWidthTitle }
        try await rewriteDiscGroups(disc)
    }

    /// Groups `length` ungrouped tracks starting at track `begin`.
    public func addGroup(begin: Int, length: Int, title: String, fullWidthTitle: String = "") async throws {
        var disc = try await listContent()
        guard let u = disc.groups.firstIndex(where: { $0.title == nil }) else {
            throw EditError.trackInTwoGroups // Only ungrouped tracks can be grouped
        }
        let range = begin..<(begin + length)
        let newTracks = disc.groups[u].tracks.filter { range.contains($0.index) }
        guard newTracks.count == length else { throw EditError.trackInTwoGroups }
        guard isSequential(newTracks.map(\.index)) else { throw EditError.tracksNotSequential }

        disc.groups[u].tracks.removeAll { range.contains($0.index) }
        disc.groups.append(Group(index: disc.groups.count, title: title, fullWidthTitle: fullWidthTitle, tracks: newTracks))
        disc.groups = disc.groups.filter { !$0.tracks.isEmpty }.sorted { $0.tracks[0].index < $1.tracks[0].index }
        try await rewriteDiscGroups(disc)
    }

    /// Removes a group; its tracks become ungrouped.
    public func deleteGroup(_ groupIndex: Int) async throws {
        var disc = try await listContent()
        guard let i = disc.groups.firstIndex(where: { $0.index == groupIndex && $0.title != nil }) else {
            throw EditError.noSuchGroup
        }
        let removed = disc.groups.remove(at: i)
        if let u = disc.groups.firstIndex(where: { $0.title == nil }) {
            disc.groups[u].tracks = (disc.groups[u].tracks + removed.tracks).sorted { $0.index < $1.index }
        } else {
            disc.groups.insert(Group(index: -1, title: nil, fullWidthTitle: nil, tracks: removed.tracks), at: 0)
        }
        try await rewriteDiscGroups(disc)
    }

    public func deleteTracks(_ indexes: [Int]) async throws {
        var disc = try await listContent()
        for index in Set(indexes).sorted(by: >) { // Highest first, so earlier indexes stay valid
            // Attempt to get panasonics working correctly (MyNameIsX)
            _ = try? await getTrackTitle(index)
            _ = try await getTrackCount()
            disc = recomputeGroupsAfterTrackMove(disc, from: index, to: nil)
            try await eraseTrack(index)
            await uninterruptibleSleep(.milliseconds(100))
        }
        try await rewriteDiscGroups(disc)
    }

    public func moveTrack(_ source: Int, to dest: Int, updateGroups: Bool) async throws {
        let disc = updateGroups ? try await listContent() : nil
        try await moveTrack(source, to: dest)
        if let disc {
            try await rewriteDiscGroups(recomputeGroupsAfterTrackMove(disc, from: source, to: dest))
        }
    }

    public func wipeDisc() async throws {
        try? await stop()
        try await eraseDisc()
    }
}

/// Replaces the disc title inside a raw title that may also hold groups.
func replaceTitle(in raw: String, with newName: String, marker: String, delimiter: String) -> String {
    guard raw.contains(delimiter) else { return newName }
    if raw.hasPrefix(marker), let end = raw.range(of: delimiter) {
        // Replace or delete the old title
        let rest = raw[end.upperBound...]
        return newName.isEmpty ? String(rest) : marker + newName + delimiter + rest
    }
    return newName.isEmpty ? raw : marker + newName + delimiter + raw // Add the new title
}
