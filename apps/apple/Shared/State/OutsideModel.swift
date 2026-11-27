// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyDirect
import LobbyKit
import Observation

/// Access from outside, for a manager at home or in the tailnet: the switch, how it is doing, letting
/// one new device in, and who was there. For a guest household's manager, who is always outside:
/// letting one more device of their household in, and who of it was there. The switch is the
/// server owner's.
@MainActor
@Observable
final class OutsideModel {
    private(set) var status: OutsideStatus?
    /// The server has no such thing, or it is not set up there.
    private(set) var isUnavailable = false
    private(set) var access: [AccessRow] = []
    /// Shown once, by the manager that opened it.
    private(set) var window: OutsideWindow?
    /// Those waiting at a guest household's window: its manager does not see the owner's status.
    private(set) var guestRequests: [OutsideStatus.Request] = []
    private(set) var isWorking = false
    /// "Apple TV was let in."
    private(set) var lastApproval: String?
    private(set) var handOver: HandOver = .none
    var problem: String?

    enum HandOver: Hashable, Sendable {
        case none
        case sending
        case sent
        case failed(String)
    }

    struct AccessRow: Hashable, Identifiable {
        var id: Int
        var title: String
        var caption: String
        var isRefusal: Bool
    }

    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    var isOn: Bool { status?.enabled ?? false }

    /// A household admin (of a guest household or the owner's): the window and who waits at it,
    /// no more. The switch and the server's status are a server admin's.
    var isGuest: Bool { !app.isOwnerManager }

    /// Who waits for this manager's yes.
    var requests: [OutsideStatus.Request] { isGuest ? guestRequests : status?.requests ?? [] }

    /// The code and where to ask, while the window is open.
    var invitation: PairingInvitation? {
        guard let window, status?.window != nil || status == nil, window.expiresAt > Date() else { return nil }
        return window.invitation
    }

    /// "Ready. 2 devices connected, 1 over the relay."
    var summary: String {
        guard let status else { return "" }
        guard status.enabled else { return "Off. Nothing can reach Lobby Server from outside." }
        guard let direct = status.direct else { return "On. The direct connection is not set up on the server." }
        if !direct.running {
            return Self.problem(of: status) ?? "Lobby Server is starting the direct connection."
        }
        if !direct.introducer {
            return Self.problem(of: status) ?? "The service that introduces devices cannot be reached."
        }
        let devices = direct.connections == 1 ? "1 device connected" : "\(direct.connections) devices connected"
        return "Ready. \(devices)\(direct.relayed == 0 ? "" : ", \(direct.relayed) over the relay")."
    }

    private static func problem(of status: OutsideStatus) -> String? {
        status.transports.compactMap(\.problem).first.map { "Something is wrong: \($0)." }
    }

    /// Keeps the page current while it is open.
    func watch() async {
        await refresh()
        while !Task.isCancelled {
            do { try await app.environment.sleep(.seconds(3)) } catch { return }
            guard app.isManager, !isUnavailable else { return }
            if isGuest {
                guard !isWorking, let fresh = try? await app.asManager({ try await $0.pendingOutsideRequests() }) else { continue }
                if fresh.isEmpty != guestRequests.isEmpty { await fetchAccess() }
                guestRequests = fresh
                continue
            }
            guard !isWorking, let fresh = try? await app.asManager({ try await $0.outsideStatus() }) else { continue }
            let hadRequests = status?.requests.isEmpty == false
            status = fresh
            if hadRequests != !fresh.requests.isEmpty { await fetchAccess() }
        }
    }

    func refresh() async {
        if isGuest {
            do {
                guestRequests = try await app.asManager { try await $0.pendingOutsideRequests() }
                await fetchAccess()
            } catch {
                problem = await app.managerProblem(error)
            }
            return
        }
        do {
            let fresh = try await app.asManager { try await $0.outsideStatus() }
            status = fresh
            isUnavailable = !fresh.configured
            if fresh.configured { await fetchAccess() }
        } catch LobbyError.notFound {
            isUnavailable = true
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    private func fetchAccess() async {
        guard let entries = try? await app.asManager({ try await $0.outsideAccess() }) else { return }
        let names = (try? await app.asManager { try await $0.devices() })?.devices ?? []
        access = entries.map { Self.row($0, names: names) }
    }

    static func row(_ entry: OutsideAccess, names: [Device]) -> AccessRow {
        let who = entry.deviceId.map { id in names.first { $0.id == id }?.name ?? "A removed device" } ?? "Nobody known"
        let what =
            switch entry.routeClass {
            case "stream": "Watched"
            case "playback", "subtitle": "Started a film"
            case "downloads": "Downloads"
            case "pairing": "Pairing"
            case "account", "library", "artwork", "progress": "Looked at the library"
            default: "Asked"
            }
        let outcome =
            switch entry.outcome {
            case "refused": "Refused"
            case "limited": "Held back"
            case "error": "Went wrong"
            default: what
            }
        let road = switch entry.transport {
        case "direct": "direct"
        case "relay": "relay"
        default: entry.transport
        }
        let when = entry.until.formatted(date: .abbreviated, time: .shortened)
        return AccessRow(
            id: entry.id, title: who, caption: [outcome, when, road, entry.address].compactMap { $0 }.joined(separator: " · "),
            isRefusal: entry.outcome == "refused")
    }

    func setOn(_ on: Bool) async {
        await perform {
            self.status = try await self.app.asManager { try await $0.setOutside(enabled: on) }
            if !on { self.window = nil }
        }
    }

    func openWindow() async {
        await perform {
            self.lastApproval = nil
            self.handOver = .none
            self.window = try await self.app.asManager { try await $0.openOutsideWindow() }
            try await self.look()
        }
    }

    /// What there is now: the owner's status, or who waits at a guest's window.
    private func look() async throws {
        if isGuest {
            guestRequests = try await app.asManager { try await $0.pendingOutsideRequests() }
        } else {
            status = try await app.asManager { try await $0.outsideStatus() }
        }
    }

    func closeWindow() async {
        await perform {
            try await self.app.asManager { try await $0.closeOutsideWindow() }
            self.window = nil
            try await self.look()
        }
    }

    /// The manager says that the digits are those on the new device's screen.
    func approve(_ request: OutsideStatus.Request) async {
        await perform {
            let approval = try await self.app.asManager {
                // A server admin's yes after its household admin's needs no digits: they compared them.
                try await $0.approveOutside(id: request.id, comparison: request.awaitsAdmin ? nil : request.comparison)
            }
            self.lastApproval =
                approval.awaitsAdmin == true
                ? "“\(approval.deviceName)” waits for the server owner to approve it too."
                : "“\(approval.deviceName)” was let in as \(ManagerModel.article(approval.access ?? .viewer))."
            if request.invited != true { self.window = nil }
            try await self.look()
        }
    }

    func refuse(_ request: OutsideStatus.Request) async {
        await perform {
            try await self.app.asManager { try await $0.refuseOutside(id: request.id) }
            try await self.look()
        }
    }

    /// The camera read what an Apple TV on this network shows.
    func send(to scanned: String) async {
        guard let invitation else { return }
        guard let target = HandOverTarget(link: scanned) else {
            handOver = .failed("That is not the code an Apple TV shows under “Pair From Outside”.")
            return
        }
        handOver = .sending
        do {
            try await target.send(invitation)
            handOver = .sent
        } catch {
            handOver = .failed("The Apple TV was not found. Is this device on the same network? Otherwise type the code on the Apple TV.")
        }
    }

    private func perform(_ work: @MainActor () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        problem = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            problem = await app.managerProblem(error)
        }
    }
}
