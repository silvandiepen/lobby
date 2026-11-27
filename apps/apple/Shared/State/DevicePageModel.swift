// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Observation

/// One device's page for a manager: what was put on it, how far it is, and what is in the way.
@MainActor
@Observable
final class DevicePageModel {
    let deviceID: String
    private(set) var detail: DeviceWantedDetail?
    /// The device as the server lists it, with the kids viewer it is bound to.
    private(set) var device: Device?
    private(set) var isBinding = false
    /// The server was set up for access from outside.
    private(set) var offersOutside = false
    private(set) var isAllowing = false
    private(set) var rows: [WantedRow] = []
    /// What the person on the device downloaded themselves.
    private(set) var own: [OwnRow] = []
    /// The device was removed while its page was open.
    private(set) var isGone = false
    var problem: String?

    struct OwnRow: Hashable, Identifiable {
        var id: String
        var title: String
        var caption: String
    }

    private let app: AppModel

    init(app: AppModel, deviceID: String) {
        self.app = app
        self.deviceID = deviceID
    }

    func refresh() async {
        do {
            apply(try await fetch())
            try await fetchDevice()
        } catch LobbyError.notFound {
            isGone = true
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    /// Keeps the page current while it is open.
    func watch() async {
        await refresh()
        while !Task.isCancelled, !isGone {
            do { try await app.environment.sleep(.seconds(5)) } catch { return }
            // A failed look is left for the next one: what is on screen stays.
            do {
                apply(try await fetch())
            } catch LobbyError.notFound {
                isGone = true
            } catch let error as LobbyError where error.requiresPairing {
                problem = await app.managerProblem(error)
                return
            } catch {
                continue
            }
        }
    }

    func remove(_ row: WantedRow) async {
        problem = nil
        do {
            let deviceID = deviceID
            try await app.asManager { try await $0.removeWanted(deviceID: deviceID, wantedID: row.id) }
            // Off the page at once; the device removes its copies the next time it looks.
            rows.removeAll { $0.id == row.id }
            await refresh()
        } catch LobbyError.notFound {
            // Another manager was quicker.
            await refresh()
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    /// Who this device can be for: the household's kids viewers.
    var kidsViewers: [Profile] { app.profiles.filter { $0.kids != nil } }

    /// A manager's device is not for a child: bound to one, it could not be freed from itself.
    var canBeBound: Bool { device.map { $0.role != .manager && ([.ios, .ipados, .macos].contains($0.platform)) } ?? false }

    /// Binds the device to a kids viewer, or (nil) frees it.
    func bind(to profileID: String?) async {
        guard !isBinding, device?.kidsProfileId != profileID else { return }
        isBinding = true
        problem = nil
        defer { isBinding = false }
        do {
            let deviceID = deviceID
            let changed = try await app.asManager { try await $0.bindDevice(id: deviceID, toKidsProfile: profileID) }
            guard changed.saysKidsProfile, changed.kidsProfileId == profileID else { throw KidsUnsupported() }
            device = changed
        } catch {
            // An older server has no such route at all.
            if case LobbyError.notFound = error, !isGone, device?.saysKidsProfile == false {
                problem = KidsUnsupported().localizedDescription
            } else {
                problem = await app.managerProblem(error)
            }
        }
    }

    /// What the device may do in its household: up to the manager's own level.
    var grantable: [DeviceAccess] {
        app.isOwnerManager && !app.isGuest ? [.viewer, .householdAdmin, .admin] : [.viewer, .householdAdmin]
    }

    /// Whether this manager may change what it is: not their own, not one above them.
    var canChangeAccess: Bool {
        guard let device, device.id != app.device?.id, device.kidsProfileId == nil else { return false }
        return app.isOwnerManager || device.level != .admin
    }

    func setAccess(_ access: DeviceAccess) async {
        problem = nil
        do {
            let deviceID = deviceID
            device = try await app.asManager { try await $0.setAccess(access, deviceID: deviceID) }
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    /// Lets the device in from outside, or no longer: its connections then end at once.
    func allowOutside(_ allowed: Bool) async {
        guard !isAllowing else { return }
        isAllowing = true
        problem = nil
        defer { isAllowing = false }
        do {
            let deviceID = deviceID
            device = try await app.asManager { try await $0.setAllowOutside(allowed, deviceID: deviceID) }
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    private func fetchDevice() async throws {
        if !app.isOwnerManager {
            // A household admin's devices come in from outside; the switch is a server admin's.
            offersOutside = true
        } else {
            do {
                offersOutside = try await app.asManager { try await $0.outsideStatus() }.configured
            } catch LobbyError.notFound {
                offersOutside = false
            }
        }
        let list = try await app.asManager { try await $0.devices() }
        guard !isBinding else { return }
        device = list.devices.first { $0.id == deviceID }
    }

    private func fetch() async throws -> DeviceWantedDetail {
        let deviceID = deviceID
        return try await app.asManager { try await $0.deviceWanted(deviceID: deviceID) }
    }

    private func apply(_ detail: DeviceWantedDetail) {
        self.detail = detail
        rows = WantedRow.rows(of: detail, catalogue: app.wholeCatalogue, profiles: app.profiles)
        own = detail.other.filter(\.own).map { other in
            let title: String = other.itemId.map { id in
                let show = app.wholeCatalogue.item(id).flatMap { app.wholeCatalogue.show(of: $0) }?.title
                return [show, WantedFileRow.title(of: id, in: app.wholeCatalogue)].compactMap { $0 }.joined(separator: " · ")
            } ?? "No longer in the library"
            let done = other.state == .downloaded
            return OwnRow(
                id: other.id, title: title,
                caption: "\(done ? "Downloaded" : "On its way") · \(MediaFormat.size(bytes: done ? other.bytesDone : other.bytesTotal ?? other.bytesDone))")
        }
    }
}

/// Send to Device: what of a film or series, and to which of the household's devices.
@MainActor
@Observable
final class SendToDeviceModel {
    /// What can be sent, in the order the picker lists it.
    enum What: Hashable, Sendable {
        case item(String)
        case nextEpisodes
    }

    struct Choice: Hashable, Identifiable {
        var what: What
        var title: String
        var id: What { what }
    }

    /// One device, and whether it already has this on its list.
    struct Target: Hashable, Identifiable {
        var device: DeviceWantedSummary
        var entry: WantedEntry?
        var id: String { device.id }
    }

    let item: Item
    /// Only this device, when the sheet was opened from a device's page.
    let onlyDeviceID: String?
    let choices: [Choice]
    var what: What
    var profileID: String?
    var count = WantedRequest.defaultCount
    private(set) var devices: [DeviceWantedSummary] = []
    private(set) var entries: [String: [WantedEntry]] = [:]
    private(set) var hasLoaded = false
    /// The device a call is under way for.
    private(set) var busy: String?
    var problem: String?

    private let app: AppModel

    init(app: AppModel, item: Item, deviceID: String? = nil) {
        self.app = app
        self.item = item
        onlyDeviceID = deviceID
        choices = Self.choices(for: item, in: app.wholeCatalogue)
        what = choices.first?.what ?? .item(item.id)
        profileID = app.activeProfile?.id ?? app.profiles.first?.id
    }

    /// The series the rule can be made for, when the item is one or part of one.
    private var show: Item? { app.wholeCatalogue.show(of: item) }

    static func choices(for item: Item, in catalogue: Catalogue) -> [Choice] {
        let show = catalogue.show(of: item)
        switch item.kind {
        case .show:
            return [
                Choice(what: .nextEpisodes, title: "The next episodes"),
                Choice(what: .item(item.id), title: "The whole series"),
            ] + EpisodeOrder.seasons(ofShow: item.id, in: catalogue).map {
                Choice(what: .item($0.id), title: MediaFormat.seasonName($0.seasonNumber, fallback: $0.title))
            }
        case .season:
            return [Choice(what: .item(item.id), title: MediaFormat.seasonName(item.seasonNumber, fallback: item.title))]
                + (show == nil ? [] : [Choice(what: .nextEpisodes, title: "The next episodes")])
                + (show.map { [Choice(what: .item($0.id), title: "The whole series")] } ?? [])
        case .episode:
            return [Choice(what: .item(item.id), title: WantedFileRow.title(of: item.id, in: catalogue))]
        default:
            return [Choice(what: .item(item.id), title: item.title)]
        }
    }

    var viewers: [Profile] { app.profiles }

    /// nil while a viewer still has to be chosen.
    var request: WantedRequest? {
        switch what {
        case .item(let id): return .item(id)
        case .nextEpisodes:
            guard let show, let profileID else { return nil }
            return .nextEpisodes(showID: show.id, profileID: profileID, count: count)
        }
    }

    var targets: [Target] {
        devices
            .filter { onlyDeviceID == nil || $0.id == onlyDeviceID }
            .map { device in
                Target(device: device, entry: request.flatMap { request in entries[device.id]?.first { request.matches($0) } })
            }
    }

    /// The rule is on the device with another count: sending sets the new one.
    func changesCount(_ target: Target) -> Bool {
        guard let entry = target.entry, case .nextEpisodes(_, _, let count)? = request else { return false }
        return entry.count != count
    }

    func load() async {
        do {
            // A command line keeps no films.
            let listed = try await app.asManager { try await $0.devicesWanted() }.filter { $0.platform != .cli }
            var found: [String: [WantedEntry]] = [:]
            for device in listed where device.entries > 0 {
                found[device.id] = try await app.asManager { try await $0.deviceWanted(deviceID: device.id) }.wanted
            }
            devices = listed
            entries = found
            hasLoaded = true
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    func send(to target: Target) async {
        guard let request, busy == nil else { return }
        busy = target.id
        problem = nil
        defer { busy = nil }
        let id = target.id
        do {
            let entry = try await app.asManager { client in
                switch request {
                case .item(let itemID):
                    try await client.addWanted(deviceID: id, itemID: itemID)
                case .nextEpisodes(let showID, let profileID, let count):
                    try await client.addWantedNextEpisodes(deviceID: id, showID: showID, profileID: profileID, count: count)
                }
            }
            entries[id, default: []].removeAll { $0.id == entry.id }
            entries[id, default: []].append(entry)
            // This device need not wait for its next look.
            if id == app.device?.id { await app.syncWanted() }
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    func takeOff(_ target: Target) async {
        guard let entry = target.entry, busy == nil else { return }
        busy = target.id
        problem = nil
        defer { busy = nil }
        let id = target.id
        do {
            try await app.asManager { try await $0.removeWanted(deviceID: id, wantedID: entry.id) }
            entries[id]?.removeAll { $0.id == entry.id }
            if id == app.device?.id { await app.syncWanted() }
        } catch {
            problem = await app.managerProblem(error)
        }
    }
}
