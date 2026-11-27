// SPDX-License-Identifier: MPL-2.0
import Charts
import LobbyKit
import SwiftUI

/// Settings → Server → Statistics: what the whole server does, for its admins. Other
/// households are totals here until one is opened. With `.household`, a household's overview for
/// its admins: the same page, of that household's watching only, without the server's parts.
struct ServerStatsView: View {
    @State private var model: ServerStatsModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(app: AppModel, scope: ServerStatsModel.Scope = .server) {
        _model = State(initialValue: ServerStatsModel(app: app, scope: scope))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Space.xl) {
                header
                if let stats = model.stats {
                    StatsCardGrid(cards: model.cards)
                    StatsPanel(title: "Watched per Day", note: "\(stats.totals.sessions) sittings") {
                        StatsTimeChart(bars: model.bars, byMonth: false, showsListening: false)
                    }
                    StatsPanel(title: "Busiest Hours") { StatsHeatmap(cells: model.heat) }
                    if !stats.topTitles.isEmpty { topTitles(stats) }
                    grid {
                        if !stats.viewers.isEmpty { viewers(stats) }
                        if !stats.devices.isEmpty { devices(stats) }
                        if let households = stats.households { self.households(households) }
                        roads(stats)
                    }
                    traffic(stats)
                    grid {
                        if let preparations = stats.preparations, let conversions = stats.conversions {
                            work(preparations, conversions)
                        }
                        if let library = stats.library { self.library(library, timeZone: stats.range.timeZone) }
                        if stats.playOn.sessions > 0 { playOn(stats) }
                        if let storage = stats.storage { self.storage(storage) }
                    }
                    Text(model.scope == .server
                        ? "Kept for \(stats.keptDays) days (Server Settings, General)."
                        : "Lobby Server keeps this for \(stats.keptDays) days.")
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                } else if model.isUnavailable {
                    ContentUnavailableView(
                        "Not on this server yet", systemImage: "chart.bar",
                        description: Text("Lobby Server shows statistics from a newer version on."))
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.vertical, AppTheme.Space.l)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .artworkBackground(model.artworks)
        .navigationTitle(model.scope == .server ? "Statistics" : "Household Statistics")
        .task { await model.load() }
        .refreshable { await model.load() }
        .alert(
            "That did not work",
            isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
        .accessibilityIdentifier("stats.server")
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let columns = sizeClass == .compact ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Space.m, content: content)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.m) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            HStack {
                StatsRangePicker(selection: model.range) { range in Task { await model.select(range) } }
                if model.householdID != nil {
                    Button("Back to Yours") { Task { await model.open(household: nil) } }
                        .buttonStyle(.lobbyText)
                }
            }
        }
    }

    private var title: String {
        switch model.scope {
        case .server: model.stats?.household.map { "\($0.name) on This Server" } ?? "This Server"
        case .household: model.stats?.household.map(\.name) ?? "Your Household"
        }
    }

    private func topTitles(_ stats: ServerStats) -> some View {
        StatsPanel(title: "Most Watched", note: "By how many viewers") {
            let most = stats.topTitles.first?.watchedMs ?? 1
            ForEach(stats.topTitles) { title in
                StatsTitleRow(
                    title: title, most: most,
                    detail: "\(title.viewers ?? 0) viewers · \(StatsSummary.duration(title.watchedMs))")
            }
        }
    }

    private func viewers(_ stats: ServerStats) -> some View {
        StatsPanel(title: "Viewers") {
            ForEach(stats.viewers) { viewer in
                if model.opens(viewer) {
                    NavigationLink(value: Route.viewerStats(viewer.id)) {
                        HStack {
                            viewerRow(viewer)
                            Spacer()
                            Image(systemName: "chevron.forward").foregroundStyle(.lobbySecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("stats.viewer.\(viewer.id)")
                } else {
                    viewerRow(viewer)
                }
            }
        }
    }

    private func viewerRow(_ viewer: ServerStatsViewer) -> some View {
        HStack(spacing: AppTheme.Space.m) {
            ProfileAvatar(name: viewer.name, color: viewer.color ?? "blue", avatar: viewer.avatar, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewer.name).font(.headline)
                Text("\(StatsSummary.duration(viewer.watchedMs)) · last \(viewer.lastAt.formatted(.relative(presentation: .named)))")
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func devices(_ stats: ServerStats) -> some View {
        StatsPanel(title: "Devices") {
            StatsSplitChart(parts: stats.devices.map { ($0.name, $0.watchedMs) })
            ForEach(stats.devices.prefix(5)) { device in
                LabeledContent(device.name, value: StatsSummary.duration(device.watchedMs))
                    .font(.subheadline)
            }
        }
    }

    private func households(_ households: [ServerStatsHousehold]) -> some View {
        StatsPanel(title: "Households", note: "Others as totals: open one to see its viewers") {
            ForEach(households) { household in
                Button {
                    Task { await model.open(household: household.owner ? nil : household.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(household.name).font(.headline)
                            Text("\(household.viewers) viewers · \(StatsSummary.duration(household.watchedMs)) · \(StatsSummary.bytes(household.bytesSent))")
                                .font(.footnote)
                                .foregroundStyle(.lobbySecondary)
                        }
                        Spacer()
                        if !household.owner { Image(systemName: "chevron.forward").foregroundStyle(.lobbySecondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("stats.household.\(household.id)")
            }
        }
    }

    private func roads(_ stats: ServerStats) -> some View {
        StatsPanel(title: "Where", note: StatsSummary.awayShare(stats.roads).map { "\(Int(($0 * 100).rounded()))% away from home" }) {
            StatsSplitChart(parts: [
                ("At home", stats.roads["home"] ?? 0), ("Tailscale", stats.roads["tailnet"] ?? 0),
                ("Relay", stats.roads["relay"] ?? 0), ("Direct", stats.roads["direct"] ?? 0),
                ("Unknown", stats.roads["unknown"] ?? 0),
            ])
            let total = stats.deliveries.values.reduce(0, +)
            Text([
                StatsSummary.share(stats.deliveries["direct"] ?? 0, of: total).map { "\($0) as it is" },
                StatsSummary.share(stats.deliveries["prepared"] ?? 0, of: total).map { "\($0) prepared" },
                StatsSummary.share(stats.deliveries["download"] ?? 0, of: total).map { "\($0) downloaded" },
            ].compactMap { $0 }.joined(separator: " · "))
            .font(.footnote)
            .foregroundStyle(.lobbySecondary)
        }
    }

    private func traffic(_ stats: ServerStats) -> some View {
        StatsPanel(
            title: "Data Sent",
            note: "\(StatsSummary.bytes(stats.traffic.homeBytes)) at home, \(StatsSummary.bytes(stats.traffic.awayBytes)) away"
        ) {
            Chart(stats.traffic.days) { day in
                if let date = StatsSummary.date(day: day.day, timeZone: stats.range.timeZone) {
                    BarMark(x: .value("Day", date, unit: .day), y: .value("GB", Double(day.homeBytes) / 1e9))
                        .foregroundStyle(by: .value("Where", "At home"))
                    BarMark(x: .value("Day", date, unit: .day), y: .value("GB", Double(day.awayBytes) / 1e9))
                        .foregroundStyle(by: .value("Where", "Away"))
                }
            }
            .chartForegroundStyleScale(["At home": Color.orange, "Away": Color.blue])
            .chartYAxisLabel("GB")
            .frame(height: 160)
        }
    }

    private func work(_ preparations: StatsPreparations, _ conversions: StatsConversions) -> some View {
        StatsPanel(title: "Preparing and Converting") {
            LabeledContent("Prepared for playing", value: "\(preparations.count)")
            LabeledContent("Of them converted", value: "\(preparations.converted)")
            LabeledContent("Prepared ahead", value: "\(preparations.ahead)")
            LabeledContent("Time preparing", value: StatsSummary.duration(preparations.timeMs))
            LabeledContent("Files converted", value: "\(conversions.done)")
            LabeledContent("Time converting", value: StatsSummary.duration(conversions.timeMs))
            LabeledContent("Space saved", value: StatsSummary.bytes(conversions.savedBytes))
            if conversions.waiting > 0 || conversions.failed > 0 {
                LabeledContent("Waiting · failed", value: "\(conversions.waiting) · \(conversions.failed)")
            }
        }
        .font(.subheadline)
    }

    private func library(_ library: StatsLibrary, timeZone: String) -> some View {
        StatsPanel(title: "Library", note: "\(library.films) films, \(library.shows) series, \(library.episodes) episodes") {
            Chart(library.months) { month in
                if let date = StatsSummary.date(day: month.month, timeZone: timeZone) {
                    BarMark(x: .value("Month", date, unit: .month), y: .value("Added", month.films))
                        .foregroundStyle(by: .value("What", "Films"))
                    BarMark(x: .value("Month", date, unit: .month), y: .value("Added", month.episodes))
                        .foregroundStyle(by: .value("What", "Episodes"))
                }
            }
            .chartForegroundStyleScale(["Films": Color.orange, "Episodes": Color.purple])
            .frame(height: 150)
        }
    }

    private func playOn(_ stats: ServerStats) -> some View {
        StatsPanel(title: "Play On", note: "\(stats.playOn.sessions) times, \(StatsSummary.duration(stats.playOn.watchedMs))") {
            ForEach(stats.playOn.targets) { target in
                LabeledContent(target.name, value: "\(target.sessions)")
                    .font(.subheadline)
            }
        }
    }

    private func storage(_ storage: StatsStorage) -> some View {
        StatsPanel(title: "Storage") {
            if let fill = model.cacheFill, let used = storage.playbackCacheBytes {
                Gauge(value: fill) {
                    Text("Prepared copies")
                } currentValueLabel: {
                    Text(StatsSummary.bytes(used))
                }
                .tint(.orange)
            }
            if let music = storage.musicCacheBytes {
                LabeledContent("Music copies", value: StatsSummary.bytes(music))
            }
            if let database = storage.databaseBytes {
                LabeledContent("Catalogue", value: StatsSummary.bytes(database))
            }
            if let free = storage.dataFreeBytes, let total = storage.dataTotalBytes {
                LabeledContent("Data drive free", value: "\(StatsSummary.bytes(free)) of \(StatsSummary.bytes(total))")
            }
        }
        .font(.subheadline)
    }
}
