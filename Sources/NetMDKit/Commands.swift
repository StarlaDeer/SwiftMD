// SwiftMD - port of netmd-js src/netmd-commands.ts (listing and status)
// Original: Copyright (C) Stefano Brilli, Asivery (https://github.com/cybercase/netmd-js)
// Licensed under the GNU General Public License v2.0.

import Foundation

public struct Track: Sendable, Hashable, Identifiable {
    public var index: Int
    public var title: String?
    public var fullWidthTitle: String?
    /// Length in frames (512 per second).
    public var duration: Int
    public var channel: Int
    public var encoding: Int
    public var protected: Int

    public var id: Int { index }
    public var isMono: Bool { channel == Channels.mono.rawValue }
    public var isProtected: Bool { protected == TrackFlag.protected.rawValue }

    public var encodingName: String {
        switch Encoding(rawValue: encoding) {
        case .sp: return isMono ? "SP Mono" : "SP"
        case .lp2: return "LP2"
        case .lp4: return "LP4"
        case nil: return String(format: "0x%02x", encoding)
        }
    }
}

public struct Group: Sendable, Hashable, Identifiable {
    public var index: Int
    public var title: String?
    public var fullWidthTitle: String?
    public var tracks: [Track]

    public var id: Int { index }
    /// The group of tracks that don't belong to any named group.
    public var isUngrouped: Bool { title == nil }
}

public struct Disc: Sendable, Hashable {
    public var title: String
    public var fullWidthTitle: String
    public var writable: Bool
    public var writeProtected: Bool
    /// Capacity in frames (512 per second).
    public var used: Int
    public var left: Int
    public var total: Int
    public var trackCount: Int
    public var groups: [Group]

    public var tracks: [Track] { groups.flatMap(\.tracks) }
}

public enum OperatingState: String, Sendable {
    case ready, playing, paused, fastForward, rewind, readingTOC, noDisc, discBlank, readyForTransfer, unknown

    init(code: Int) {
        switch code {
        case 50687: self = .ready
        case 50037: self = .playing
        case 50045: self = .paused
        case 49983: self = .fastForward
        case 49999: self = .rewind
        case 65315: self = .readingTOC
        case 65296: self = .noDisc
        case 65535: self = .discBlank
        case 65319: self = .readyForTransfer
        default: self = .unknown
        }
    }
}

public struct DeviceStatus: Sendable, Hashable {
    public struct Time: Sendable, Hashable {
        public var minute: Int
        public var second: Int
        public var frame: Int
    }

    public var discPresent: Bool
    public var time: Time?
    public var track: Int?
    public var state: OperatingState
    /// The raw operating status, for states SwiftMD doesn't name (an MZ-N910 showing
    /// ERROR or TOC Edit reports 0xff11).
    public var operatingStatusCode: Int = 0
}

extension NetMDInterface {
    public func getDeviceStatus() async throws -> DeviceStatus {
        let status = try await getStatus()
        let playbackStatus2 = try await getPlaybackStatus2()
        let operatingStatus = playbackStatus2.count > 5 ? (Int(playbackStatus2[4]) << 8) | Int(playbackStatus2[5]) : 0
        let position = try await getPosition()

        let discPresent = status.count > 4 && status[4] != 0x80
        var state = OperatingState(code: operatingStatus)
        if state == .playing && !discPresent {
            state = .ready
        }

        return DeviceStatus(
            discPresent: discPresent && state != .readingTOC && state != .noDisc,
            time: position.map { .init(minute: $0[2] + $0[1] * 60, second: $0[3], frame: $0[4]) },
            track: position?[0],
            state: state,
            operatingStatusCode: operatingStatus
        )
    }

    public func listContent() async throws -> Disc {
        let flags = try await getDiscFlags()
        let title = try await getDiscTitle()
        let fullWidthTitle = try await getDiscTitle(wchar: true)
        let capacity = try await getDiscCapacity()
        let trackCount = try await getTrackCount()

        var framesUsed = timeToFrames(capacity[0])
        var framesTotal = timeToFrames(capacity[1])
        var framesLeft = timeToFrames(capacity[2])
        // Some devices report the time remaining of the currently selected recording mode. (Sharps)
        while framesTotal > framesPerSecond * 60 * 82 {
            framesUsed /= 2
            framesTotal /= 2
            framesLeft /= 2
        }

        var disc = Disc(
            title: title,
            fullWidthTitle: fullWidthTitle,
            writable: flags & DiscFlag.writable != 0,
            writeProtected: flags & DiscFlag.writeProtected != 0,
            used: framesUsed,
            left: framesLeft,
            total: framesTotal,
            trackCount: trackCount,
            groups: []
        )

        for (groupIndex, rawGroup) in try await getTrackGroupList().enumerated() {
            var group = Group(index: groupIndex, title: rawGroup.title, fullWidthTitle: rawGroup.fullWidthTitle, tracks: [])
            for track in rawGroup.tracks {
                let (codec, channel) = try await getTrackEncoding(track)
                let duration = timeToFrames(try await getTrackLength(track))
                let flags = try await getTrackFlags(track)
                let title = try await getTrackTitle(track)
                let fullWidthTitle = try await getTrackTitle(track, wchar: true)
                group.tracks.append(Track(
                    index: track,
                    title: title,
                    fullWidthTitle: fullWidthTitle,
                    duration: duration,
                    channel: channel,
                    encoding: codec,
                    protected: flags
                ))
            }
            disc.groups.append(group)
        }
        return disc
    }
}
