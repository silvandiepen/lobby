// SPDX-License-Identifier: MPL-2.0
import CoreGraphics
import Foundation
import ImageIO
import LobbyKit
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import Lobby

/// A Lobby Server as the app sees it over HTTP, answering from state a test sets up: viewers,
/// items, progress, and whether this device is still welcome. Written to `docs/api.md`.
final class Household: Sendable {
    struct State: Sendable {
        /// `GET /v1/outside` as the server says it. nil: a server without it.
        var outside: String? = nil
        /// Whose household the device is in, as `GET /v1/me` says it. nil: a server from before households.
        var household: HouseholdSummary? = nil
        /// `GET /v1/households`, for the owner's managers. nil: a server without households.
        var households: String? = nil
        /// What was asked to make or change, each time, as it was sent.
        var householdChanges: [Data] = []
        /// Who waits at a guest household's window, as `GET /v1/pairing/requests` lists them.
        var outsideRequests = "[]"
        /// `GET /v1/settings` as the server says it. nil: a server without it.
        var settings: String? = nil
        /// What `PATCH /v1/settings` answers. A change that restarts gives the settings a new boot id.
        var settingsChange = #"{"dryRun":true,"version":1,"changed":[],"effects":[],"restart":false,"restarting":false,"rescanFolders":0,"bootId":"boot-1"}"#
        var server = ServerInfo(id: "server-1", name: "Family Pi", version: "0.1.0", apiVersion: 1, claimed: true)
        var device = Device(id: "dev-1", name: "Test iPhone", platform: .ios, role: .viewer, createdAt: Make.epoch)
        var profiles: [Profile] = [
            Profile(id: "alex", name: "Alex", color: "blue"),
            Profile(id: "kids", name: "Kids", color: "green"),
        ]
        /// False: a server from before kids viewers.
        var knowsKids = false
        /// What `GET /v1/me/kids` says. nil: the route is not there, as on a server from before plans.
        var kidsMe: KidsMe?
        /// False: a server from before avatars.
        var knowsAvatars = false
        var items: [Item] = []
        /// What every further look at the library says is gone.
        var removed: [String] = []
        /// Progress per profile id, per item id.
        var progress: [String: [String: PlaybackProgress]] = [:]
        var revision = 0
        /// Nothing answers: the Pi is off, or the device is not on the home network.
        var offline = false
        /// The device is not on the home network: the home address does not answer.
        var awayFromHome = false
        /// Away from home, another Lobby Server with this id answers at the home address.
        var strangerAtHomeAddress: String?
        /// A manager removed this device.
        var revoked = false
        /// A manager typed the pairing code.
        var approved = false
        /// The pairing code is older than ten minutes.
        var codeExpired = false
        var setupSecret = "the-setup-secret"
        /// The credential this server hands out and accepts.
        var token = "device-token"
        /// What `POST /v1/assets/{id}/playback` answers, one per call. The last one repeats.
        /// When empty, an asset in `files` is answered as ready to play and download directly.
        var playback: [StubResponse] = []
        /// What a manager wants on this device. nil: the server does not know about lists.
        var wanted: DeviceWantedList?
        /// What the device said it has, each time it said so.
        var reports: [DownloadsReport] = []
        /// What a manager put on each device, by device id.
        var deviceLists: [String: [ListEntry]] = [:]
        /// The files those stand for and what the device said, as the server writes them.
        var deviceAssets: [String: String] = [:]
        /// What else a device holds, as the server writes it.
        var deviceOther: [String: String] = [:]
        /// Posters, backdrops and stills, as JPEG, by artwork id.
        var pictures: [String: Data] = [:]
        /// The household's parts of the library. nil: the server does not have the route.
        var categoryGroups: CategoryGroups?
        /// The library folders, and the category each feeds, for the manager's settings.
        var folders: [String: String?] = [:]
        /// Titles as a manager edits them, by item id.
        var itemEdits: [String: EditedItem] = [:]
        /// `GET /v1/stats/viewers/{id}` and `GET /v1/stats/server` as the server says them.
        /// nil: a server from before statistics.
        var viewerStats: String? = nil
        var serverStats: String? = nil
        /// What the statistics were asked for, as `path?range=…`.
        var statsAsked: [String] = []
        /// Sittings taken out of a history, as `viewer/sitting`, and viewers whose history went.
        var removedSittings: [String] = []
        var forgottenViewers: [String] = []
        /// The pictures that were sent.
        var uploads: [Data] = []
        /// When set, the library is served in pages of this many items.
        var pageSize: Int?
        var pagesServed = 0
        /// The connection breaks on this page of the library (1 is the first).
        var failLibraryAtPage: Int?
        /// The other devices paired with the server.
        var otherDevices: [Device] = []
        /// Devices showing a code and waiting for a manager: the code, and who shows it.
        var waiting: [String: String] = [:]
        /// What the device has room for.
        var freeBytes: Int64 = 64_000_000_000
        /// What `GET …/subtitles/{id}.vtt` answers, by subtitle id, one per call. The last
        /// one repeats.
        var subtitles: [String: [StubResponse]] = [:]
        /// The household's code for grown-ups. nil: none chosen.
        var kidsCode: String?
        /// False: a server from before codes.
        var knowsKidsCode = true
        /// Wrong codes so far: after five the server refuses for a while.
        var wrongKidsCodes = 0
        /// The bytes of files on the server's drive, by asset id.
        var files: [String: Data] = [:]
        /// What any change of the categories would let kids viewers see: it is refused with
        /// `kids_confirmation` until it comes with `kidsToken` "kids-token". nil: nothing.
        var kidsQuestion: [KidsChange]?
        /// The setup before the last arrangement, while nothing else changed it.
        var undoable: CategoryGroups?
        /// `GET /v1/categories/suggestions` as the server writes it. nil: a server without it.
        var suggestions: String?
        /// Suggestions a manager dismissed, by id.
        var dismissed: [String] = []
    }

    /// What Lobby finds by itself, what a manager laid over it, and the count of edits.
    struct EditedItem: Sendable {
        var item: Item
        var revision = 0
        var overriddenTitle: String?
        /// `.some(nil)`: changed to no year.
        var overriddenYear: Int??
        var overriddenCategories: [String]?
        var uploaded = false

        func json(error: String? = nil) throws -> String {
            func text(_ value: some Encodable) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
            func field(_ automatic: some Encodable, _ overridden: Bool, _ effective: some Encodable) throws -> String {
                #"{"automatic":\#(try text(automatic)),"overridden":\#(overridden),"override":null,"effective":\#(try text(effective))}"#
            }
            var shown = item
            shown.title = overriddenTitle ?? item.title
            let year = overriddenYear ?? item.year
            let encoded = String(decoding: try LobbyJSON.encoder().encode(shown), as: UTF8.self)
            let ids = item.categoryIds ?? []
            return #"{\#(error.map { #""error":{"code":"conflict","message":"\#($0)"},"# } ?? "")"item":\#(encoded),"revision":\#(revision),"fields":{"title":\#(try field(item.title, overriddenTitle != nil, shown.title)),"sortTitle":\#(try field(item.sortTitle, false, item.sortTitle)),"year":\#(try field(item.year, overriddenYear != nil, year)),"overview":\#(try field(item.overview, false, item.overview)),"genres":\#(try field(item.genres, false, item.genres))},"categories":[{"id":"c1","name":"One"},{"id":"c2","name":"Two"}],"categoryIds":{"automatic":\#(try text(ids)),"overridden":\#(overriddenCategories != nil),"effective":\#(try text(overriddenCategories ?? ids))},"categoryNames":[],"artwork":{"poster":[],"backdrop":[]},"match":{"status":"needs_review","chosen":false,"tmdb":null,"canChange":true,"available":true,"reason":"Two films have that name.","candidates":[],"evidence":[]}}"#
        }
    }

    struct ListEntry: Encodable, Sendable {
        var id: String
        var kind: String
        var itemId: String
        var itemKind: String
        var profileId: String?
        var count: Int?
        var addedBy: String?
        var addedAt = 1_795_530_000_000
    }

    /// The server at its home address.
    let stub: StubServer
    /// The same server as it is reached from elsewhere (over Tailscale, say).
    let remote: StubServer
    private let state: Mutex<State>

    init(_ initial: State = State()) {
        let state = Mutex(initial)
        self.state = state
        stub = StubServer { _ in .error(500, "unavailable", "Not set up.") }
        remote = StubServer { _ in .error(500, "unavailable", "Not set up.") }
        stub.setHandler { [unowned self] request in try self.answer(request, atHome: true) }
        remote.setHandler { [unowned self] request in try self.answer(request, atHome: false) }
    }

    /// The server tells its paired devices where it can be reached.
    func announceAddresses() {
        change { $0.server.addresses = ServerAddresses(home: [stub.baseURL], remote: [remote.baseURL]) }
    }

    func change(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    var current: State { state.withLock { $0 } }

    private func answer(_ request: RecordedRequest, atHome: Bool) throws -> StubResponse {
        try state.withLock { state in
            if state.offline { throw URLError(.cannotConnectToHost) }
            if atHome, state.awayFromHome {
                // On another network the home address is nobody, or somebody else's machine.
                guard let stranger = state.strangerAtHomeAddress else { throw URLError(.cannotFindHost) }
                guard request.path == "/v1/server" else { return .error(401, "unauthorized", "Who are you?") }
                return try .encoded(ServerInfo(id: stranger, name: "Hotel", version: "0.1.0", apiVersion: 1, claimed: true))
            }
            let path = request.path.split(separator: "/").map(String.init)
            guard path.first == "v1" else { return .error(404, "not_found", "No such route.") }
            let route = Array(path.dropFirst())

            // Open routes.
            switch (request.method, route) {
            case ("GET", ["server"]):
                return try .encoded(state.server)
            case ("POST", ["pairing", "requests"]):
                return .json(201, #"{ "id": "req-1", "code": "482913", "pollSecret": "poll", "expiresAt": 1795530600000 }"#)
            case ("POST", ["pairing", "requests", "req-1", "collect"]):
                if state.codeExpired { return .error(410, "gone", "This pairing request expired.") }
                guard state.approved else { return .json(202, #"{ "status": "pending", "expiresAt": 1795530600000 }"#) }
                state.revoked = false
                return try .encoded(Grant(status: "approved", device: state.device, token: state.token))
            case ("POST", ["pairing", "claim"]):
                let secretIsRight = request.json()["setupSecret"] as? String == state.setupSecret
                guard !state.server.claimed, state.server.claim == .open || secretIsRight else {
                    return .error(403, "forbidden", "That is not the setup secret.")
                }
                state.server.claimed = true
                state.device.role = .manager
                return try .encoded(Grant(status: nil, device: state.device, token: state.token), status: 201)
            default:
                break
            }

            guard request.headers["Authorization"] == "Bearer \(state.token)" else {
                return .error(401, "unauthorized", "This device is not paired.")
            }
            if state.revoked {
                return .error(401, "device_revoked", "A manager removed this device.")
            }

            switch (request.method, route) {
            case ("GET", ["me"]):
                return try .encoded(Whoami(device: state.device, server: state.server, household: state.household))
            case ("GET", ["me", "kids"]) where state.kidsMe != nil:
                return try .encoded(state.kidsMe)
            case ("PUT", ["me", "kids", "place"]) where state.kidsMe != nil:
                return try .encoded(["now": state.kidsMe?.now])
            case ("PUT", ["me", "push"]), ("DELETE", ["me", "push"]):
                return StubResponse(status: 204)
            case ("GET", ["profiles"]):
                return try .encoded(Profiles(profiles: state.profiles.map { Self.told($0, state) }))
            case ("GET", ["kids", "code"]) where state.knowsKidsCode && state.device.kidsProfileId == nil:
                return .json(200, #"{ "set": \#(state.kidsCode != nil) }"#)
            case ("POST", ["kids", "code", "check"]) where state.knowsKidsCode && state.device.kidsProfileId == nil:
                guard state.kidsCode != nil else { return .error(409, "conflict", "No code was chosen yet.") }
                guard state.wrongKidsCodes < 5 else { return .error(429, "rate_limited", "Too many wrong attempts.") }
                let correct = request.json()["code"] as? String == state.kidsCode
                state.wrongKidsCodes = correct ? 0 : state.wrongKidsCodes + 1
                return .json(200, #"{ "correct": \#(correct) }"#)
            case ("PUT", ["kids", "code"]) where state.knowsKidsCode:
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can.") }
                state.kidsCode = request.json()["code"] as? String
                return .json(200, #"{ "set": \#(state.kidsCode != nil) }"#)
            case ("GET", ["me", "wanted"]):
                // nil: a server from before managers could put downloads on a device.
                guard let wanted = state.wanted else { return .error(404, "not_found", "No such route.") }
                if request.headers["If-None-Match"] == "\"\(wanted.revision)\"" { return StubResponse(status: 304) }
                return try .encoded(wanted)
            case ("POST", ["me", "downloads"]):
                guard let wanted = state.wanted else { return .error(404, "not_found", "No such route.") }
                state.reports.append(try JSONDecoder().decode(DownloadsReport.self, from: request.body))
                return .json(200, #"{ "accepted": \#(state.reports.last?.downloads.count ?? 0), "wantedRevision": "\#(wanted.revision)" }"#)
            case ("POST", ["profiles"]):
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can add viewers.") }
                let body = request.json()
                let profile = Profile(
                    id: "p\(state.profiles.count + 1)", name: body["name"] as? String ?? "", color: body["color"] as? String ?? "",
                    avatar: body["avatar"] as? String, saysAvatar: true,
                    kids: state.knowsKids ? Self.kids(body["kids"]) : nil, saysKids: state.knowsKids)
                state.profiles.append(profile)
                return try .encoded(Self.told(profile, state), status: 201)
            case ("PATCH", _) where route.count == 2 && route[0] == "profiles":
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can change viewers.") }
                guard let index = state.profiles.firstIndex(where: { $0.id == route[1] }) else {
                    return .error(404, "not_found", "No such viewer.")
                }
                let old = state.profiles[index]
                let body = request.json()
                let kids = body.keys.contains("kids") ? Self.kids(body["kids"]) : old.kids
                state.profiles[index] = Profile(
                    id: old.id, name: body["name"] as? String ?? old.name, color: body["color"] as? String ?? old.color,
                    avatar: body.keys.contains("avatar") ? body["avatar"] as? String : old.avatar, saysAvatar: true,
                    kids: state.knowsKids ? kids : nil, saysKids: state.knowsKids)
                return try .encoded(Self.told(state.profiles[index], state))
            case ("PUT", _) where route.count == 3 && route[0] == "profiles" && route[2] == "avatar" && state.knowsAvatars:
                guard let index = state.profiles.firstIndex(where: { $0.id == route[1] }),
                    state.device.kidsProfileId == nil || state.device.kidsProfileId == route[1]
                else { return .error(404, "not_found", "There is no such viewer.") }
                state.profiles[index].avatar = request.json()["avatar"] as? String
                return try .encoded(Self.told(state.profiles[index], state))
            case ("PUT", _) where route.count == 3 && route[0] == "profiles" && route[2] == "skipping":
                // A grown-up chooses this for a child: a child's device has no such route.
                guard let index = state.profiles.firstIndex(where: { $0.id == route[1] }), state.device.kidsProfileId == nil else {
                    return .error(404, "not_found", "There is no such viewer.")
                }
                let body = request.json()
                var skipping = state.profiles[index].skipPreferences
                if let intro = (body["intro"] as? String).flatMap(SkipPreferences.Intro.init) { skipping.intro = intro }
                if let credits = (body["credits"] as? String).flatMap(SkipPreferences.Credits.init) { skipping.credits = credits }
                state.profiles[index].skipping = skipping
                return try .encoded(Self.told(state.profiles[index], state))
            case ("PATCH", _) where route.count == 2 && route[0] == "devices" && state.knowsKids:
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can change devices.") }
                guard let index = state.otherDevices.firstIndex(where: { $0.id == route[1] }) else {
                    return .error(404, "not_found", "No such device.")
                }
                let old = state.otherDevices[index]
                state.otherDevices[index] = Device(
                    id: old.id, name: old.name, platform: old.platform, role: old.role, createdAt: old.createdAt,
                    kidsProfileId: request.json()["kidsProfileId"] as? String, saysKidsProfile: true)
                return try .encoded(state.otherDevices[index])
            case ("DELETE", _) where route.count == 2 && route[0] == "profiles":
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can remove viewers.") }
                state.profiles.removeAll { $0.id == route[1] }
                state.progress[route[1]] = nil
                return StubResponse(status: 204)
            case ("GET", ["pairing", "requests"]):
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can see who is waiting.") }
                let requests = state.waiting.sorted { $0.value < $1.value }.map {
                    #"{"id":"req-\#($0.value)","deviceName":"\#($0.value)","platform":"tvos","code":"\#($0.key)","createdAt":1795530000000,"expiresAt":1795530600000}"#
                }
                return .json(200, #"{"requests":[\#(requests.joined(separator: ","))],"outsideRequests":\#(state.outsideRequests)}"#)
            case ("POST", ["pairing", "approve"]):
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can approve devices.") }
                let body = request.json()
                let picked = (body["requestId"] as? String).flatMap { id in
                    state.waiting.first { "req-\($0.value)" == id }?.key
                }
                guard let code = picked ?? body["code"] as? String, let name = state.waiting.removeValue(forKey: code) else {
                    return .error(404, "not_found", "No device is waiting with that code.")
                }
                // "access" now; "role" from an app before household admins, "manager" a server admin.
                let access = body["access"] as? String ?? (body["role"] as? String == "manager" ? "admin" : "viewer")
                let role = access == "admin" ? "manager" : "viewer"
                var made = Device(
                    id: "dev-\(state.otherDevices.count + 2)", name: name, platform: .tvos, role: DeviceRole(role),
                    createdAt: Make.epoch.addingTimeInterval(60))
                made.access = DeviceAccess(access)
                state.otherDevices.append(made)
                return .json(200, #"{"deviceName":"\#(name)","platform":"tvos","role":"\#(role)","access":"\#(access)","awaitsAdmin":false}"#)
            case ("GET", ["devices"]):
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can list devices.") }
                return try .encoded(Devices(devices: [state.device] + state.otherDevices, currentDeviceId: state.device.id))
            case ("DELETE", _) where route.count == 2 && route[0] == "devices":
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can remove devices.") }
                if route[1] == state.device.id { return .error(409, "conflict", "The last manager cannot be removed.") }
                state.otherDevices.removeAll { $0.id == route[1] }
                return StubResponse(status: 204)
            case ("GET", ["devices", "wanted"]):
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can see the lists.") }
                let lines = ([state.device] + state.otherDevices).map { device in
                    let entries = state.deviceLists[device.id] ?? []
                    return #"{"id":"\#(device.id)","name":"\#(device.name)","platform":"\#(device.platform.rawValue)","role":"\#(device.role.rawValue)","lastSeenAt":null,"entries":\#(entries.count),"files":\#(entries.count),"downloaded":0,"failed":0,"bytesToFetch":1000000,"ownDownloads":0,"storage":{"freeBytes":41000000000,"totalBytes":128000000000,"reportedAt":1795530000000}}"#
                }
                return .json(200, #"{"devices":[\#(lines.joined(separator: ","))]}"#)
            case ("GET", _) where route.count == 3 && route[0] == "devices" && route[2] == "wanted":
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can see the lists.") }
                guard let device = ([state.device] + state.otherDevices).first(where: { $0.id == route[1] }) else {
                    return .error(404, "not_found", "No such device.")
                }
                let entries = String(decoding: try JSONEncoder().encode(state.deviceLists[device.id] ?? []), as: UTF8.self)
                return .json(200, #"{"device":{"id":"\#(device.id)","name":"\#(device.name)","platform":"\#(device.platform.rawValue)","role":"\#(device.role.rawValue)","lastSeenAt":null},"wanted":\#(entries),"assets":\#(state.deviceAssets[device.id] ?? "[]"),"leftOut":0,"storage":null,"bytesToFetch":0,"fits":null,"other":\#(state.deviceOther[device.id] ?? "[]")}"#)
            case ("POST", _) where route.count == 3 && route[0] == "devices" && route[2] == "wanted":
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can send downloads.") }
                let body = request.json()
                let kind = body["kind"] as? String ?? ""
                let itemID = (body["itemId"] ?? body["showId"]) as? String ?? ""
                guard let item = state.items.first(where: { $0.id == itemID }) else {
                    return .error(404, "not_found", "That title is not in the library.")
                }
                var list = state.deviceLists[route[1]] ?? []
                let profile = body["profileId"] as? String
                let count = body["count"] as? Int
                if let index = list.firstIndex(where: { $0.kind == kind && $0.itemId == itemID && $0.profileId == profile }) {
                    list[index].count = count
                    state.deviceLists[route[1]] = list
                    return .json(200, #"{"entry":\#(String(decoding: try JSONEncoder().encode(list[index]), as: UTF8.self))}"#)
                }
                let entry = ListEntry(id: "w\(list.count + 1)", kind: kind, itemId: itemID, itemKind: item.kind.rawValue, profileId: profile, count: count)
                state.deviceLists[route[1]] = list + [entry]
                return .json(201, #"{"entry":\#(String(decoding: try JSONEncoder().encode(entry), as: UTF8.self))}"#)
            case ("DELETE", _) where route.count == 4 && route[0] == "devices" && route[2] == "wanted":
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can send downloads.") }
                guard state.deviceLists[route[1]]?.contains(where: { $0.id == route[3] }) == true else {
                    return .error(404, "not_found", "That is not on this device's list.")
                }
                state.deviceLists[route[1]]?.removeAll { $0.id == route[3] }
                return StubResponse(status: 204)
            case ("GET", ["settings"]) where state.settings != nil:
                return .json(200, state.settings ?? "")
            case ("PATCH", ["settings"]) where state.settings != nil:
                let dryRun = request.json()["dryRun"] as? Bool ?? false
                let answer = state.settingsChange.replacingOccurrences(of: #""dryRun":true"#, with: #""dryRun":\#(dryRun)"#)
                if !dryRun, answer.contains(#""restarting":true"#) {
                    state.settings = state.settings?.replacingOccurrences(of: "boot-1", with: "boot-2")
                }
                return .json(200, answer)
            case ("PUT", ["settings", "tmdb"]) where state.settings != nil:
                guard request.json()["key"] as? String == "0123456789abcdef0123456789abcdef" else {
                    return .error(400, "invalid_request", "TMDB does not accept this key.")
                }
                return .json(200, #"{"tmdbKey":{"set":true,"source":"settings"}}"#)
            case ("GET", _) where route.count == 3 && route[0] == "stats" && route[1] == "viewers" && state.viewerStats != nil:
                state.statsAsked.append("viewers/\(route[2])?range=\(request.query["range"] ?? "")")
                return .json(200, state.viewerStats ?? "")
            case ("DELETE", _) where route.count == 5 && route[0] == "stats" && route[3] == "history":
                state.removedSittings.append("\(route[2])/\(route[4])")
                return StubResponse(status: 204)
            case ("DELETE", _) where route.count == 3 && route[0] == "stats" && route[1] == "viewers":
                guard state.device.level != .viewer else {
                    return .error(403, "forbidden", "Only an admin of this household can forget a viewer's history.")
                }
                state.forgottenViewers.append(route[2])
                return StubResponse(status: 204)
            case ("GET", ["stats", "server"]) where state.serverStats != nil:
                guard state.device.level == .admin else { return .error(403, "forbidden", "Only a server admin can.") }
                state.statsAsked.append("server?range=\(request.query["range"] ?? "")&household=\(request.query["household"] ?? "")")
                return .json(200, state.serverStats ?? "")
            case ("GET", ["households"]) where state.households != nil:
                guard state.device.level != .viewer, state.household?.owner != false else {
                    return .error(404, "not_found", "There is nothing at this address.")
                }
                return .json(200, state.households ?? "")
            case ("POST", ["households"]) where state.households != nil:
                guard state.device.level != .viewer, state.household?.owner != false else {
                    return .error(404, "not_found", "There is nothing at this address.")
                }
                state.householdChanges.append(request.body)
                let name = request.json()["name"] as? String ?? ""
                return .json(201, #"{"household":{"id":"h-2","name":"\#(name)","owner":false,"scope":null,"maxMbps":null,"allowOutside":true,"maxDevices":null,"paused":false,"pausedAt":null,"createdAt":1795530000000,"devices":0,"managers":0,"viewers":0},"invite":{"id":"inv-1","householdId":"h-2","createdBy":"dev-1","createdAt":1795530000000,"expiresAt":4102444800000,"usedAt":null,"revokedAt":null,"code":"0123-4567-89AB-CDEF","introducer":"wss://introducer.example.com","link":"lobby://pair?i=wss%3A%2F%2Fintroducer.example.com&c=0123-4567-89AB-CDEF&h=The%20neighbours&s=Family%20Pi"}}"#)
            case ("PATCH", _) where route.count == 2 && route[0] == "households" && state.households != nil:
                state.householdChanges.append(request.body)
                return .json(200, #"{"id":"\#(route[1])","name":"The neighbours","owner":false,"scope":null,"maxMbps":null,"allowOutside":true,"maxDevices":null,"paused":true,"pausedAt":1795530000000,"createdAt":1795530000000,"devices":1,"managers":1,"viewers":0}"#)
            case ("GET", _) where route.count == 2 && route[0] == "households" && state.households != nil:
                return .json(200, #"{"household":{"id":"\#(route[1])","name":"The neighbours","owner":false,"scope":null,"maxMbps":null,"allowOutside":true,"maxDevices":null,"paused":true,"pausedAt":1795530000000,"createdAt":1795530000000,"devices":1,"managers":1,"viewers":0},"devices":[{"id":"g-1","name":"Their phone","platform":"ios","role":"manager","createdAt":1795530000000,"lastUsedAt":null,"lastOutsideAt":null}],"invites":[]}"#)
            case ("POST", ["household", "invites"]) where state.households != nil:
                guard state.device.level != .viewer || state.device.access == .householdAdmin else {
                    return .error(403, "forbidden", "Only an admin of this household can.")
                }
                state.householdChanges.append(request.body)
                let access = request.json()["access"] as? String ?? "householdAdmin"
                return .json(201, #"{"id":"inv-2","householdId":"owner","access":"\#(access)","createdBy":"dev-1","createdAt":1795530000000,"expiresAt":4102444800000,"usedAt":null,"revokedAt":null,"code":"0123-4567-89AB-CDEF","introducer":"wss://introducer.example.com","link":"lobby://pair?i=wss%3A%2F%2Fintroducer.example.com&c=0123-4567-89AB-CDEF&h=Home&s=Family%20Pi"}"#)
            case ("POST", ["outside", "window"]) where state.household?.owner == false:
                // A guest household's manager opens their own window, without the owner's status.
                return .json(201, #"{"code":"0123-4567-89AB-CDEF","expiresAt":4102444800000,"direct":{"introducer":"wss://introducer.example.com"}}"#)
            case ("GET", ["outside", "access"]) where state.household?.owner == false:
                return .json(200, #"{"entries":[]}"#)
            case ("POST", _) where route.count == 4 && route[0] == "outside" && route[1] == "pairing" && state.household?.owner == false:
                guard request.json()["comparison"] as? String == "482913" else { return .error(409, "conflict", "Those are other digits.") }
                return .json(200, #"{"deviceName":"Their TV","platform":"tvos","role":"viewer","householdId":"h-2"}"#)
            case ("GET", ["status"]) where state.household?.owner == false:
                return .error(404, "not_found", "There is nothing here for this device.")
            case ("GET", ["outside"]) where state.outside != nil:
                return .json(200, state.outside ?? "")
            case ("PATCH", ["outside"]) where state.outside != nil:
                let on = request.json()["enabled"] as? Bool ?? false
                state.outside = state.outside?.replacingOccurrences(of: "\"enabled\":\(!on)", with: "\"enabled\":\(on)")
                return .json(200, state.outside ?? "")
            case ("POST", ["outside", "window"]) where state.outside != nil:
                return .json(201, #"{"code":"0123-4567-89AB-CDEF","expiresAt":4102444800000,"direct":{"introducer":"wss://introducer.example.com"}}"#)
            case ("GET", ["outside", "access"]) where state.outside != nil:
                return .json(200, #"{"entries":[{"id":2,"at":1795530000000,"until":1795530050000,"count":4,"deviceId":"dev-2","transport":"direct","address":"203.0.113.7","routeClass":"stream","outcome":"ok"},{"id":1,"at":1795530000000,"until":1795530050000,"count":1,"deviceId":null,"transport":"direct","address":null,"routeClass":"none","outcome":"refused"}]}"#)
            case ("POST", _) where route.count == 4 && route[0] == "outside" && route[1] == "pairing":
                guard request.json()["comparison"] as? String == "482913" else { return .error(409, "conflict", "Those are other digits.") }
                return .json(200, #"{"deviceName":"Apple TV","platform":"tvos","role":"viewer"}"#)
            case ("GET", ["status"]):
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can see the status.") }
                return .json(200, #"{"scanning":true,"sources":[{"id":"s1","name":"Pixar","hint":"movies","available":true,"lastScanStartedAt":null,"lastScanFinishedAt":null,"files":34},{"id":"s2","name":"Disney","hint":"movies","available":false,"lastScanStartedAt":null,"lastScanFinishedAt":null,"files":0}],"files":{"total":3070,"waiting":12,"failed":3,"missing":0},"playability":{"direct":920,"remux":1380,"transcode":620,"unsupported":4},"items":{"movies":380,"shows":50,"episodes":2500,"extras":40,"personal":0,"needsReview":62,"unmatched":310}}"#)
            case ("GET", _) where route.count == 2 && route[0] == "artwork":
                guard let picture = state.pictures[route[1]] else { return .error(404, "not_found", "No such artwork.") }
                return StubResponse(status: 200, headers: ["Content-Type": "image/jpeg"], body: picture)
            case ("GET", ["categories"]):
                // nil: a server from before groups existed.
                guard let groups = state.categoryGroups else { return .error(404, "not_found", "No such route.") }
                return try .encoded(groups)
            case (_, _) where route.count >= 2 && route[0] == "items" && state.itemEdits[route[1]] != nil:
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can edit titles.") }
                let id = route[1]
                var edited = state.itemEdits[id]!
                if request.method == "GET", route.count == 3, route[2] == "edit" { return .json(200, try edited.json()) }
                let body = request.json()
                guard (body["revision"] as? Int ?? request.query["revision"].flatMap(Int.init)) == edited.revision else {
                    return .json(409, try edited.json(error: "Someone else changed this."))
                }
                switch (request.method, route.count) {
                case ("PATCH", 2):
                    let set = body["set"] as? [String: Any] ?? [:]
                    let reset = body["reset"] as? [String] ?? []
                    if let title = set["title"] as? String { edited.overriddenTitle = title }
                    if set.keys.contains("year") { edited.overriddenYear = .some(set["year"] as? Int) }
                    if let ids = set["categoryIds"] as? [String] { edited.overriddenCategories = ids }
                    if reset.contains("title") { edited.overriddenTitle = nil }
                    if reset.contains("year") { edited.overriddenYear = nil }
                    if reset.contains("categories") { edited.overriddenCategories = nil }
                case ("POST", 4) where route[3] == "upload":
                    state.uploads.append(request.body)
                default:
                    return .error(404, "not_found", "No such route.")
                }
                edited.revision += 1
                state.itemEdits[id] = edited
                return .json(200, try edited.json())
            case ("GET", ["categories", "edit"]):
                guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can change the categories.") }
                return try Self.categoriesEdit(state)
            case ("GET", ["categories", "logo-search", "preview"]):
                guard let picture = request.query["path"].flatMap({ state.pictures[$0] }) else {
                    return .error(404, "not_found", "No such logo.")
                }
                return StubResponse(status: 200, headers: ["Content-Type": "image/png"], body: picture)
            case ("GET", ["categories", "suggestions"]):
                return state.suggestions.map { .json(200, $0) } ?? .error(404, "not_found", "No such route.")
            case ("POST", _) where route.count == 4 && route[1] == "suggestions" && route[3] == "dismiss":
                state.dismissed.append(route[2])
                return .json(200, #"{"min":8,"suggestions":[]}"#)
            case (_, _) where route.first == "categories" && route.count > 1 || (request.method == "POST" && route == ["categories"]):
                return try Self.changeCategories(request, route: route, in: &state)
            case ("GET", ["library"]):
                // In pages of `pageSize`, with the cursor saying where the next one starts.
                guard let pageSize = state.pageSize else {
                    return try .encoded(LibraryPage(items: request.query["cursor"] == nil ? state.items : [], removed: state.removed, cursor: "c1"))
                }
                let start = request.query["cursor"].flatMap { Int($0.dropFirst(4)) } ?? 0
                if request.query["cursor"] == "end" { return try .encoded(LibraryPage(items: [], cursor: "end")) }
                let end = min(state.items.count, start + pageSize)
                state.pagesServed += 1
                if let failAt = state.failLibraryAtPage, state.pagesServed == failAt { throw URLError(.networkConnectionLost) }
                return try .encoded(LibraryPage(
                    items: Array(state.items[start..<end]), cursor: end == state.items.count ? "end" : "page\(end)",
                    more: end < state.items.count))
            case ("GET", _) where route.count == 3 && route[0] == "profiles" && route[2] == "progress":
                let profile = route[1]
                return try .encoded(
                    Progresses(progress: Array((state.progress[profile] ?? [:]).values), revision: state.revision))
            case ("PUT", _) where route.count == 4 && route[0] == "profiles" && route[2] == "progress":
                let profile = route[1]
                let item = route[3]
                let update = try LobbyJSON.decoder().decode(ProgressUpdate.self, from: request.body)
                state.revision += 1
                let accepted = PlaybackProgress(
                    itemId: item, positionMs: update.positionMs, durationMs: update.durationMs,
                    completed: update.completed, revision: state.revision, updatedAt: update.updatedAt)
                state.progress[profile, default: [:]][item] = accepted
                return try .encoded(Accepted(progress: accepted))
            case ("POST", _) where route.count == 3 && route[0] == "assets" && route[2] == "playback":
                if let next = state.playback.first {
                    if state.playback.count > 1 { state.playback.removeFirst() }
                    return next
                }
                let assetID = route[1]
                guard let bytes = state.files[assetID],
                    let file = state.items.flatMap(\.files).first(where: { $0.assetId == assetID })
                else { return .error(404, "not_found", "No such asset.") }
                let url = "/v1/assets/\(assetID)/content"
                return .json(200, #"{"state":"ready","mode":"direct","revision":"\#(file.revision)","progress":1,"preparedMs":0,"durationMs":null,"streamUrl":"\#(url)","downloadUrl":"\#(url)","downloadBytes":\#(bytes.count),"audio":[],"message":null}"#)
            case ("GET", _) where route.count == 4 && route[0] == "assets" && route[2] == "subtitles":
                // "t2.vtt", or "pgs.json" for picture subtitles.
                let id = String(route[3].prefix { $0 != "." })
                guard let next = state.subtitles[id]?.first else { return .error(404, "not_found", "No such subtitle.") }
                if state.subtitles[id]!.count > 1 { state.subtitles[id]!.removeFirst() }
                return next
            case ("GET", _) where route.count == 3 && route[0] == "assets" && route[2] == "content":
                guard let bytes = state.files[route[1]],
                    let file = state.items.flatMap(\.files).first(where: { $0.assetId == route[1] })
                else { return .error(404, "not_found", "No such asset.") }
                return StubResponse(status: 200, headers: ["ETag": "\"\(file.revision)\"", "Content-Type": "video/mp4"], body: bytes)
            default:
                return .error(404, "not_found", "No such route.")
            }
        }
    }

    private struct CategoriesView: Encodable {
        struct Folder: Encodable {
            var id: String
            var name: String
            var hint = "mixed"
            var available = true
            var categoryId: String?
        }
        struct Failure: Encodable {
            var code: String
            var message: String
        }
        var revision: Int
        var groups: [CategoryGroup]
        var folders: [Folder]
        var colors = ["red", "teal"]
        var undo: String?
        var kidsChanges: [KidsChange]?
        var kidsToken: String?
        var created: [String: String]?
        var categoryIds: [String]?
        var dryRun: Bool?
        var needsConfirmation: Bool?
        var error: Failure?
    }

    private static func categoriesEdit(
        _ state: State, refusal: String? = nil, asking: Bool = false, created: [String: String]? = nil,
        categoryIds: [String]? = nil, dryRun: Bool = false
    ) throws -> StubResponse {
        let setup = state.categoryGroups ?? .none
        let tells = asking || dryRun
        return try .encoded(
            CategoriesView(
                revision: setup.revision, groups: setup.groups,
                folders: state.folders.keys.sorted().map { .init(id: $0, name: $0, categoryId: state.folders[$0] ?? nil) },
                undo: dryRun || state.undoable == nil ? nil : "undo-\(setup.revision)",
                kidsChanges: tells ? state.kidsQuestion ?? [] : nil,
                kidsToken: tells ? (state.kidsQuestion == nil ? "nothing-token" : "kids-token") : nil, created: created,
                categoryIds: categoryIds, dryRun: dryRun ? true : nil, needsConfirmation: dryRun ? state.kidsQuestion != nil : nil,
                error: refusal.map { .init(code: asking ? "kids_confirmation" : "conflict", message: $0) }),
            status: refusal == nil ? 200 : 409)
    }

    /// The part of "Editing categories" in docs/api.md that the tests use.
    private static func changeCategories(_ request: RecordedRequest, route: [String], in state: inout State) throws -> StubResponse {
        guard state.device.level != .viewer else { return .error(403, "forbidden", "Only a manager can change the categories.") }
        var setup = state.categoryGroups ?? .none
        let body = request.json()
        guard (body["revision"] as? Int ?? request.query["revision"].flatMap(Int.init)) == setup.revision else {
            return try categoriesEdit(state, refusal: "Someone else changed the categories meanwhile.")
        }
        // A dry run of what the tests send: the setup stays, and says what kids viewers would see.
        if body["dryRun"] as? Bool == true || request.query["dryRun"] == "true" {
            return try categoriesEdit(state, dryRun: true)
        }
        if state.kidsQuestion != nil, (body["kidsToken"] as? String ?? request.query["kidsToken"]) != "kids-token" {
            return try categoriesEdit(state, refusal: "This lets a child see more than now.", asking: true)
        }
        let before = setup
        var undoable: CategoryGroups?
        var created: [String: String]?
        var categoryIds: [String]?
        func place(_ id: String) -> (Int, Int)? {
            for (g, group) in setup.groups.enumerated() {
                if let e = group.entries.firstIndex(where: { $0.id == id }) { return (g, e) }
            }
            return nil
        }
        switch (request.method, route.count) {
        case ("POST", 1):
            guard let index = setup.groups.firstIndex(where: { $0.id == body["groupId"] as? String }) else {
                return .error(404, "not_found", "No such group.")
            }
            let name = body["name"] as? String ?? ""
            if setup.categories.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                return .error(400, "invalid_request", "There is a category with that name.")
            }
            let made = LibraryCategory(
                id: "new\(setup.revision)", parentId: body["parentId"] as? String, name: name, icon: body["icon"] as? String,
                color: body["color"] as? String)
            if let parent = made.parentId, let last = setup.groups[index].entries.lastIndex(where: { $0.id == parent || $0.parentId == parent }) {
                setup.groups[index].entries.insert(made, at: last + 1)
            } else {
                setup.groups[index].entries.append(made)
            }
        case ("POST", 4) where route[1] == "suggestions" && route[3] == "accept":
            guard let g = setup.groups.firstIndex(where: { $0.id == body["groupId"] as? String }) else {
                return .error(400, "invalid_request", "\"groupId\" must be a group's id.")
            }
            setup.groups[g].entries.append(LibraryCategory(
                id: "studio-\(route[2])", name: body["name"] as? String ?? "Studio \(route[2])",
                rule: CategoryRule(studioIds: ["company:\(route[2].dropFirst())"])))
            state.suggestions = #"{"min":8,"suggestions":[]}"#
        case ("POST", 3) where route[1] == "suggestions" && route[2] == "accept":
            let ids = body["ids"] as? [String] ?? []
            let studios = ids.map { "company:\($0.dropFirst())" }
            if let target = body["categoryId"] as? String {
                guard let (g, e) = place(target) else { return .error(404, "not_found", "No such category.") }
                let had = setup.groups[g].entries[e].rule?.studioIds ?? []
                setup.groups[g].entries[e].rule = CategoryRule(studioIds: Array(Set(had + studios)).sorted())
                categoryIds = [target]
            } else {
                let parent = body["parentId"] as? String
                let groupID = parent.flatMap { id in setup.groups.first { $0.entries.contains { $0.id == id } }?.id }
                    ?? body["groupId"] as? String
                guard let g = setup.groups.firstIndex(where: { $0.id == groupID }) else {
                    return .error(400, "invalid_request", "\"groupId\" must be a group's id.")
                }
                let together = body["together"] as? Bool ?? false
                let made: [LibraryCategory] = together || ids.count == 1
                    ? [LibraryCategory(
                        id: "studio-\(ids[0])", parentId: parent, name: body["name"] as? String ?? "Studio \(ids[0])",
                        rule: CategoryRule(studioIds: studios.sorted()))]
                    : zip(ids, studios).map { id, studio in
                        LibraryCategory(id: "studio-\(id)", parentId: parent, name: "Studio \(id)", rule: CategoryRule(studioIds: [studio]))
                    }
                setup.groups[g].entries += made
                categoryIds = made.map(\.id)
                Self.nest(&setup)
            }
            state.suggestions = #"{"min":8,"suggestions":[]}"#
        case ("POST", 2) where route[1] == "merge":
            guard let into = body["into"] as? String, place(into) != nil else { return .error(404, "not_found", "No such category.") }
            let ids = body["ids"] as? [String] ?? []
            guard !ids.isEmpty, !ids.contains(into), ids.allSatisfy({ place($0) != nil }) else {
                return .error(400, "invalid_request", "Those cannot be merged.")
            }
            var studios = Set(setup.category(id: into)?.rule?.studioIds ?? [])
            for id in ids { studios.formUnion(setup.category(id: id)?.rule?.studioIds ?? []) }
            for g in setup.groups.indices {
                setup.groups[g].entries.removeAll { ids.contains($0.id) }
                for e in setup.groups[g].entries.indices {
                    if let parent = setup.groups[g].entries[e].parentId, ids.contains(parent) { setup.groups[g].entries[e].parentId = into }
                    if setup.groups[g].entries[e].id == into, !studios.isEmpty {
                        setup.groups[g].entries[e].rule = CategoryRule(studioIds: studios.sorted())
                    }
                }
            }
            for (folder, category) in state.folders where category.map(ids.contains) == true { state.folders[folder] = .some(into) }
            Self.nest(&setup)
        case ("POST", 2) where route[1] == "arrange":
            guard let made = arrange(body, in: &setup) else { return .error(400, "invalid_request", "That does not fit.") }
            created = made
            undoable = before
        case ("POST", 3) where route[1] == "arrange" && route[2] == "undo":
            guard let old = state.undoable, body["token"] as? String == "undo-\(setup.revision)" else {
                return try categoriesEdit(state, refusal: "The categories changed since.")
            }
            setup.groups = old.groups
        case ("PATCH", 2):
            guard let (g, e) = place(route[1]) else { return .error(404, "not_found", "No such category.") }
            if let target = body["groupId"] as? String, let to = setup.groups.firstIndex(where: { $0.id == target }) {
                setup.groups[to].entries.append(setup.groups[g].entries.remove(at: e))
            } else {
                if let name = body["name"] as? String { setup.groups[g].entries[e].name = name }
                if body.keys.contains("icon") { setup.groups[g].entries[e].icon = body["icon"] as? String }
                if body.keys.contains("color") { setup.groups[g].entries[e].color = body["color"] as? String }
            }
        case ("PUT", 2) where route[1] == "order":
            let ids = body["ids"] as? [String] ?? []
            guard let g = setup.groups.firstIndex(where: { $0.id == body["groupId"] as? String }) else {
                return .error(404, "not_found", "No such group.")
            }
            setup.groups[g].entries = ids.compactMap { id in setup.groups[g].entries.first { $0.id == id } }
        case ("PUT", 3) where route[2] == "logo":
            guard let (g, e) = place(route[1]) else { return .error(404, "not_found", "No such category.") }
            setup.groups[g].entries[e].logo = CategoryLogo(id: body["path"] as? String ?? "", width: 10, height: 5)
        case ("PUT", 3) where route[1] == "folders":
            state.folders[route[2]] = .some(body["categoryId"] as? String)
        case ("DELETE", 2):
            guard let (g, e) = place(route[1]) else { return .error(404, "not_found", "No such category.") }
            let fed = state.folders.filter { $0.value == route[1] }.map(\.key)
            if !fed.isEmpty {
                guard let target = request.query["foldersTo"] else {
                    return .error(400, "invalid_request", "Say where its folders go.")
                }
                for folder in fed { state.folders[folder] = .some(target == "none" ? nil : target) }
            }
            setup.groups[g].entries.remove(at: e)
        default:
            return .error(404, "not_found", "No such route.")
        }
        setup.revision += 1
        state.categoryGroups = setup
        state.undoable = undoable
        return try categoriesEdit(state, created: created, categoryIds: categoryIds)
    }

    /// Each top-level one followed by those inside it, and those in the group of their parent,
    /// as the server lists them.
    private static func nest(_ setup: inout CategoryGroups) {
        for g in setup.groups.indices {
            let strays = setup.groups[g].entries.filter { entry in
                entry.parentId.map { parent in !setup.groups[g].entries.contains { $0.id == parent } } ?? false
            }
            for stray in strays {
                guard let to = setup.groups.firstIndex(where: { $0.entries.contains { $0.id == stray.parentId } }) else { continue }
                setup.groups[g].entries.removeAll { $0.id == stray.id }
                setup.groups[to].entries.append(stray)
            }
        }
        for g in setup.groups.indices {
            let entries = setup.groups[g].entries
            setup.groups[g].entries = entries.filter { $0.parentId == nil }.flatMap { top in
                [top] + entries.filter { $0.parentId == top.id }
            }
        }
    }

    /// `POST /v1/categories/arrange`, as far as the tests use it: one level, in one group.
    private static func arrange(_ body: [String: Any], in setup: inout CategoryGroups) -> [String: String]? {
        var made: [String: String] = [:]
        func real(_ id: String) -> String { id.hasPrefix("new:") ? made[String(id.dropFirst(4))] ?? id : id }
        for new in body["create"] as? [[String: Any]] ?? [] {
            guard let key = new["key"] as? String, let g = setup.groups.firstIndex(where: { $0.id == new["groupId"] as? String }) else {
                return nil
            }
            let id = "made-\(key)"
            made[key] = id
            let logo = (new["logoFrom"] as? String).flatMap { setup.category(id: $0)?.logo }
            setup.groups[g].entries.append(LibraryCategory(
                id: id, name: new["name"] as? String ?? "", icon: new["icon"] as? String, color: new["color"] as? String, logo: logo))
        }
        for change in body["categories"] as? [[String: Any]] ?? [] {
            guard let id = change["id"] as? String,
                let g = setup.groups.firstIndex(where: { $0.entries.contains { $0.id == id } }),
                let e = setup.groups[g].entries.firstIndex(where: { $0.id == id })
            else { return nil }
            if let name = change["name"] as? String { setup.groups[g].entries[e].name = name }
            if change.keys.contains("parentId") { setup.groups[g].entries[e].parentId = (change["parentId"] as? String).map(real) }
            if let target = change["groupId"] as? String, target != setup.groups[g].id,
                let to = setup.groups.firstIndex(where: { $0.id == target }) {
                var moved = setup.groups[g].entries.remove(at: e)
                moved.parentId = nil
                setup.groups[to].entries.append(moved)
            }
        }
        // One inside a category of another group goes to that group, with those inside it.
        for g in setup.groups.indices {
            for entry in setup.groups[g].entries {
                guard let parent = entry.parentId, !setup.groups[g].entries.contains(where: { $0.id == parent }),
                    let to = setup.groups.firstIndex(where: { $0.entries.contains { $0.id == parent } })
                else { continue }
                setup.groups[g].entries.removeAll { $0.id == entry.id }
                setup.groups[to].entries.append(entry)
            }
        }
        for order in body["order"] as? [[String: Any]] ?? [] {
            guard let g = setup.groups.firstIndex(where: { $0.id == order["groupId"] as? String }) else { return nil }
            let parent = (order["parentId"] as? String).map(real)
            let ids = (order["ids"] as? [String] ?? []).map(real)
            var entries = setup.groups[g].entries
            let sorted = ids.compactMap { id in entries.first { $0.id == id && $0.parentId == parent } }
            guard sorted.count == entries.filter({ $0.parentId == parent }).count else { return nil }
            var next = sorted.makeIterator()
            entries = entries.map { $0.parentId == parent ? next.next()! : $0 }
            setup.groups[g].entries = entries
        }
        // Each top-level one followed by those inside it, as the server lists them.
        nest(&setup)
        // Names are unique across groups, whatever their case.
        let names = setup.categories.map { $0.name.lowercased() }
        return Set(names).count == names.count ? made : nil
    }

    /// A viewer as this server writes it: one from before avatars leaves the field out.
    private static func told(_ profile: Profile, _ state: State) -> Profile {
        Profile(
            id: profile.id, name: profile.name, color: profile.color, avatar: state.knowsAvatars ? profile.avatar : nil,
            saysAvatar: state.knowsAvatars, kids: profile.kids, saysKids: profile.saysKids, skipping: profile.skipping)
    }

    private static func kids(_ json: Any?) -> KidsSettings? {
        guard let json = json as? [String: Any] else { return nil }
        func ids(_ key: String) -> [String] { json[key] as? [String] ?? [] }
        return KidsSettings(
            allowedGroupIds: ids("allowedGroupIds"), allowedCategoryIds: ids("allowedCategoryIds"),
            allowedItemIds: ids("allowedItemIds"), blockedItemIds: ids("blockedItemIds"),
            blockedCategoryIds: ids("blockedCategoryIds"), knowsBlockedCategories: json["blockedCategoryIds"] != nil)
    }

    private struct Grant: Encodable {
        var status: String?
        var device: Device
        var token: String
    }

    private struct Devices: Encodable {
        var devices: [Device]
        var currentDeviceId: String
    }

    private struct Whoami: Encodable {
        var device: Device
        var server: ServerInfo
        var household: HouseholdSummary?
    }

    private struct Progresses: Encodable {
        var progress: [PlaybackProgress]
        var revision: Int
    }

    private struct Profiles: Encodable {
        var profiles: [Profile]
    }

    private struct Accepted: Encodable {
        var progress: PlaybackProgress
    }
}

/// The app's surroundings for one test: real stores on files in a temporary folder, a real
/// client on the stubbed network, credentials in memory, preferences in a suite of their own.
@MainActor
final class TestApp {
    let household: Household
    var environment: AppEnvironment
    let credentials = InMemoryCredentialStore()
    private let directory: TemporaryDirectory
    private let suite: String

    init(_ household: Household = Household()) throws {
        self.household = household
        directory = try TemporaryDirectory()
        suite = "mt.sil.lobby.tests.\(UUID().uuidString)"
        environment = AppEnvironment(
            catalogueStore: CatalogueStore(fileURL: LobbyStorage.catalogueFile(in: directory.url)),
            categoryGroupsStore: CategoryGroupsStore(fileURL: LobbyStorage.categoriesFile(in: directory.url)),
            popularStore: PopularStore(fileURL: LobbyStorage.popularFile(in: directory.url)),
            progressStore: ProgressStore(fileURL: LobbyStorage.progressFile(in: directory.url)),
            credentials: credentials,
            preferences: ConnectionPreferences(suiteName: suite),
            settings: LocalSettings(suiteName: suite),
            artwork: ArtworkLoader(
                directory: directory.url.appending(path: "Artwork", directoryHint: .isDirectory),
                keptDirectory: directory.url.appending(path: "DownloadArtwork", directoryHint: .isDirectory),
                session: household.stub.session),
            downloads: DownloadManager(
                directory: LobbyStorage.downloadsDirectory(in: directory.url),
                sessionConfiguration: household.stub.configuration,
                sleep: { _ in
                    try Task.checkCancellation()
                    await Task.yield()
                },
                availableSpace: { _ in household.current.freeBytes },
                spaceReserveBytes: 0),
            session: household.stub.session,
            device: DeviceIdentity(name: "Test iPhone", platform: .ios),
            capabilities: DeviceCapabilities(hardwareAV1Decode: false),
            // The home address always gets its say: here it answers or fails at once, and the
            // choice is made then. This wait is never sat out; it ends when the choice is made.
            locateGrace: { try? await Task.sleep(for: .seconds(3600)) },
            // No waiting in tests: a poll hands over to whatever else is ready and goes again.
            sleep: { _ in
                try Task.checkCancellation()
                await Task.yield()
            })
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    /// A new app model on the same stored state, as after quitting and opening the app.
    func launch() -> AppModel {
        AppModel(environment: environment)
    }

    /// An app that paired earlier: the credential and the connection are stored.
    func launchPaired(as profileID: String? = nil) async throws -> AppModel {
        let state = household.current
        await credentials.setToken("device-token", forServer: state.server.id)
        environment.preferences.connection = SavedConnection(
            serverAddress: household.stub.baseURL, serverID: state.server.id, serverName: state.server.name,
            deviceID: state.device.id)
        if let profileID {
            environment.preferences.activeProfileID = profileID
            environment.settings.profiles = state.profiles
        }
        let app = launch()
        await app.start()
        return app
    }
}

/// Builders for catalogues.
enum Make {
    static let epoch = Date(millisecondsSince1970: 1_795_530_000_000)

    static func file(
        _ playability: Playability = .direct, container: String = "mp4", codec: String = "h264",
        durationMs: Int? = 6_000_000, available: Bool = true, reason: String? = nil, startMs: Int? = nil,
        endMs: Int? = nil, assetID: String? = nil, sizeBytes: Int64 = 2_100_000_000, revision: String = "r1"
    ) -> MediaFile {
        MediaFile(
            assetId: assetID ?? "asset-\(container)-\(codec)", startMs: startMs, endMs: endMs, available: available,
            sizeBytes: sizeBytes, durationMs: durationMs, container: container, revision: revision,
            playability: playability, playabilityReason: reason,
            video: VideoTrack(codec: codec, width: 1920, height: 1080, bitDepth: 8))
    }

    /// A real JPEG, made here: the loader decodes what it gets.
    static func jpeg(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func movie(
        _ id: String, title: String? = nil, year: Int? = 2019, categories: [String] = ["Pixar"],
        files: [MediaFile] = [file()]
    ) -> Item {
        Item(id: id, kind: .movie, title: title ?? id, year: year, categories: categories, addedAt: epoch, files: files)
    }

    /// A show with one season per element of `episodesPerSeason`: ids "show", "show-s1", "show-s1e1", …
    static func show(_ id: String, title: String, episodesPerSeason: [Int], file: MediaFile = file(durationMs: 1_200_000)) -> [Item] {
        var items = [Item(id: id, kind: .show, title: title, categories: ["Series"], addedAt: epoch)]
        for (index, count) in episodesPerSeason.enumerated() {
            let season = index + 1
            items.append(Item(
                id: "\(id)-s\(season)", kind: .season, parentId: id, title: "Season \(season)", seasonNumber: season,
                addedAt: epoch))
            for episode in 1...max(1, count) where count > 0 {
                items.append(Item(
                    id: "\(id)-s\(season)e\(episode)", kind: .episode, parentId: "\(id)-s\(season)",
                    title: "Chapter \(episode)", seasonNumber: season, episodeNumber: episode, addedAt: epoch,
                    files: [file]))
            }
        }
        return items
    }

    static func progress(_ itemID: String, positionMs: Int, durationMs: Int? = 6_000_000, completed: Bool = false, minutesAgo: Int = 0) -> PlaybackProgress {
        PlaybackProgress(
            itemId: itemID, positionMs: positionMs, durationMs: durationMs, completed: completed, revision: 1,
            updatedAt: epoch.addingTimeInterval(TimeInterval(-minutesAgo * 60)))
    }

    static let context = PlaybackContext(capabilities: DeviceCapabilities(hardwareAV1Decode: false))
}
