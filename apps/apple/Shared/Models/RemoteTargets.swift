// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// The household's other devices as the screens show them: in which order, under which name,
/// with which picture and what they do. Pure, so that it can be tested apart from the channel.
enum RemoteTargets {
    /// What can be played on: every device that is not this one. Those that are open come first,
    /// then televisions, Macs and the rest, each by name.
    static func ordered(_ devices: [ShownDevice]) -> [ShownDevice] {
        devices.filter { !$0.isSelf }.sorted { a, b in
            if a.online != b.online { return a.online }
            if rank(a.platform) != rank(b.platform) { return rank(a.platform) < rank(b.platform) }
            let names = a.name.localizedStandardCompare(b.name)
            return names == .orderedSame ? a.id < b.id : names == .orderedAscending
        }
    }

    private static func rank(_ platform: DevicePlatform) -> Int {
        switch platform {
        case .tvos: 0
        case .macos: 1
        case .ipados: 2
        case .ios: 3
        default: 4
        }
    }

    /// The name to show for each device. Two with the same name (every Apple TV calls itself
    /// "Apple TV" until somebody renames it) get a number, in a fixed order, so that one is not
    /// taken for the other.
    static func names(of devices: [ShownDevice]) -> [String: String] {
        var result: [String: String] = [:]
        let groups = Dictionary(grouping: devices) { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        for (_, same) in groups {
            if same.count == 1, let only = same.first {
                result[only.id] = only.name
                continue
            }
            for (index, device) in same.sorted(by: { $0.id < $1.id }).enumerated() {
                result[device.id] = "\(device.name) \(index + 1)"
            }
        }
        return result
    }

    /// The SF Symbol for a kind of device.
    static func symbol(_ platform: DevicePlatform) -> String {
        switch platform {
        case .tvos: "appletv"
        case .macos: "desktopcomputer"
        case .ipados: "ipad"
        case .ios: "iphone"
        default: "display"
        }
    }

    /// Lobby Server turns it on and opens Lobby before it plays: an Apple TV that is asleep, or
    /// where Lobby is not in front, and that the server can wake.
    static func willWake(_ device: ShownDevice) -> Bool {
        device.wakeable && device.platform == .tvos && !(device.online && device.canPlay)
    }

    // MARK: Play On

    /// The sheet's two lists: the household's Apple TVs with Lobby first (open, then those that will
    /// wake, then the rest), and every other device under them, where AirPlay is too.
    static func playOnSections(_ devices: [ShownDevice]) -> (televisions: [ShownDevice], others: [ShownDevice]) {
        let all = ordered(devices)
        let televisions = all.filter { $0.platform == .tvos }.enumerated().sorted { a, b in
            let ranks = (tvRank(a.element), tvRank(b.element))
            return ranks.0 == ranks.1 ? a.offset < b.offset : ranks.0 < ranks.1
        }.map(\.element)
        return (televisions, all.filter { $0.platform != .tvos })
    }

    private static func tvRank(_ device: ShownDevice) -> Int {
        if device.online && device.canPlay { return 0 }
        if willWake(device) { return 1 }
        return device.online ? 2 : 3
    }

    /// What a TV in the sheet says: "Lobby open", "Will wake", what plays, or that it sleeps and
    /// cannot be woken. Other devices say what `state(of:)` says.
    static func playOnState(of device: ShownDevice, title: (String) -> String?) -> String {
        guard device.platform == .tvos else { return state(of: device, title: title) }
        if willWake(device), device.player == nil { return "Will wake" }
        guard device.online else { return "Asleep — can’t be woken (link it in Apple TVs)" }
        if device.player == nil, device.canPlay { return "Lobby open" }
        return state(of: device, title: title)
    }

    /// What the sheet says while a TV wakes for a play.
    static func progress(_ step: RemoteModel.WakeStep, device name: String) -> String {
        switch step {
        case .waking: "Waking \(name)…"
        case .opening, .profileHint, .notOpen: "Opening Lobby…"
        case .starting: "Starting…"
        }
    }

    /// The hint under it, when Lobby is slow to come up on the TV.
    static func hint(_ step: RemoteModel.WakeStep, device name: String) -> String? {
        switch step {
        case .profileHint: "Choose a profile on the TV if it asks"
        case .notOpen: "Lobby has not opened on \(name) yet. Choose a profile there if it asks; the film starts once Lobby is open."
        default: nil
        }
    }

    // MARK: Kids mode (docs/decisions.md, "Kids mode plays on the TV")

    /// Where the kids screens can play: Apple TVs that are open and ready, or that Lobby Server
    /// will wake for this child (only when the household lets kids turn on the TV). The server
    /// shows a child nothing it may not play on; this leaves out what cannot play this moment.
    static func forKids(_ devices: [ShownDevice], atHome: Bool) -> [ShownDevice] {
        ordered(devices).filter { device in
            guard device.platform == .tvos else { return false }
            return (device.online && device.canPlay) || (atHome && willWake(device))
        }
    }

    /// The TV that plays the child's own film now, which the child may pause and stop. The server
    /// shows a child nothing else as controllable.
    static func kidsPlaying(_ devices: [ShownDevice]) -> ShownDevice? {
        devices.first { device in
            guard !device.isSelf, device.online, device.controllable, let state = device.player?.state else { return false }
            return state.status != .ended && state.status != .error
        }
    }

    /// What it is doing, in a few words: "Playing Wild Isles", "Paused", "Idle", "Lobby is not open",
    /// "Will wake". A title this device may not know is never named.
    static func state(of device: ShownDevice, title: (String) -> String?) -> String {
        if willWake(device), device.player == nil { return "Will wake" }
        guard device.online else { return "Lobby is not open" }
        guard let player = device.player else { return device.canPlay ? "Idle" : "Busy" }
        let doing = words(for: player.status)
        guard let state = player.state, let itemID = state.itemId, let name = title(itemID) else { return doing }
        return "\(doing) \(name)"
    }

    static func words(for status: RemotePlayerStatus) -> String {
        switch status {
        case .paused: "Paused"
        case .loading, .buffering: "Starting"
        case .ended: "Finished"
        case .error: "Stopped"
        default: "Playing"
        }
    }

    /// The devices that play something this one may see or control, the one to show first first.
    static func nowPlaying(_ devices: [ShownDevice]) -> [ShownDevice] {
        devices.filter { device in
            guard !device.isSelf, device.online, let player = device.player else { return false }
            switch player.status {
            case .ended, .error: return false
            default: return true
            }
        }
        .sorted { a, b in
            // What can be controlled before what can only be seen, and what plays before what waits.
            if a.controllable != b.controllable { return a.controllable }
            let aPlays = a.player?.status == .playing, bPlays = b.player?.status == .playing
            if aPlays != bPlays { return aPlays }
            return a.id < b.id
        }
    }
}

/// How a command that was sent went, in words for the person who sent it.
enum RemoteOutcome: Hashable, Sendable {
    case done
    /// The device or the server said no, for this reason.
    case failed(code: String?)
    /// Lobby is not open there.
    case offline
    case expired
    /// A newer one of the same kind came.
    case superseded
    /// The server could not be reached.
    case unreachable
    /// The server could not wake it, or Lobby did not open there in time. The reason is the
    /// server's (`wake_not_found`, …) or `did_not_open`.
    case notWoken(reason: String?)
    /// The person took it back before it started.
    case cancelled

    var succeeded: Bool { self == .done || self == .superseded }

    /// What to tell a child, in a few plain words, without AirPlay or settings. nil when it went.
    func kidsWords(device name: String) -> String? {
        switch self {
        case .done, .superseded: nil
        case .failed(let code) where code == "title_not_allowed" || code == "not_allowed":
            "\(name) cannot play this one."
        case .failed(let code) where code == "nothing_playing":
            "Nothing plays on \(name) any more."
        case .cancelled: nil
        case .offline, .expired, .notWoken:
            "\(name) did not answer. Ask a grown-up to open Lobby there."
        default:
            "That did not work on \(name). Ask a grown-up for help."
        }
    }

    /// What to tell the person. nil when nothing needs saying.
    func words(device name: String) -> String? {
        switch self {
        case .done, .superseded, .cancelled: nil
        case .offline: "Lobby is not open on \(name). Open it there, or use AirPlay."
        case .expired: "\(name) did not answer. Is Lobby still open there?"
        case .unreachable: "Lobby Server cannot be reached."
        case .notWoken(let reason):
            switch reason {
            case "did_not_open": "\(name) woke, but Lobby did not open there in time. If it asks who is watching, choose a profile there and try again, or use AirPlay."
            case "wake_not_found": "\(name) was not found on the network. Is it plugged in? Use AirPlay instead."
            case "wake_not_paired": "\(name) no longer accepts Lobby Server. A manager connects it again under Server Settings → Apple TVs. Use AirPlay meanwhile."
            case "wake_off": "Waking Apple TVs is turned off. Use AirPlay instead."
            case "home_only": "\(name) can only be woken from home. Use AirPlay at home."
            case "rate_limited": "\(name) was asked to wake a lot just now. Wait a moment, or use AirPlay."
            case "control_off": "Playing on other devices is turned off for this device."
            default: "\(name) could not be woken. Use AirPlay instead."
            }
        case .failed(let code):
            switch code {
            case "title_not_allowed", "not_allowed": "This cannot be played on \(name) for that viewer."
            case "not_found": "\(name) does not have this, or that viewer."
            case "cannot_play": "\(name) cannot play anything right now. Open Lobby on it and try again."
            case "nothing_playing": "Nothing plays on \(name) any more."
            case "unsupported": "\(name) cannot do that."
            case "busy": "\(name) is busy handing something over. Try again in a moment."
            case "control_off": "Playing on other devices is turned off for this device."
            case "declined": "\(name) said no."
            case "device_offline": "Lobby is not open on \(name). Open it there, or use AirPlay."
            default: "That did not work on \(name)."
            }
        }
    }
}
