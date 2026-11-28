// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// One stretch of a day on the week grid: from, to (minutes of the day), and its mode.
struct KidsWeekSegment: Hashable, Sendable {
    var start: Int
    var end: Int
    var mode: KidsMode
    /// The block it comes from; nil for the default mode.
    var blockIndex: Int?
}

/// The week of a plan as the grid draws it, and the presets.
enum KidsWeek {
    /// Monday to Sunday, as the plan counts them.
    static let days = Array(1...7)

    static func dayName(_ day: Int, calendar: Calendar = .current) -> String {
        // Calendar counts from Sunday = 1.
        let index = day % 7
        return calendar.shortWeekdaySymbols[index]
    }

    /// The stretches of one weekday: the default mode, with the blocks that hold then on top,
    /// the strictest where they overlap. A block into the next day shows its morning there.
    static func segments(of plan: KidsPlan, day: Int) -> [KidsWeekSegment] {
        var edges: Set<Int> = [0, 1440]
        for block in plan.blocks {
            edges.insert(KidsPlanResolver.minutes(block.start))
            let end = KidsPlanResolver.minutes(block.end)
            edges.insert(end == 0 ? 1440 : end)
        }
        let sorted = edges.sorted()
        var segments: [KidsWeekSegment] = []
        for (start, end) in zip(sorted, sorted.dropFirst()) where end > start {
            var mode = plan.defaultMode
            var index: Int?
            for (i, block) in plan.blocks.enumerated() where KidsPlanResolver.holds(block, weekday: day, minute: start) {
                if index.map({ block.mode.strictness > plan.blocks[$0].mode.strictness }) ?? true { index = i }
                mode = mode.stricter(block.mode)
            }
            if let last = segments.last, last.mode == mode, last.blockIndex == index {
                segments[segments.count - 1].end = end
            } else {
                segments.append(KidsWeekSegment(start: start, end: end, mode: mode, blockIndex: index))
            }
        }
        return segments
    }

    static let schoolDays = KidsPlanBlock(days: [1, 2, 3, 4, 5], start: "08:00", end: "15:00", mode: .nothing, label: "School")
    static let bedtime = KidsPlanBlock(days: Array(1...7), start: "19:30", end: "07:00", mode: .listening, label: "Bedtime")

    /// Adds a preset, or puts it back as it was when a block of that name is there.
    static func applying(_ preset: KidsPlanBlock, to plan: KidsPlan) -> KidsPlan {
        var plan = plan
        if let index = plan.blocks.firstIndex(where: { $0.label == preset.label }) {
            plan.blocks[index] = preset
        } else {
            plan.blocks.append(preset)
        }
        return plan
    }

    /// "HH:MM" from minutes of the day.
    static func time(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

/// What the kids screens and the grown-ups' sheets say about asking and answering.
enum KidsAskText {
    /// "Asking Dad…", "Asking Mum and Dad…", "Asking Mum, Dad and Gran…".
    static func asking(_ names: [String]) -> String {
        let names = names.filter { !$0.isEmpty }
        guard let last = names.last else { return "Asking a grown-up…" }
        if names.count == 1 { return "Asking \(last)…" }
        return "Asking \(names.dropLast().joined(separator: ", ")) and \(last)…"
    }

    /// "Answered by Dad — Watch for 1 h", "Answered by Mum — Listen until 19:30", "Answered by Dad — Not now".
    static func answered(_ request: KidsRequest, now: Date = Date()) -> String {
        let who = request.answeredByName.map { "Answered by \($0)" } ?? "Answered"
        guard request.state == .allowed, let grant = request.grant else {
            return request.state == .declined ? "\(who) — Not now" : who
        }
        let what = grant.mode == .everything ? "Watch" : "Listen"
        let until = Date(millisecondsSince1970: grant.until)
        let minutes = Int((until.timeIntervalSince(Date(millisecondsSince1970: request.answeredAt ?? now.millisecondsSince1970)) / 60).rounded())
        if minutes > 0, minutes % 60 == 0, minutes <= 180 { return "\(who) — \(what) for \(minutes / 60) h" }
        if minutes > 0, minutes < 60 { return "\(who) — \(what) for \(minutes) min" }
        return "\(who) — \(what) until \(until.formatted(date: .omitted, time: .shortened))"
    }
}

/// What a new kids viewer sees to begin with: the household's kids part, when there is one.
enum KidsSetup {
    static func defaultLimits(for groups: CategoryGroups) -> KidsSettings {
        let kids = groups.groups.filter { ($0.name ?? "").localizedCaseInsensitiveContains("kid") }
        return KidsSettings(allowedGroupIds: kids.map(\.id))
    }
}

/// The lengths a grown-up picks for an override or an answer. Nil: the usual (until the next
/// switch today, else an hour).
struct KidsLengthChoice: Hashable, Identifiable {
    var title: String
    var length: KidsLength?
    var id: String { title }

    static let choices: [KidsLengthChoice] = [
        KidsLengthChoice(title: "Until the next switch", length: .nextSwitch),
        KidsLengthChoice(title: "30 minutes", length: .minutes(30)),
        KidsLengthChoice(title: "1 hour", length: .minutes(60)),
        KidsLengthChoice(title: "2 hours", length: .minutes(120)),
    ]
}

/// A grown-up's "When and what" page for one kids viewer: the plan as it is being changed, and
/// the buttons that act at once.
@MainActor
@Observable
final class KidsPlanEditor {
    let profileID: String
    private(set) var view: KidsPlanView?
    /// What is changed here, sent with Save.
    var plan = KidsPlan.none
    private(set) var isSaving = false
    var problem: String?
    private let app: AppModel

    init(app: AppModel, profileID: String) {
        self.app = app
        self.profileID = profileID
    }

    var hasChanges: Bool { view.map { $0.plan != plan } ?? false }

    func load() async {
        guard let client = app.liveClient else { return problem = "The server cannot be reached right now." }
        await run { try await client.kidsPlan(profileID: self.profileID) }
    }

    func save() async {
        guard let client = app.liveClient else { return }
        isSaving = true
        defer { isSaving = false }
        let plan = plan
        await run { try await client.setKidsPlan(plan, profileID: self.profileID) }
    }

    func override(_ mode: KidsMode, length: KidsLength?) async {
        guard let client = app.liveClient else { return }
        await run(keepingPlan: true) { try await client.setKidsOverride(mode, length: length, profileID: self.profileID) }
    }

    func endOverride() async {
        guard let client = app.liveClient else { return }
        await run(keepingPlan: true) { try await client.endKidsOverride(profileID: self.profileID) }
    }

    func switchAnswer(to answer: KidsAnswer) async {
        guard let client = app.liveClient else { return }
        await run(keepingPlan: true) { try await client.switchKidsAnswer(answer, profileID: self.profileID) }
    }

    func endAnswer() async {
        guard let client = app.liveClient else { return }
        await run(keepingPlan: true) { try await client.endKidsAnswer(profileID: self.profileID) }
    }

    /// The quick switch for one of the child's devices. What the saved plan says is sent as
    /// "as the plan says", so that the device follows the plan again from then on.
    func setLock(_ locked: Bool, device deviceID: String) async {
        guard let client = app.liveClient else { return }
        let choice: Bool? = locked == view?.plan.lockToLobby ? nil : locked
        await run(keepingPlan: true) { try await client.setKidsLock(choice, deviceID: deviceID, profileID: self.profileID) }
    }

    // MARK: Changing the plan here

    func apply(_ preset: KidsPlanBlock) { plan = KidsWeek.applying(preset, to: plan) }

    func remove(block index: Int) {
        guard plan.blocks.indices.contains(index) else { return }
        plan.blocks.remove(at: index)
    }

    /// Whether this grown-up is asked: everyone is while nobody was chosen.
    func isAsked(_ profileID: String) -> Bool {
        plan.askers.isEmpty || plan.askers.contains { $0.profileId == profileID }
    }

    /// Chooses whether a grown-up is asked, on these devices of theirs.
    func setAsked(_ asked: Bool, profileID: String, deviceIDs: [String]) {
        if plan.askers.isEmpty, let view {
            // From everyone to a choice: all the others stay asked.
            plan.askers = view.grownUps.map { KidsAsker(profileId: $0.profileId, deviceIds: view.adminDevices.map(\.id)) }
        }
        plan.askers.removeAll { $0.profileId == profileID }
        if asked { plan.askers.append(KidsAsker(profileId: profileID, deviceIds: deviceIDs)) }
    }

    func setDevice(_ deviceID: String, asked: Bool, for profileID: String) {
        guard let index = plan.askers.firstIndex(where: { $0.profileId == profileID }) else { return }
        plan.askers[index].deviceIds.removeAll { $0 == deviceID }
        if asked { plan.askers[index].deviceIds.append(deviceID) }
    }

    func hears(_ sourceID: String) -> Bool { plan.musicSourceIds?.contains(sourceID) ?? true }

    func setHears(_ hears: Bool, source sourceID: String) {
        var ids = plan.musicSourceIds ?? view?.musicLibraries.map(\.id) ?? []
        ids.removeAll { $0 == sourceID }
        if hears { ids.append(sourceID) }
        let all = Set(view?.musicLibraries.map(\.id) ?? [])
        plan.musicSourceIds = Set(ids) == all ? nil : ids
    }

    private func run(keepingPlan: Bool = false, _ work: @escaping () async throws -> KidsPlanView) async {
        do {
            let answer = try await work()
            let edited = plan
            let wasChanged = hasChanges
            view = answer
            plan = keepingPlan && wasChanged ? edited : answer.plan
        } catch {
            problem = error.localizedDescription
        }
    }
}
