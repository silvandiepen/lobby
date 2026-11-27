// SPDX-License-Identifier: MPL-2.0
import Charts
import LobbyKit
import SwiftUI

/// "Your Month in Lobby": what a viewer watched and listened to, and when. Their own, or a
/// child's for a grown-up of the household.
struct ViewerStatsView: View {
    @State private var model: ViewerStatsModel
    @State private var confirmsForget = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(app: AppModel, profileID: String) {
        _model = State(initialValue: ViewerStatsModel(app: app, profileID: profileID))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Space.xl) {
                header
                if let stats = model.stats {
                    if model.isEmpty {
                        ContentUnavailableView(
                            "Nothing yet", systemImage: "chart.bar",
                            description: Text("What is watched and listened to shows up here."))
                    } else {
                        StatsCardGrid(cards: model.cards)
                        timeSection(stats)
                        whenSection(stats)
                        titlesSection(stats)
                        if !stats.series.isEmpty { seriesSection(stats) }
                        kindsSection(stats)
                        if stats.music.listenedMs > 0 { musicSection(stats) }
                        if let history = stats.history, !history.isEmpty { historySection(history) }
                    }
                    footer(stats)
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
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .artworkBackground(model.artworks)
        .navigationTitle(model.headline)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
        .confirmationDialog(
            "Forget everything \(model.stats?.viewer.name ?? "this viewer") watched?", isPresented: $confirmsForget,
            titleVisibility: .visible
        ) {
            Button("Forget History", role: .destructive) { Task { await model.forget() } }
                .accessibilityIdentifier("stats.confirmForget")
        } message: {
            Text("The history and these statistics are deleted on Lobby Server, music included. Where each title was stopped stays.")
        }
        .accessibilityIdentifier("stats.viewer")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.m) {
            HStack(spacing: AppTheme.Space.m) {
                if let profile = model.profile { ProfileAvatar(profile: profile, size: 48) }
                Text(model.headline)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("stats.headline")
            }
            StatsRangePicker(selection: model.range) { range in Task { await model.select(range) } }
        }
    }

    private func timeSection(_ stats: ViewerStats) -> some View {
        StatsPanel(
            title: model.isKid ? "Screen Time" : "Time",
            note: model.isKid ? "Watching and listening in Lobby, each day" : nil
        ) {
            StatsTimeChart(bars: model.bars, byMonth: stats.range.name == .year || stats.range.name == .all)
        }
    }

    private func whenSection(_ stats: ViewerStats) -> some View {
        StatsPanel(title: "When", note: model.isKid ? model.whenSummary : nil) {
            StatsHeatmap(cells: model.heat)
            HStack(spacing: AppTheme.Space.l) {
                whenFigure("Mornings", stats.when.mornings)
                whenFigure("Afternoons", stats.when.afternoons)
                whenFigure("Evenings", stats.when.evenings)
                whenFigure("Nights", stats.when.nights)
                whenFigure("Weekends", stats.when.weekends)
            }
            .font(.footnote)
        }
    }

    private func whenFigure(_ name: String, _ ms: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).foregroundStyle(.lobbySecondary)
            Text(StatsSummary.duration(ms)).font(.subheadline.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    private func titlesSection(_ stats: ViewerStats) -> some View {
        StatsPanel(title: "Most Watched") {
            let most = stats.topTitles.first?.watchedMs ?? 1
            ForEach(stats.topTitles) { title in
                StatsTitleRow(title: title, most: most)
            }
        }
    }

    private func seriesSection(_ stats: ViewerStats) -> some View {
        StatsPanel(title: "Series", note: "How far along") {
            ForEach(stats.series) { StatsSeriesRow(series: $0) }
        }
    }

    @ViewBuilder
    private func kindsSection(_ stats: ViewerStats) -> some View {
        let columns = sizeClass == .compact ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Space.m) {
            if !stats.genres.isEmpty {
                StatsPanel(title: "Genres") { StatsShareChart(shares: stats.genres) }
            }
            if !stats.studios.isEmpty {
                StatsPanel(title: "Studios") { StatsShareChart(shares: stats.studios) }
            }
            if !stats.categories.isEmpty {
                StatsPanel(title: "Categories") { StatsShareChart(shares: stats.categories) }
            }
            if let devices = stats.devices, !devices.isEmpty {
                StatsPanel(title: "Devices") {
                    StatsSplitChart(parts: devices.map { ($0.name, $0.watchedMs) })
                    if let away = StatsSummary.awayShare(stats.roads) {
                        Text("\(Int((away * 100).rounded()))% away from home")
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                    }
                }
            }
        }
    }

    private func musicSection(_ stats: ViewerStats) -> some View {
        StatsPanel(title: "Listening", note: "\(StatsSummary.duration(stats.music.listenedMs)), \(stats.music.plays) songs") {
            ForEach(stats.music.topAlbums.prefix(5)) { StatsAlbumRow(album: $0) }
            if !stats.music.topArtists.isEmpty {
                Text("Mostly " + stats.music.topArtists.prefix(3).map(\.name).joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
            }
        }
    }

    private func historySection(_ history: [StatsSitting]) -> some View {
        StatsPanel(title: "History", note: "The latest first") {
            ForEach(history) { sitting in
                HStack(alignment: .top, spacing: AppTheme.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sitting.title).font(.headline).lineLimit(1)
                        if let subtitle = sitting.subtitle {
                            Text(subtitle).font(.subheadline).lineLimit(1)
                        }
                        Text(when(sitting) + " · " + StatsSummary.duration(sitting.watchedMs) + (sitting.completed ? " · Finished" : ""))
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                        let how = StatsSummary.how(sitting)
                        if !how.isEmpty {
                            Text(how).font(.caption).foregroundStyle(.lobbySecondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if model.canRemove {
                        Button("Remove from History", systemImage: "minus.circle", role: .destructive) {
                            Task { await model.remove(sitting) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("stats.remove.\(sitting.id)")
                    }
                }
                .contextMenu {
                    if model.canRemove {
                        Button("Remove from History", systemImage: "minus.circle", role: .destructive) {
                            Task { await model.remove(sitting) }
                        }
                    }
                }
            }
        }
    }

    private func when(_ sitting: StatsSitting) -> String {
        sitting.timed
            ? sitting.startedAt.formatted(date: .abbreviated, time: .shortened)
            : sitting.startedAt.formatted(date: .abbreviated, time: .omitted)
    }

    private func footer(_ stats: ViewerStats) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.m) {
            Text("Lobby Server keeps this for \(stats.keptDays) days, for this household only.")
                .font(.footnote)
                .foregroundStyle(.lobbySecondary)
            if model.canForget {
                Button("Forget History…", systemImage: "trash", role: .destructive) { confirmsForget = true }
                    .buttonStyle(.lobbyText)
                    .accessibilityIdentifier("stats.forget")
            }
        }
    }
}

/// The viewer's own page as a sheet, from the viewer menu.
struct StatsSheet: View {
    let profileID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ViewerStatsView(app: app, profileID: profileID)
                .lobbyDestinations()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 640)
        #endif
    }
}
