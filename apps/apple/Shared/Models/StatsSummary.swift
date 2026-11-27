// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// One summary card on a statistics page: a big number and what it is.
struct StatsCard: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var value: String
    var detail: String?
    var symbol: String
}

/// One bar of the chart of time: a day, or a month for a long range.
struct StatsBar: Identifiable, Hashable, Sendable {
    var id: String
    var date: Date
    var watchedHours: Double
    var listenedHours: Double
}

/// One cell of the week by hour.
struct StatsHeatCell: Identifiable, Hashable, Sendable {
    /// Monday is 0.
    var weekday: Int
    var hour: Int
    var minutes: Double
    var id: Int { weekday * 24 + hour }
}

/// What a statistics page says, worked out from the server's answer. No state: easy to test.
enum StatsSummary {
    static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    static let shortWeekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// "Your Month in Lobby", or the same for someone else.
    static func headline(_ range: StatsRange, name: String? = nil) -> String {
        let whose = name.map { "\($0)’s" } ?? "Your"
        switch range {
        case .week: return "\(whose) Week in Lobby"
        case .month: return "\(whose) Month in Lobby"
        case .year: return "\(whose) Year in Lobby"
        case .all: return "\(whose) Lobby"
        }
    }

    static func rangeTitle(_ range: StatsRange) -> String {
        switch range {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .all: "All"
        }
    }

    /// "12 h 5 min", "45 min", "under a minute".
    static func duration(_ milliseconds: Int) -> String {
        let minutes = milliseconds / 60_000
        if minutes == 0 { return milliseconds > 0 ? "Under a minute" : "None" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(minutes) min" }
        if hours >= 100 || rest == 0 { return "\(hours) h" }
        return "\(hours) h \(rest) min"
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// "60%" of a part of a whole; nil without a whole.
    static func share(_ part: Int, of whole: Int) -> String? {
        guard whole > 0 else { return nil }
        return "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
    }

    /// A day of the page, `yyyy-MM-dd`, as noon of that day in its time zone.
    static func date(day: String, timeZone: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts.count > 2 ? parts[2] : 15, hour: 12))
    }

    /// Days for a week or a month; months for a year or longer.
    static func bars(days: [StatsDay], months: [StatsMonth], range: StatsPeriod) -> [StatsBar] {
        let hours = { (ms: Int?) in Double(ms ?? 0) / 3_600_000 }
        switch range.name {
        case .week, .month:
            return days.compactMap { day in
                date(day: day.day, timeZone: range.timeZone).map {
                    StatsBar(id: day.day, date: $0, watchedHours: hours(day.watchedMs), listenedHours: hours(day.listenedMs))
                }
            }
        case .year, .all:
            return months.compactMap { month in
                date(day: month.month, timeZone: range.timeZone).map {
                    StatsBar(id: month.month, date: $0, watchedHours: hours(month.watchedMs), listenedHours: hours(month.listenedMs))
                }
            }
        }
    }

    static func heatCells(_ heatmap: [[Int]]) -> [StatsHeatCell] {
        heatmap.enumerated().flatMap { weekday, hours in
            hours.enumerated().map { hour, ms in StatsHeatCell(weekday: weekday, hour: hour, minutes: Double(ms) / 60_000) }
        }
    }

    /// The weekday most is watched on, Monday 0; nil when nothing was.
    static func busiestWeekday(_ heatmap: [[Int]]) -> Int? {
        let totals = heatmap.map { $0.reduce(0, +) }
        guard let most = totals.max(), most > 0 else { return nil }
        return totals.firstIndex(of: most)
    }

    static func busiestHour(_ heatmap: [[Int]]) -> Int? {
        guard !heatmap.isEmpty else { return nil }
        let totals = (0..<24).map { hour in heatmap.reduce(0) { $0 + ($1.count > hour ? $1[hour] : 0) } }
        guard let most = totals.max(), most > 0 else { return nil }
        return totals.firstIndex(of: most)
    }

    /// "Evenings", the part of the day most is watched in.
    static func favouriteTime(_ when: StatsWhen) -> String? {
        let parts = [("Mornings", when.mornings), ("Afternoons", when.afternoons), ("Evenings", when.evenings), ("Nights", when.nights)]
        guard let most = parts.max(by: { $0.1 < $1.1 }), most.1 > 0 else { return nil }
        return most.0
    }

    /// "20:00", an hour of the day.
    static func hour(_ hour: Int) -> String { String(format: "%02d:00", hour) }

    /// The cards at the top of a viewer's page.
    static func cards(_ stats: ViewerStats) -> [StatsCard] {
        var cards = [
            StatsCard(
                id: "watched", title: "Watched", value: duration(stats.totals.watchedMs),
                detail: stats.totals.activeDays == 1 ? "On 1 day" : "On \(stats.totals.activeDays) days", symbol: "play.rectangle.fill"),
        ]
        if let top = stats.topTitles.first {
            cards.append(StatsCard(id: "top", title: "Most Watched", value: top.title, detail: duration(top.watchedMs), symbol: "star.fill"))
        }
        if stats.totals.filmsFinished > 0 || stats.totals.episodesFinished > 0 {
            let films = stats.totals.filmsFinished == 1 ? "1 film" : "\(stats.totals.filmsFinished) films"
            let episodes = stats.totals.episodesFinished == 1 ? "1 episode" : "\(stats.totals.episodesFinished) episodes"
            cards.append(StatsCard(id: "finished", title: "Finished", value: films, detail: episodes, symbol: "checkmark.circle.fill"))
        }
        if let weekday = busiestWeekday(stats.heatmap) {
            let time = favouriteTime(stats.when)
            cards.append(StatsCard(
                id: "when", title: "Mostly", value: "\(weekdays[weekday])s", detail: time.map { "\($0), around \(hour(busiestHour(stats.heatmap) ?? 20))" },
                symbol: "clock.fill"))
        }
        if stats.streak.current > 0 || stats.streak.longest > 1 {
            cards.append(StatsCard(
                id: "streak", title: "Streak", value: stats.streak.current == 1 ? "1 day" : "\(stats.streak.current) days",
                detail: "Longest \(stats.streak.longest) days", symbol: "flame.fill"))
        }
        if stats.music.listenedMs > 0 {
            cards.append(StatsCard(
                id: "music", title: "Listened", value: duration(stats.music.listenedMs),
                detail: stats.music.topAlbums.first.map { "Mostly \($0.title)" }, symbol: "music.note"))
        }
        return cards
    }

    /// The cards at the top of the server's page.
    static func cards(_ stats: ServerStats) -> [StatsCard] {
        let away = stats.traffic.awayBytes
        let sent = stats.traffic.homeBytes + away
        var cards = [
            StatsCard(
                id: "watched", title: "Watched", value: duration(stats.totals.watchedMs),
                detail: "\(stats.totals.sessions) sittings", symbol: "play.rectangle.fill"),
            StatsCard(
                id: "viewers", title: "Viewers", value: "\(stats.totals.viewers)",
                detail: "On \(stats.totals.devices) devices", symbol: "person.2.fill"),
            StatsCard(
                id: "sent", title: "Sent", value: bytes(sent),
                detail: share(away, of: sent).map { "\($0) away from home" }, symbol: "arrow.up.arrow.down"),
        ]
        // A household's overview has neither: they are the server's.
        if let preparations = stats.preparations, preparations.count > 0 {
            cards.append(StatsCard(
                id: "prepared", title: "Prepared", value: "\(preparations.count)",
                detail: "In \(duration(preparations.timeMs))", symbol: "gearshape.2.fill"))
        }
        if let conversions = stats.conversions, conversions.done > 0 || conversions.savedInAllBytes > 0 {
            cards.append(StatsCard(
                id: "converted", title: "Converted", value: "\(conversions.done)",
                detail: "\(bytes(conversions.savedBytes)) saved", symbol: "arrow.triangle.2.circlepath"))
        }
        if stats.playOn.sessions > 0 {
            cards.append(StatsCard(
                id: "playOn", title: "Play On", value: "\(stats.playOn.sessions)",
                detail: stats.playOn.targets.first.map { "Mostly \($0.name)" }, symbol: "tv.fill"))
        }
        return cards
    }

    /// How a sitting got here, in words: "Prepared · Away, direct".
    static func how(_ sitting: StatsSitting) -> String {
        let road: String? = switch sitting.road {
        case "home": "At home"
        case "tailnet": "Over Tailscale"
        case "relay": "Away"
        case "direct": "Away, direct"
        default: nil
        }
        let delivery: String? = switch sitting.delivery {
        case "direct": "As it is"
        case "prepared": "Prepared"
        case "download": "Downloaded"
        default: nil
        }
        let playOn = sitting.playOnFrom.map { "Sent from \($0)" }
        return [sitting.device, road, delivery, playOn].compactMap { $0 }.joined(separator: " · ")
    }

    /// The part of the roads that is away from home, by time watched.
    static func awayShare(_ roads: [String: Int]?) -> Double? {
        guard let roads else { return nil }
        let total = roads.values.reduce(0, +)
        guard total > 0 else { return nil }
        let home = roads["home"] ?? 0
        return Double(total - home) / Double(total)
    }
}
