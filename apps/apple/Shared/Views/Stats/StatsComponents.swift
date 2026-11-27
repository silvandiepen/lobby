// SPDX-License-Identifier: MPL-2.0
import Charts
import LobbyKit
import SwiftUI

// The parts of the statistics pages: cards, charts, rows. In the look of the home: the page in
// the colours of what was watched most, headings as the shelves have them.

/// The range of a page: week, month, year, all.
struct StatsRangePicker: View {
    let selection: StatsRange
    let choose: (StatsRange) -> Void

    var body: some View {
        Picker("Range", selection: Binding(get: { selection }, set: { choose($0) })) {
            ForEach(StatsRange.allCases, id: \.self) { range in
                Text(StatsSummary.rangeTitle(range)).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
        .accessibilityIdentifier("stats.range")
    }
}

/// A heading as the home's shelves have them.
struct StatsHeading: View {
    let title: String
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A block of the page, on a surface a step lighter than the page.
struct StatsPanel<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.m) {
            StatsHeading(title: title, note: note)
            content
        }
        .padding(AppTheme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lobbyChip(scheme).opacity(scheme == .dark ? 1 : 0.7), in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
    }
}

/// The big numbers at the top of a page.
struct StatsCardGrid: View {
    let cards: [StatsCard]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: AppTheme.Space.m)], spacing: AppTheme.Space.m) {
            ForEach(cards) { card in
                VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                    Label(card.title, systemImage: card.symbol)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.lobbyKicker)
                    Text(card.value)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    if let detail = card.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                .padding(AppTheme.Space.m)
                .background(Color.lobbyChip(scheme), in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("stats.card.\(card.id)")
            }
        }
    }
}

/// Time per day (or month): watching, and listening on top of it.
struct StatsTimeChart: View {
    let bars: [StatsBar]
    /// Days, or months for a long range.
    let byMonth: Bool
    var showsListening = true

    var body: some View {
        Chart(bars) { bar in
            BarMark(
                x: .value(byMonth ? "Month" : "Day", bar.date, unit: byMonth ? .month : .day),
                y: .value("Hours", bar.watchedHours))
                .foregroundStyle(by: .value("What", "Watched"))
            if showsListening, bar.listenedHours > 0 {
                BarMark(
                    x: .value(byMonth ? "Month" : "Day", bar.date, unit: byMonth ? .month : .day),
                    y: .value("Hours", bar.listenedHours))
                    .foregroundStyle(by: .value("What", "Listened"))
            }
        }
        .chartForegroundStyleScale(["Watched": Color.orange, "Listened": Color.purple])
        .chartLegend(showsListening && bars.contains { $0.listenedHours > 0 } ? .visible : .hidden)
        .chartYAxisLabel("Hours")
        .frame(height: 180)
        .accessibilityIdentifier("stats.time")
    }
}

/// When: weekdays by hours, darker for more.
struct StatsHeatmap: View {
    let cells: [StatsHeatCell]

    var body: some View {
        let most = max(1, cells.map(\.minutes).max() ?? 1)
        Chart(cells) { cell in
            RectangleMark(
                x: .value("Hour", cell.hour),
                y: .value("Day", StatsSummary.shortWeekdays[cell.weekday]),
                width: .ratio(0.9), height: .ratio(0.85))
                .foregroundStyle(Color.orange.opacity(cell.minutes == 0 ? 0.06 : 0.2 + 0.8 * cell.minutes / most))
                .accessibilityLabel("\(StatsSummary.weekdays[cell.weekday]) \(StatsSummary.hour(cell.hour))")
                .accessibilityValue("\(Int(cell.minutes)) minutes")
        }
        .chartXScale(domain: 0...23)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                AxisValueLabel { Text(StatsSummary.hour(value.as(Int.self) ?? 0)) }
            }
        }
        .chartYScale(domain: StatsSummary.shortWeekdays)
        .frame(height: 210)
        .accessibilityIdentifier("stats.heatmap")
    }
}

/// Shares of a whole as bars: genres, studios, categories.
struct StatsShareChart: View {
    let shares: [StatsShare]

    var body: some View {
        Chart(shares.prefix(6)) { share in
            BarMark(x: .value("Hours", Double(share.watchedMs) / 3_600_000), y: .value("Name", share.name))
                .foregroundStyle(Color.orange.gradient)
                .annotation(position: .trailing) {
                    Text(StatsSummary.duration(share.watchedMs))
                        .font(.caption)
                        .foregroundStyle(.lobbySecondary)
                }
        }
        .chartXAxis(.hidden)
        .frame(height: CGFloat(min(shares.count, 6)) * 34 + 10)
    }
}

/// A title with its poster, how long, and a bar as long as its part of the most watched.
struct StatsTitleRow: View {
    let title: StatsTitle
    let most: Int
    var detail: String? = nil
    @Environment(AppModel.self) private var app

    var body: some View {
        let item = app.item(title.itemId)
        NavigationLink(value: Route.item(title.itemId)) {
            HStack(spacing: AppTheme.Space.m) {
                ArtworkView(artwork: item?.artwork.poster, width: 44) {
                    TitleTile(title: title.title, detail: nil, picture: nil, showsTitle: false, width: 44)
                }
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                    Text(title.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(detail ?? StatsSummary.duration(title.watchedMs))
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                    GeometryReader { space in
                        Capsule()
                            .fill(Color.orange.gradient)
                            .frame(width: max(4, space.size.width * CGFloat(title.watchedMs) / CGFloat(max(1, most))))
                    }
                    .frame(height: 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("stats.title.\(title.title)")
    }
}

/// An album and its cover.
struct StatsAlbumRow: View {
    let album: StatsAlbum

    var body: some View {
        NavigationLink(value: Route.musicAlbum(album.id)) {
            HStack(spacing: AppTheme.Space.m) {
                ArtworkView(artwork: album.coverId.map(Artwork.musicCover), width: 48) {
                    Image(systemName: "music.note")
                        .frame(width: 48, height: 48)
                        .background(Color.purple.opacity(0.3))
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).font(.headline).lineLimit(1)
                    Text([album.artist, StatsSummary.duration(album.listenedMs)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// How far along a series is.
struct StatsSeriesRow: View {
    let series: StatsSeries

    var body: some View {
        NavigationLink(value: Route.item(series.itemId)) {
            VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                HStack {
                    Text(series.title).font(.headline).lineLimit(1)
                    Spacer()
                    Text("\(series.episodesWatched) of \(series.episodes)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.lobbySecondary)
                }
                ProgressView(value: Double(series.episodesWatched), total: Double(max(1, series.episodes)))
                    .tint(.orange)
                if let last = series.lastEpisode {
                    Text("Last: \(last), \(series.lastAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.lobbySecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// A part of a whole, as a ring.
struct StatsSplitChart: View {
    let parts: [(name: String, value: Int)]

    var body: some View {
        let shown = parts.filter { $0.value > 0 }
        Chart(shown, id: \.name) { part in
            SectorMark(angle: .value("Share", part.value), innerRadius: .ratio(0.62), angularInset: 1.5)
                .foregroundStyle(by: .value("Where", part.name))
                .cornerRadius(3)
        }
        .chartForegroundStyleScale(range: [Color.orange, Color.purple, Color.blue, Color.teal, Color.gray])
        .frame(height: 170)
    }
}
