// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Observation

/// Settings → Server → Speakers, for a manager at home or over Tailscale: the HomePods and AirPlay
/// speakers Lobby Server finds on its network and plays to (docs/api.md, "Playing on a speaker"),
/// their names, which are hidden, a password for one that wants it, and the switch.
@MainActor
@Observable
final class SpeakersModel {
    private(set) var status: SpeakersStatus?
    /// The server has no such thing: an older one.
    private(set) var isUnavailable = false
    private(set) var isWorking = false
    private(set) var isScanning = false
    var problem: String?

    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    var isConfigured: Bool { status?.configured ?? false }
    var isEnabled: Bool { status?.enabled ?? false }
    var speakers: [ManagedSpeaker] { status?.speakers ?? [] }

    /// One line on how it is doing.
    var summary: String { Self.summary(status) }

    nonisolated static func summary(_ status: SpeakersStatus?) -> String {
        guard let status else { return "" }
        guard status.configured else {
            return "Not set up on Lobby Server. It uses the helper of the Apple TVs: pyatv and one line in lobby.config.json; docs/operations.md says how."
        }
        guard status.enabled else { return "Off. Play On does not offer speakers." }
        if !status.running {
            return status.problem.map { "Speakers cannot be reached now: \($0)." } ?? "Lobby Server is starting the helper."
        }
        let shown = status.speakers.filter { $0.found && !$0.hidden }.count
        switch shown {
        case 0: return "On. No speaker was found on the network yet."
        case 1: return "On. Play On offers 1 speaker for music and stories."
        default: return "On. Play On offers \(shown) speakers for music and stories."
        }
    }

    /// What a speaker is, in a few words.
    nonisolated static func state(of speaker: ManagedSpeaker) -> String {
        var parts: [String] = []
        if !speaker.found { parts.append("Not found in the last looks") }
        if speaker.hidden { parts.append("Hidden from Play On") }
        switch speaker.access {
        case .homeOnly: parts.append("Lets only people in its Home play")
        case .password: parts.append(speaker.hasPassword ? "Password kept" : "Needs its password")
        default: if speaker.hasPassword { parts.append("Password kept") }
        }
        if speaker.playing { parts.append("Playing") }
        if speaker.customName != nil { parts.append("Calls itself “\(speaker.foundName)”") }
        return parts.isEmpty ? (speaker.model.isEmpty ? "Ready" : speaker.model) : parts.joined(separator: " · ")
    }

    func speaker(_ id: String) -> ManagedSpeaker? { speakers.first { $0.id == id } }

    // MARK: Loading

    func load() async {
        do {
            status = try await app.asManager { try await $0.speakers() }
            isUnavailable = false
        } catch LobbyError.notFound {
            isUnavailable = true
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    /// Keeps the list current while the page is open; the server looks on the network by itself.
    func watch() async {
        await load()
        while !Task.isCancelled {
            do { try await app.environment.sleep(.seconds(5)) } catch { return }
            guard app.isManager, !isUnavailable, !isWorking, !isScanning else { continue }
            if let fresh = try? await app.asManager({ try await $0.speakers() }) { status = fresh }
        }
    }

    // MARK: Doing

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            status = try await app.asManager { try await $0.scanForSpeakers() }
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    func setEnabled(_ enabled: Bool) async {
        await perform {
            self.status = try await self.app.asManager { try await $0.setSpeakers(enabled: enabled) }
        }
    }

    /// A name of the household's own; empty gives it its own name again.
    func rename(_ speaker: ManagedSpeaker, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted: String? = trimmed.isEmpty || trimmed == speaker.foundName ? nil : String(trimmed.prefix(60))
        guard wanted != speaker.customName else { return }
        await perform {
            self.replace(try await self.app.asManager { try await $0.renameSpeaker(id: speaker.id, name: wanted) })
        }
    }

    func setHidden(_ speaker: ManagedSpeaker, _ hidden: Bool) async {
        await perform {
            self.replace(try await self.app.asManager { try await $0.hideSpeaker(id: speaker.id, hidden: hidden) })
        }
    }

    /// Kept in pyatv's file on the server; empty removes it.
    func setPassword(_ speaker: ManagedSpeaker, _ password: String) async {
        let value: String? = password.isEmpty ? nil : password
        await perform {
            self.replace(try await self.app.asManager { try await $0.setSpeakerPassword(id: speaker.id, password: value) })
        }
    }

    private func replace(_ speaker: ManagedSpeaker) {
        guard var status, let index = status.speakers.firstIndex(where: { $0.id == speaker.id }) else { return }
        status.speakers[index] = speaker
        self.status = status
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
