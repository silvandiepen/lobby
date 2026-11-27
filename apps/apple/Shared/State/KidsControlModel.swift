// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// What a kids viewer's screens show, by what its plan allows now (docs/kids-control.md, §3).
enum KidsScreen: Hashable, Sendable {
    /// The kids screens as they are: watching and, with music on, listening.
    case open
    /// Ask per title: looking and listening are free, a film's Play asks first.
    case askPerTitle
    /// Only listening: no films, no trailers, no Play On.
    case listening
    /// "Lobby is resting", and when it opens again.
    case resting(KidsResting)
    /// Ask to open: nothing of the library, only the question.
    case asking(KidsAsking)

    /// Video of the library may be seen at all.
    var showsFilms: Bool {
        switch self {
        case .open, .askPerTitle: true
        case .listening, .resting, .asking: false
        }
    }
}

extension KidsScreen {
    /// What the page says, in a child's words.
    var title: String {
        switch self {
        case .open, .askPerTitle: "Lobby"
        case .listening: "Time to listen"
        case .resting(let resting):
            switch resting.reason {
            case .place: resting.detail.map { "At \($0)" } ?? "Lobby is resting"
            case .screenTime: "That was all the watching for today"
            default: "Lobby is resting"
            }
        case .asking(let asking):
            switch asking {
            case .sending, .waiting: "Asking a grown-up…"
            case .declined: "Not now"
            case .noAnswer: "No answer yet"
            case .offline: "Lobby needs the internet to ask"
            }
        }
    }

    func line(now: Date, calendar: Calendar = .current) -> String {
        switch self {
        case .open, .askPerTitle: return ""
        case .listening: return "Films and series come back later."
        case .resting(let resting):
            if resting.reason == .place { return "Lobby is resting here." + (Self.back(resting.until, now: now, calendar: calendar).map { " \($0)" } ?? "") }
            return Self.back(resting.until, now: now, calendar: calendar) ?? "See you later!"
        case .asking(let asking):
            switch asking {
            case .sending, .waiting: return "They get a message and can say yes."
            case .declined: return "Maybe later!"
            case .noAnswer: return "Try again in a little while."
            case .offline: return "Try again when Lobby can reach home."
            }
        }
    }

    /// "Back at 15:00", "Back tomorrow at 07:00", in the device's own way of writing times.
    static func back(_ until: Date?, now: Date, calendar: Calendar) -> String? {
        guard let until else { return nil }
        let time = until.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(until, inSameDayAs: now) { return "Back at \(time)." }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(until, inSameDayAs: tomorrow) {
            return "Back tomorrow at \(time)."
        }
        return "Back on \(until.formatted(.dateTime.weekday(.wide))) at \(time)."
    }
}

/// What the countdown before a switch says.
enum KidsCountdownText {
    static func text(left: TimeInterval, next: KidsModeAt?) -> String {
        let minutes = max(1, Int((left / 60).rounded(.up)))
        let unit = minutes == 1 ? "minute" : "minutes"
        if next?.isResting == false, next?.listening == true, next?.browse == false {
            return "Listening time in \(minutes) \(unit)"
        }
        return "Lobby rests in \(minutes) \(unit)"
    }
}

struct KidsResting: Hashable, Sendable {
    var reason: KidsReason
    /// The block's label or the place's name.
    var detail: String?
    /// When the app opens again; nil when not known within a week, or offline.
    var until: Date?
}

enum KidsAsking: Hashable, Sendable {
    /// The question goes out.
    case sending
    case waiting(KidsRequest)
    /// "Not now".
    case declined
    /// Ten minutes without an answer, or too many questions: try again later.
    case noAnswer(retryAt: Date?)
    /// Without the server nobody can be asked.
    case offline
}

/// What the child is told once when a switch ended its film.
enum KidsNotice: String, Hashable, Identifiable, Sendable {
    case filmWaits

    var id: String { rawValue }
}

/// When and what of the kids viewer in front: what the server says, or offline what the signed
/// copy of the plan says; and, on a grown-up's device, the questions children ask.
@MainActor
@Observable
final class KidsControlModel {
    /// The last minutes before a switch, in which the kids screens count down.
    nonisolated static let countdown: TimeInterval = 5 * 60

    /// What the child may do now; nil while nothing is known (a server from before plans).
    private(set) var now: KidsNow?
    /// This device's latest question.
    private(set) var request: KidsRequest?
    private(set) var isOffline = false
    /// Too many questions: not before then.
    private(set) var retryAt: Date?
    /// On a grown-up's device: the questions that wait for an answer.
    private(set) var questions: [KidsRequest] = []
    /// Questions another grown-up answered just now: "Answered by Dad — Watch for 1 h".
    private(set) var answered: [KidsRequest] = []
    /// The child's plan as the server last said it.
    private(set) var plan: KidsPlan?
    /// Who is asked, by name.
    private(set) var askNames: [String] = []

    /// The places to watch on this device.
    var places: [KidsPlace] { plan?.places ?? cache.copy?.plan.places ?? [] }

    /// What the asking page says: "Asking Mum and Dad…".
    var askingText: String { KidsAskText.asking(askNames) }

    @ObservationIgnored private(set) var cache: KidsPlanCache
    @ObservationIgnored private let clock: any KidsClock
    @ObservationIgnored private let save: @Sendable (KidsPlanCache) -> Void

    init(cache: KidsPlanCache = KidsPlanCache(), clock: any KidsClock = SystemKidsClock(), save: @escaping @Sendable (KidsPlanCache) -> Void = { _ in }) {
        self.cache = cache
        self.clock = clock
        self.save = save
    }

    /// What the screens show now.
    var screen: KidsScreen { Self.screen(for: now, request: request, isOffline: isOffline, retryAt: retryAt) }

    static func screen(for now: KidsNow?, request: KidsRequest?, isOffline: Bool, retryAt: Date? = nil) -> KidsScreen {
        guard let now else { return .open }
        let at = now.at
        if at.waiting {
            if isOffline { return .asking(.offline) }
            if let retryAt { return .asking(.noAnswer(retryAt: retryAt)) }
            guard let request else { return .asking(.sending) }
            switch request.state {
            case .waiting: return .asking(.waiting(request))
            case .declined: return .asking(.declined)
            case .expired: return .asking(.noAnswer(retryAt: nil))
            case .allowed, .cancelled: return .asking(.sending)
            }
        }
        if at.isResting {
            return .resting(KidsResting(reason: at.reason, detail: at.detail, until: now.until.map(Date.init(millisecondsSince1970:))))
        }
        if !at.browse { return .listening }
        if at.video != .all { return .askPerTitle }
        return .open
    }

    /// Seconds to the next switch that allows less, in its last five minutes; nil otherwise.
    func countdown(at date: Date) -> TimeInterval? {
        guard let now, let until = now.until, let next = now.next,
            next.mode.strictness > now.at.mode.strictness || next.isResting && !now.at.isResting
        else { return nil }
        let left = Date(millisecondsSince1970: until).timeIntervalSince(date)
        return left > 0 && left <= Self.countdown ? left : nil
    }

    /// Whether video of this title may play now: the title itself or what it is part of.
    func allowsVideo(of itemIDs: [String]) -> Bool {
        guard let now else { return true }
        return now.at.allowsVideo(of: itemIDs)
    }

    // MARK: From the server

    /// What `GET /v1/me/kids` said. Its signed copy is kept for offline.
    func update(_ me: KidsMe, deviceID: String) {
        isOffline = false
        now = me.now
        plan = me.plan
        askNames = me.askNames
        if let request = me.request { self.request = request }
        do {
            try cache.accept(me, deviceID: deviceID, clock: clock)
            save(cache)
        } catch {
            // Not the server's, or not for this device: the copy kept so far stays.
        }
    }

    /// The live channel said what the child may do now.
    func heard(_ now: KidsNow) {
        isOffline = false
        let answerEnded = !(self.now?.at.waiting ?? false) && now.at.waiting
        self.now = now
        if answerEnded { request = nil }
    }

    /// The live channel said what came of a question (the child's), or of one asked (a grown-up's).
    func heard(_ request: KidsRequest, closed: Bool) {
        if request.viewer != nil || closed {
            // A grown-up's device: the questions waiting for it. The first answer counts: on the
            // others it shows who answered, for a moment, instead of the buttons.
            let wasAsked = questions.contains { $0.id == request.id }
            questions.removeAll { $0.id == request.id }
            if !closed, request.state == .waiting { questions.append(request) }
            if closed, wasAsked, request.state == .allowed || request.state == .declined {
                answered.removeAll { $0.id == request.id }
                answered.append(request)
                let id = request.id
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    self?.answered.removeAll { $0.id == id }
                }
            }
        }
        if request.id == self.request?.id || (self.request == nil && request.viewer == nil) {
            self.request = request
        }
    }

    /// Without the server: what the signed copy says, away, at the place this device says.
    func wentOffline(place: KidsPlaceReport = .unknown) {
        isOffline = true
        cache.note(clock)
        save(cache)
        now = cache.now(place: place, clock: clock)
    }

    /// Counts video that played on this device, for offline screen time.
    func watched(seconds: Double) {
        cache.addVideo(seconds: seconds, clock: clock)
        save(cache)
    }

    /// A viewer that is not a kids viewer any more, or a device that left the server.
    func reset() {
        now = nil
        request = nil
        retryAt = nil
        isOffline = false
    }

    // MARK: Asking

    /// Asks the grown-ups, when the screens are asking and nothing waits yet.
    func askIfNeeded(using client: LobbyClient, profileID: String?) async {
        guard case .asking(.sending) = screen else { return }
        await ask(.open, itemID: nil, using: client, profileID: profileID)
    }

    /// Try again, after no answer or "Not now".
    func askAgain(using client: LobbyClient, profileID: String?) async {
        if let retryAt, retryAt > Date() { return }
        retryAt = nil
        request = nil
        await ask(.open, itemID: nil, using: client, profileID: profileID)
    }

    /// "Ask to watch" for one title.
    func ask(_ kind: KidsRequestKind, itemID: String?, using client: LobbyClient, profileID: String?) async {
        do {
            request = try await client.askKids(kind, itemID: itemID, profileID: profileID)
        } catch let error as LobbyError {
            if case .rateLimited(_, let after) = error {
                retryAt = Date().addingTimeInterval(after ?? 60)
            }
        } catch {}
    }

    // MARK: Grown-ups

    /// Answers a child's question. The first answer counts: a later one only hears what came of it.
    @discardableResult
    func answer(_ id: String, _ answer: KidsAnswer, length: KidsLength? = nil, titleOnly: Bool? = nil, using client: LobbyClient) async
        -> KidsRequest?
    {
        defer { questions.removeAll { $0.id == id } }
        do {
            return try await client.answerKids(id, answer, length: length, titleOnly: titleOnly)
        } catch {
            // Answered by someone else first: the server says who, on the live channel.
            return nil
        }
    }

    /// The questions that wait, as the server knows them.
    func refreshQuestions(using client: LobbyClient) async {
        if let waiting = try? await client.waitingKidsRequests() { questions = waiting }
    }
}
