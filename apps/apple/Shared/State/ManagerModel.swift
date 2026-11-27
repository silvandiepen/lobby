// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Observation

/// What a manager device can do for the household: let new devices in, remove devices, and
/// keep the list of viewers. Every call here is refused by the server for a viewer device.
@MainActor
@Observable
final class ManagerModel {
    /// One device in the list, ready to draw.
    struct DeviceRow: Hashable, Identifiable {
        var device: Device
        var isThisDevice: Bool
        /// "iPhone · Viewer", "Mac · Manager".
        var caption: String
        /// How it is doing with what a manager put on it. nil on a server that does not know.
        var progress: DeviceProgress?
        /// "Seen 2 hours ago", "41 GB free of 128 GB".
        var facts: [String] = []
        var id: String { device.id }
    }

    private(set) var waiting: [PendingPairingRequest] = []
    /// Let in at home by a household admin, waiting for a server admin's yes.
    private(set) var awaitingAdmin: [PendingPairingRequest] = []
    private(set) var devices: [DeviceRow] = []
    private(set) var status: ServerStatus?
    /// The server was set up for access from outside.
    private(set) var offersOutside = false
    private(set) var isLoading = false
    /// What went wrong with the last action, in the server's words.
    var problem: String?
    /// "Approved "Living room Apple TV" as a viewer."
    private(set) var lastApproval: String?

    var code = ""
    var role: DeviceAccess = .viewer

    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    /// Six digits, with or without spaces between them.
    var canApprove: Bool { Self.digits(code).count == 6 }

    static func digits(_ text: String) -> String {
        text.filter(\.isNumber)
    }

    /// Fetches who is waiting, the devices and the server's status.
    func refresh() async {
        guard app.isManager else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await look()
            // A household admin: the server and its switch are a server admin's, and their
            // household's devices come in through their own window too.
            if !app.isOwnerManager {
                status = nil
                offersOutside = true
                return
            }
            status = try await app.asManager { try await $0.status() }
            do {
                offersOutside = try await app.asManager { try await $0.outsideStatus() }.configured
            } catch LobbyError.notFound {
                // A server from before access from outside.
                offersOutside = false
            }
        } catch {
            await report(error)
        }
    }

    /// The manager typed the code a new device shows.
    func approve() async {
        guard app.isManager, canApprove else { return }
        problem = nil
        do {
            let digits = Self.digits(code), role = role
            let approval = try await app.asManager { try await $0.approvePairing(code: digits, access: role) }
            lastApproval = Self.approved(approval)
            code = ""
            await refresh()
        } catch {
            lastApproval = nil
            await report(error)
        }
    }

    /// The manager picked a device from those waiting.
    func approve(_ request: PendingPairingRequest, as role: DeviceAccess?) async {
        guard app.isManager else { return }
        problem = nil
        do {
            let approval = try await app.asManager { try await $0.approvePairing(requestID: request.id, access: role) }
            lastApproval = Self.approved(approval)
            await refresh()
        } catch {
            lastApproval = nil
            await report(error)
        }
    }

    /// Keeps the page current while it is open, so a new device appears by itself.
    /// A failed look is left for the next one; Refresh reports what is wrong.
    func watch() async {
        await refresh()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard app.isManager else { return }
            do {
                try await look()
            } catch let error as LobbyError where error.requiresPairing {
                await report(error)
                return
            } catch {
                continue
            }
        }
    }

    /// "Approved “Living room” as a viewer.", or that the server owner is still to say yes.
    static func approved(_ approval: PairingApproval) -> String {
        if approval.awaitsAdmin == true {
            return "“\(approval.deviceName)” waits for the server owner to approve it too."
        }
        return "Approved “\(approval.deviceName)” as \(article(approval.access ?? (approval.role == .manager ? .admin : .viewer)))."
    }

    /// A server admin turns away a device a household admin let in.
    func refuse(_ request: PendingPairingRequest) async {
        problem = nil
        do {
            try await app.asManager { try await $0.refusePairing(id: request.id) }
            await refresh()
        } catch {
            await report(error)
        }
    }

    /// Makes a device of this household a viewer, a household admin, or (a server admin only) a server admin.
    func setAccess(_ access: DeviceAccess, of device: Device) async {
        problem = nil
        do {
            _ = try await app.asManager { try await $0.setAccess(access, deviceID: device.id) }
            await refresh()
        } catch {
            await report(error)
        }
    }

    /// What a manager may make of a device: up to their own.
    var grantable: [DeviceAccess] {
        app.isOwnerManager ? [.viewer, .householdAdmin, .admin] : [.viewer, .householdAdmin]
    }

    private func look() async throws {
        waiting = try await app.asManager { try await $0.pendingPairingRequests() }
        awaitingAdmin = app.isGuest ? [] : ((try? await app.asManager { try await $0.awaitingAdmin() }) ?? [])
        let list = try await app.asManager { try await $0.devices() }
        let lists: [DeviceWantedSummary]
        do {
            lists = try await app.asManager { try await $0.devicesWanted() }
        } catch LobbyError.notFound {
            // A server from before managers could put downloads on a device.
            lists = []
        }
        let now = Date()
        devices = list.devices
            .filter { $0.revokedAt == nil }
            .sorted { $0.createdAt < $1.createdAt }
            .map { device in
                let summary = lists.first { $0.id == device.id }
                return DeviceRow(
                    device: device, isThisDevice: device.id == list.currentDeviceId,
                    caption: "\(Self.name(device.platform)) · \(Self.name(device.level))",
                    // A command line keeps no films.
                    progress: device.platform == .cli ? nil : summary.map(DeviceProgress.init),
                    facts: summary.map { summary in
                        [DeviceProgress.seen(summary.lastSeenAt, now: now), DeviceProgress.space(summary.storage)].compactMap { $0 }
                    } ?? [])
            }
    }

    /// "482 913"
    static func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }

    /// Removes a device: its next request is refused, and it has to pair again.
    func remove(_ row: DeviceRow) async {
        _ = await remove(deviceID: row.device.id)
    }

    /// - Returns: whether it was removed. When not, `problem` says why.
    func remove(deviceID: String) async -> Bool {
        guard app.isManager else { return false }
        problem = nil
        do {
            try await app.asManager { try await $0.revokeDevice(id: deviceID) }
            await refresh()
            return true
        } catch {
            await report(error)
            return false
        }
    }

    /// The problem, for the page that shows it: no other page shows it again.
    func takeProblem() -> String? {
        defer { problem = nil }
        return problem
    }

    func addViewer(name: String, color: String) async {
        problem = nil
        do {
            try await app.addProfile(name: name, color: color)
        } catch {
            await report(error)
        }
    }

    /// Deletes a viewer and their progress on the server.
    func removeViewer(_ profile: Profile) async {
        problem = nil
        do {
            try await app.removeProfile(profile)
        } catch {
            await report(error)
        }
    }

    private func report(_ error: any Error) async {
        problem = await app.managerProblem(error)
    }

    static func symbol(_ platform: DevicePlatform) -> String {
        switch platform {
        case .ios: AppSymbol.phone
        case .ipados: AppSymbol.pad
        case .macos: AppSymbol.mac
        case .tvos: AppSymbol.television
        case .cli, .unknown: AppSymbol.commandLine
        }
    }

    static func name(_ platform: DevicePlatform) -> String {
        switch platform {
        case .ios: "iPhone"
        case .ipados: "iPad"
        case .macos: "Mac"
        case .tvos: "Apple TV"
        case .cli: "Command line"
        case .unknown(let raw): raw
        }
    }

    static func name(_ role: DeviceRole) -> String {
        switch role {
        case .manager: "Server Admin"
        case .viewer: "Viewer"
        case .unknown(let raw): raw.capitalized
        }
    }

    static func name(_ access: DeviceAccess) -> String {
        switch access {
        case .admin: "Server Admin"
        case .householdAdmin: "Household Admin"
        case .viewer: "Viewer"
        case .unknown(let raw): raw.capitalized
        }
    }

    /// The button that lets a waiting device in: "Let In as Viewer", "Let In as Household Admin".
    static func letInLabel(_ access: DeviceAccess) -> String {
        "Let In as \(name(access))"
    }

    /// "a viewer", "a household admin".
    static func article(_ access: DeviceAccess) -> String {
        switch access {
        case .admin: "a server admin"
        case .householdAdmin: "a household admin"
        default: "a viewer"
        }
    }

    /// "3,070 files · 12 waiting to be read · 3 unreadable", for the server section.
    static func summary(_ status: ServerStatus) -> [String] {
        // Repackaged: the same picture in a container Apple opens. Converted: the server makes
        // a new picture first (old AVI, for one), which takes it longer.
        var lines = [
            "\(status.items.movies) films, \(status.items.shows) series, \(status.items.episodes) episodes",
            "\(status.playability.direct) files play as they are, \(status.playability.remux) are repackaged first, \(status.playability.transcode) are converted first",
        ]
        if status.playability.unsupported > 0 {
            lines.append("\(status.playability.unsupported) files cannot be played")
        }
        if status.scanning || status.files.waiting > 0 {
            lines.append("Reading the library: \(status.files.waiting) files to go")
        }
        if status.files.failed > 0 {
            lines.append("\(status.files.failed) files could not be read")
        }
        let unplugged = status.sources.filter { !$0.available }.map(\.name)
        if !unplugged.isEmpty {
            lines.append("Not connected: \(unplugged.joined(separator: ", "))")
        }
        return lines
    }
}
