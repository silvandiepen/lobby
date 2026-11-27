// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A viewer's month, year or all, simply: the big numbers and what was watched most.
struct TVStatsPage: View {
    @State private var model: ViewerStatsModel
    @Environment(AppModel.self) private var app

    init(app: AppModel, profileID: String) {
        _model = State(initialValue: ViewerStatsModel(app: app, profileID: profileID))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVMetrics.shelfGap) {
                Text(model.headline)
                    .font(.system(size: 64, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: TVMetrics.gap) {
                    ForEach([StatsRange.week, .month, .year], id: \.self) { range in
                        Button(StatsSummary.rangeTitle(range)) { Task { await model.select(range) } }
                            .opacity(model.range == range ? 1 : 0.7)
                            .accessibilityAddTraits(model.range == range ? .isSelected : [])
                    }
                }
                .focusSection()
                if let stats = model.stats {
                    if model.isEmpty {
                        TVNotice(symbol: "chart.bar", tint: .secondary, title: "Nothing yet", text: "What is watched shows up here.")
                    } else {
                        HStack(alignment: .top, spacing: TVMetrics.gap) {
                            ForEach(model.cards.prefix(5)) { card in
                                VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                                    Label(card.title, systemImage: card.symbol)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(Color.lobbyKicker)
                                    Text(card.value).font(.title2.weight(.bold)).lineLimit(2)
                                    if let detail = card.detail {
                                        Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                .frame(width: 300, alignment: .leading)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        let titles = stats.topTitles.compactMap { app.item($0.itemId) }
                        if !titles.isEmpty {
                            VStack(alignment: .leading, spacing: AppTheme.Space.m) {
                                Text("Most Watched").font(.headline).accessibilityAddTraits(.isHeader)
                                ScrollView(.horizontal) {
                                    LazyHStack(spacing: TVMetrics.gap) {
                                        ForEach(titles) { TVItemLink(item: $0) }
                                    }
                                    .padding(.vertical, AppTheme.Space.l)
                                }
                                .scrollClipDisabled()
                            }
                        }
                    }
                } else if model.isUnavailable {
                    TVNotice(symbol: "chart.bar", tint: .secondary, title: "Not on this server yet", text: "Lobby Server shows statistics from a newer version on.")
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, AppTheme.Space.xl)
        }
        .scrollClipDisabled()
        .artworkBackground(model.artworks)
        .task { await model.load() }
    }
}
