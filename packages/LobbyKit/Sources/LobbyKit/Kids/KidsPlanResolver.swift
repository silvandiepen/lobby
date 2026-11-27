// SPDX-License-Identifier: MPL-2.0
import Foundation

/// What a kids viewer's device knows besides the plan: where it is, what it watched, what a
/// grown-up said. The same as the server's `PlanContext` (`apps/server/src/kids/plan.ts`).
public struct KidsPlanContext: Sendable {
    public var timeZone: TimeZone
    /// Not on the home network. Offline counts as away.
    public var away: Bool
    public var place: KidsPlaceReport
    /// Seconds of video watched on a local day ("YYYY-MM-DD").
    public var videoSeconds: @Sendable (String) -> Double
    public var override: KidsOverride?
    public var grants: [KidsGrant]

    public init(
        timeZone: TimeZone, away: Bool, place: KidsPlaceReport, videoSeconds: @escaping @Sendable (String) -> Double = { _ in 0 },
        override: KidsOverride? = nil, grants: [KidsGrant] = []
    ) {
        self.timeZone = timeZone
        self.away = away
        self.place = place
        self.videoSeconds = videoSeconds
        self.override = override
        self.grants = grants
    }
}

/// The rule of `apps/server/src/kids/plan.ts`, for a device without the server: the mode at a
/// moment, and until when it holds. The two are tested against the same cases.
public enum KidsPlanResolver {
    private static let day: Int64 = 86_400_000
    private static let horizonDays = 8

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Minutes of "HH:MM".
    public static func minutes(_ time: String) -> Int {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }

    struct Local {
        /// 1 is Monday.
        var weekday: Int
        var minute: Int
        var day: String
    }

    static func local(_ timeZone: TimeZone, _ ms: Int64) -> Local {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let parts = calendar(timeZone).dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
        // Calendar counts from Sunday = 1.
        let weekday = ((parts.weekday ?? 2) + 5) % 7 + 1
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return Local(weekday: weekday, minute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0), day: day)
    }

    /// The local day, "YYYY-MM-DD".
    public static func localDay(_ timeZone: TimeZone, _ ms: Int64) -> String { local(timeZone, ms).day }

    /// Whether a block holds at this weekday (1 is Monday) and minute of the day.
    public static func holds(_ block: KidsPlanBlock, weekday: Int, minute: Int) -> Bool {
        let start = minutes(block.start)
        let end = minutes(block.end)
        if start < end { return block.days.contains(weekday) && minute >= start && minute < end }
        let previous = weekday == 1 ? 7 : weekday - 1
        return (block.days.contains(weekday) && minute >= start) || (block.days.contains(previous) && minute < end)
    }

    static func screenLimit(_ plan: KidsPlan, weekday: Int) -> Int? {
        guard let screenTime = plan.screenTime else { return nil }
        return weekday >= 6 ? screenTime.weekendMinutes : screenTime.weekdayMinutes
    }

    struct Source {
        var mode: KidsMode
        var reason: KidsReason
        var detail: String?
    }

    /// What the plan says at a moment, before any answer.
    static func planMode(_ plan: KidsPlan, _ context: KidsPlanContext, at ms: Int64) -> Source {
        if let override = context.override, override.until > ms {
            return Source(mode: override.mode, reason: .override)
        }
        let now = local(context.timeZone, ms)
        var source = Source(mode: plan.defaultMode, reason: .default)
        func consider(_ one: Source) {
            if one.mode.strictness > source.mode.strictness { source = one }
        }
        for block in plan.blocks where holds(block, weekday: now.weekday, minute: now.minute) {
            if source.reason == .default, block.mode == source.mode {
                source = Source(mode: block.mode, reason: .schedule, detail: block.label)
            } else {
                consider(Source(mode: block.mode, reason: .schedule, detail: block.label))
            }
        }
        if let away = plan.away, context.away { consider(Source(mode: away, reason: .away)) }
        if !plan.places.isEmpty {
            var inside: KidsPlace?
            if case .inside(let id) = context.place { inside = plan.places.first { $0.id == id } }
            if let inside {
                consider(Source(mode: inside.mode, reason: .place, detail: inside.name))
            } else if context.place != .outside {
                let unknown = plan.whenPlaceUnknown ?? plan.places.reduce(KidsMode.everything) { $0.stricter($1.mode) }
                consider(Source(mode: unknown, reason: .placeUnknown))
            }
        }
        if let screenTime = plan.screenTime, let limit = screenLimit(plan, weekday: now.weekday),
            context.videoSeconds(now.day) >= Double(limit * 60)
        {
            consider(Source(mode: screenTime.whenOut, reason: .screenTime))
        }
        return source
    }

    /// What a kids viewer may do at a moment.
    public static func modeAt(_ plan: KidsPlan, _ context: KidsPlanContext, at ms: Int64) -> KidsModeAt {
        let source = planMode(plan, context, at: ms)
        func make(browse: Bool, video: KidsVideo, listening: Bool, titles: [String] = [], waiting: Bool = false, grant: String? = nil)
            -> KidsModeAt
        {
            KidsModeAt(
                mode: source.mode, reason: source.reason, detail: source.detail, browse: browse, video: video, titles: titles,
                listening: listening, waiting: waiting, grantId: grant)
        }
        switch source.mode {
        case .everything: return make(browse: true, video: .all, listening: plan.music)
        case .listening: return make(browse: false, video: .none, listening: plan.music)
        case .nothing, .unknown: return make(browse: false, video: .none, listening: false)
        case .ask: break
        }
        let running = context.grants.filter { $0.until > ms }
        let app = running.filter { $0.itemId == nil }.max { ($0.at, $0.until) < ($1.at, $1.until) }
        if plan.askStyle == .open {
            guard let app else { return make(browse: false, video: .none, listening: false, waiting: true) }
            let watch = app.mode == .everything
            return make(browse: watch, video: watch ? .all : .none, listening: plan.music, grant: app.id)
        }
        if let app, app.mode == .everything {
            return make(browse: true, video: .all, listening: plan.music, grant: app.id)
        }
        let titles = running.filter { $0.itemId != nil && $0.mode == .everything }
        return make(
            browse: true, video: titles.isEmpty ? .none : .titles, listening: plan.music,
            titles: Array(Set(titles.compactMap(\.itemId))).sorted(), grant: titles.first?.id)
    }

    /// Every moment within the horizon at which what holds can change. More than are needed.
    static func candidates(_ plan: KidsPlan, _ context: KidsPlanContext, after ms: Int64) -> [Int64] {
        let calendar = calendar(context.timeZone)
        let now = Date(timeIntervalSince1970: Double(ms) / 1000)
        var edges: Set<Int> = [0]
        for block in plan.blocks {
            edges.insert(minutes(block.start))
            edges.insert(minutes(block.end) % 1440)
        }
        var found: Set<Int64> = []
        let today = calendar.startOfDay(for: now)
        var transitions: [Date] = []
        var cursor = now
        while let next = context.timeZone.nextDaylightSavingTimeTransition(after: cursor),
            next.timeIntervalSince(now) <= Double(horizonDays) * 86_400
        {
            transitions.append(next)
            cursor = next
        }
        for k in 0...horizonDays {
            guard let date = calendar.date(byAdding: .day, value: k, to: today) else { continue }
            for edge in edges {
                guard let at = calendar.date(bySettingHour: edge / 60, minute: edge % 60, second: 0, of: date) else { continue }
                found.insert(at.millisecondsSince1970)
                // Near a change of the clock, the same wall time can be an hour off.
                if transitions.contains(where: { abs($0.timeIntervalSince(at)) < 86_400 }) {
                    found.insert(at.millisecondsSince1970 + 3_600_000)
                    found.insert(at.millisecondsSince1970 - 3_600_000)
                }
            }
        }
        for transition in transitions { found.insert(transition.millisecondsSince1970) }
        if let override = context.override { found.insert(override.until) }
        for grant in context.grants { found.insert(grant.until) }
        let end = ms + Int64(horizonDays) * day
        return found.filter { $0 > ms && $0 <= end }.sorted()
    }

    /// What holds now, until when, and what comes then.
    public static func resolve(_ plan: KidsPlan, _ context: KidsPlanContext, at ms: Int64) -> KidsNow {
        let current = modeAt(plan, context, at: ms)
        let today = localDay(context.timeZone, ms)
        var later = context
        let watched = context.videoSeconds
        later.videoSeconds = { day in day == today ? watched(day) : 0 }
        var until: Int64?
        var next: KidsModeAt?
        for at in candidates(plan, context, after: ms) {
            let then = modeAt(plan, later, at: at)
            if !then.allowsSame(as: current) {
                until = at
                next = then
                break
            }
        }
        let weekday = local(context.timeZone, ms).weekday
        let screenTime = plan.screenTime.map { _ in
            KidsNow.ScreenTimeToday(
                day: today, limitMinutes: screenLimit(plan, weekday: weekday), usedSeconds: context.videoSeconds(today))
        }
        return KidsNow(at: current, until: until, next: next, screenTime: screenTime)
    }

    /// The one of two that allows less.
    public static func stricter(_ a: KidsModeAt, _ b: KidsModeAt) -> KidsModeAt {
        if a.mode.strictness != b.mode.strictness { return a.mode.strictness > b.mode.strictness ? a : b }
        func allowance(_ one: KidsModeAt) -> Int {
            (one.browse ? 1 : 0) + (one.listening ? 1 : 0) + (one.video == .all ? 2 : one.video == .titles ? 1 : 0)
                - (one.waiting ? 1 : 0)
        }
        return allowance(b) < allowance(a) ? b : a
    }
}
