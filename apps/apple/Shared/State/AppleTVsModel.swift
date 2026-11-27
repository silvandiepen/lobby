// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Observation

/// Settings → Server → Apple TVs, for a manager at home or over Tailscale: the Apple TVs Lobby
/// Server can turn on for Play On (docs/api.md, "Waking an Apple TV"), connecting one with
/// the code it shows, saying which Lobby device it is, and the switch for waking.
@MainActor
@Observable
final class AppleTVsModel {
    private(set) var status: WakeStatus?
    /// The household's Apple TVs as Lobby devices, to link a TV to.
    private(set) var devices: [Device] = []
    /// The server has no such thing: an older one.
    private(set) var isUnavailable = false
    private(set) var isWorking = false
    private(set) var isScanning = false
    /// A pairing that waits for the code the TV shows.
    private(set) var pairing: TelevisionPairing?
    var pin = ""
    var problem: String?

    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    var isConfigured: Bool { status?.configured ?? false }
    var isEnabled: Bool { status?.enabled ?? false }
    /// "Kids can turn on the TV": kids mode may wake a TV too. Off by default.
    var kidsMayWake: Bool { status?.kids ?? false }

    /// One line on how it is doing.
    var summary: String { Self.summary(status) }

    nonisolated static func summary(_ status: WakeStatus?) -> String {
        guard let status else { return "" }
        guard status.configured else {
            return "Not set up on Lobby Server. It needs pyatv and one line in lobby.config.json; docs/operations.md says how."
        }
        if !status.running {
            return status.problem.map { "Apple TVs cannot be reached now: \($0)." } ?? "Lobby Server is starting the helper for Apple TVs."
        }
        let connected = status.televisions.filter { $0.paired && $0.deviceId != nil }.count
        guard status.enabled else { return "Off. Play On does not turn Apple TVs on." }
        switch connected {
        case 0: return "On. No Apple TV is connected yet."
        case 1: return "On. Play On turns 1 Apple TV on."
        default: return "On. Play On turns \(connected) Apple TVs on."
        }
    }

    /// What a TV is, in a few words: "Connected as Living Room", "Not connected".
    /// - Parameter looked: the network was looked at, so `found` means something.
    nonisolated static func state(of tv: Television, devices: [Device], looked: Bool) -> String {
        let missing = looked && !tv.found ? ", not found in the last look" : ""
        guard tv.paired else { return "Not connected\(missing)" }
        guard let id = tv.deviceId else { return "Connected. Which Lobby device is it?" }
        let name = devices.first { $0.id == id }?.name ?? "a removed device"
        return "Connected as \(name)\(missing)"
    }

    /// The Lobby device it probably is, while none is confirmed.
    func suggestion(for tv: Television) -> Device? {
        guard tv.paired, tv.deviceId == nil, let id = tv.suggestedDeviceId else { return nil }
        return devices.first { $0.id == id }
    }

    func television(_ id: String) -> Television? { status?.televisions.first { $0.id == id } }

    // MARK: Loading

    func load() async {
        do {
            status = try await app.asManager { try await $0.wakeStatus() }
            isUnavailable = false
            await fetchDevices()
        } catch LobbyError.notFound {
            isUnavailable = true
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    /// Looks for TVs the first time the page opens, and keeps the helper's state current.
    func watch() async {
        await load()
        if isConfigured, status?.running == true, status?.scannedAt == nil { await scan() }
        while !Task.isCancelled {
            do { try await app.environment.sleep(.seconds(5)) } catch { return }
            guard app.isManager, !isUnavailable, !isWorking, !isScanning, pairing == nil else { continue }
            if let fresh = try? await app.asManager({ try await $0.wakeStatus() }) { status = fresh }
        }
    }

    private func fetchDevices() async {
        guard let list = try? await app.asManager({ try await $0.devices() }) else { return }
        devices = list.devices.filter { $0.platform == .tvos && $0.revokedAt == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Doing

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            status = try await app.asManager { try await $0.scanForTelevisions() }
            await fetchDevices()
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    func setEnabled(_ enabled: Bool) async {
        await perform {
            self.status = try await self.app.asManager { try await $0.setWake(enabled: enabled) }
        }
    }

    func setKidsMayWake(_ kids: Bool) async {
        await perform {
            self.status = try await self.app.asManager { try await $0.setKidsWake(kids) }
        }
    }

    /// The TV shows a code now.
    func connect(_ tv: Television) async {
        await perform {
            self.pin = ""
            self.pairing = try await self.app.asManager { try await $0.beginTelevisionPairing(televisionID: tv.id) }
        }
    }

    /// The code the TV shows. Links it to the Lobby device of the same name when there is one, which
    /// the manager then sees and can change.
    func submitPin() async {
        guard let pairing else { return }
        let code = pin.filter(\.isNumber)
        guard code.count == 4 else {
            problem = "The code is the four digits the Apple TV shows."
            return
        }
        await perform {
            defer { self.pairing = nil }
            _ = try await self.app.asManager { try await $0.finishTelevisionPairing(id: pairing.id, pin: code) }
            self.pin = ""
            self.status = try await self.app.asManager { try await $0.wakeStatus() }
        }
    }

    func cancelPairing() async {
        guard let pairing else { return }
        self.pairing = nil
        pin = ""
        _ = try? await app.asManager { try await $0.cancelTelevisionPairing(id: pairing.id) }
    }

    /// A manager's confirmation of which Lobby device the TV is.
    func link(_ tv: Television, to deviceID: String?) async {
        await perform {
            _ = try await self.app.asManager { try await $0.linkTelevision(id: tv.id, deviceID: deviceID) }
            self.status = try await self.app.asManager { try await $0.wakeStatus() }
        }
    }

    func disconnect(_ tv: Television) async {
        await perform {
            try await self.app.asManager { try await $0.disconnectTelevision(id: tv.id) }
            self.status = try await self.app.asManager { try await $0.wakeStatus() }
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
