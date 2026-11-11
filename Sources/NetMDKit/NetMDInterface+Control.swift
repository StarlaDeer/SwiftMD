// SwiftMD - port of netmd-js src/netmd-interface.ts (editing and playback commands)
// Original: Copyright (C) Stefano Brilli, Asivery (https://github.com/cybercase/netmd-js)
// Licensed under the GNU General Public License v2.0.

import Foundation

enum PlayAction: Int {
    case play = 0x75
    case pause = 0x7d
    case fastForward = 0x39
    case rewind = 0x49
}

enum TrackChange: Int {
    case previous = 0x0002
    case next = 0x8001
    case restart = 0x0001
}

extension NetMDInterface {
    // MARK: - Playback

    func play(_ action: PlayAction) async throws {
        let reply = try await sendQuery(formatQuery("18c3 ff %b 000000", .init(action.rawValue)))
        _ = try scanQuery(reply, "18c3 00 %b 000000")
    }

    public func play() async throws { try await play(.play) }
    public func pause() async throws { try await play(.pause) }
    public func fastForward() async throws { try await play(.fastForward) }
    public func rewind() async throws { try await play(.rewind) }

    public func stop() async throws {
        do {
            let reply = try await sendQuery(formatQuery("18c5 ff 00000000"))
            _ = try scanQuery(reply, "18c5 00 00000000")
        } catch {
            // Ignore (fix for LAM-1)
        }
    }

    @discardableResult
    public func gotoTrack(_ track: Int) async throws -> Int {
        let reply = try await sendQuery(formatQuery("1850 ff010000 0000 %w", .init(track)))
        return try scanQuery(reply, "1850 00010000 0000 %w")[0].int
    }

    /// Seeks within a track. Port of netmd-js `gotoTime`.
    @discardableResult
    public func gotoTime(_ track: Int, hour: Int = 0, minute: Int = 0, second: Int = 0, frame: Int = 0) async throws -> [Int] {
        let reply = try await sendQuery(formatQuery("1850 ff000000 0000 %w %B%B%B%B",
                                                    .init(track), .init(hour), .init(minute), .init(second), .init(frame)))
        return try scanQuery(reply, "1850 00000000 %?%? %w %B%B%B%B").map(\.int)
    }

    func changeTrack(_ direction: TrackChange) async throws {
        let reply = try await sendQuery(formatQuery("1850 ff10 00000000 %w", .init(direction.rawValue)))
        _ = try scanQuery(reply, "1850 0010 00000000 %?%?")
    }

    public func nextTrack() async throws { try await changeTrack(.next) }
    public func previousTrack() async throws { try await changeTrack(.previous) }
    public func restartTrack() async throws { try await changeTrack(.restart) }

    public func ejectDisc() async throws {
        _ = try await sendQuery(formatQuery("18c1 ff 6000"))
    }

    // MARK: - Editing (these change the disc)

    public func eraseDisc() async throws {
        let reply = try await sendQuery(formatQuery("1840 ff 0000"))
        _ = try scanQuery(reply, "1840 00 0000")
    }

    public func eraseTrack(_ track: Int) async throws {
        _ = try await sendQuery(formatQuery("1840 ff01 00 201001 %w", .init(track)))
    }

    public func moveTrack(_ source: Int, to dest: Int) async throws {
        _ = try await sendQuery(formatQuery("1843 ff00 00 201001 %w 201001 %w", .init(source), .init(dest)))
    }

    /// Writes the raw disc title, which also holds the group list ("0;Title//1-3;Group//").
    public func setDiscTitle(_ title: String, wchar: Bool = false) async throws {
        let currentTitle = try await rawDiscTitle(wchar: wchar)
        if currentTitle == title { return } // Setting the same title causes problems with the LAM.

        let sanitized = wchar ? sanitizeFullWidthTitle(title) : sanitizeHalfWidthTitle(title)
        // netmd-js measures the title before sanitizing it; measure what is actually sent.
        let oldLength = encodeToSJIS(currentTitle).count
        let newBytes = encodeToSJIS(sanitized)
        let isSharp = vendorID == 0x04dd

        if isSharp {
            // Sharp disc rename (Issue #67 of webminidisc)
            await changeDescriptorState(.audioUTOC1TD, .openWrite)
        } else {
            await changeDescriptorState(.discTitleTD, .close)
            await changeDescriptorState(.discTitleTD, .openWrite)
        }
        let reply = try await sendQuery(formatQuery(
            "1807 02201801 00%b 3000 0a00 5000 %w 0000 %w %*",
            wchar ? 1 : 0, .init(newBytes.count), .init(oldLength), .bytes(newBytes)
        ))
        _ = try scanQuery(reply, "1807 02201801 00%? 3000 0a00 5000 %?%? 0000 %?%?")
        if isSharp {
            await changeDescriptorState(.audioUTOC1TD, .close)
        } else {
            await changeDescriptorState(.discTitleTD, .close)
            await changeDescriptorState(.discTitleTD, .openRead)
            await changeDescriptorState(.discTitleTD, .close)
        }
    }

    public func setTrackTitle(_ track: Int, _ title: String, wchar: Bool = false) async throws {
        let sanitized = wchar ? sanitizeFullWidthTitle(title) : sanitizeHalfWidthTitle(title)
        let newBytes = encodeToSJIS(sanitized)
        let oldLength: Int
        do {
            let currentTitle = try await getTrackTitle(track, wchar: wchar)
            if currentTitle == sanitized { return }
            oldLength = encodeToSJIS(currentTitle).count
        } catch NetMDError.rejected {
            oldLength = 0
        }

        let descriptor: Descriptor = wchar ? .audioUTOC4TD : .audioUTOC1TD
        await changeDescriptorState(descriptor, .openWrite)
        let reply = try await sendQuery(formatQuery(
            "1807 022018%b %w 3000 0a00 5000 %w 0000 %w %*",
            wchar ? 3 : 2, .init(track), .init(newBytes.count), .init(oldLength), .bytes(newBytes)
        ))
        _ = try scanQuery(reply, "1807 022018%? %?%? 3000 0a00 5000 %?%? 0000 %?%?")
        await changeDescriptorState(descriptor, .close)
    }
}
