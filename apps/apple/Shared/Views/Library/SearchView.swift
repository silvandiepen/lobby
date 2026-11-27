// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Search: one field for the whole library and beyond it. While the server answers, the titles
/// whose name matches come from the device's own copy at once; then the server's answer: films,
/// series, episodes, people and collections that can be played, and below them what TMDB has that
/// is not in the library, which only links out. Kids mode searches the library alone.
struct SearchResultsView: View {
    @Binding var query: String

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.motion) private var motion
    @State private var model: SearchModel?
    @State private var shownOutside: OutsideTitle?
    private var metrics = TileMetrics()

    init(query: Binding<String>) {
        _query = query
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.lobbyBackground(scheme))
        .onAppear {
            if model == nil { model = app.makeSearchModel() }
        }
        .onChange(of: app.activeProfile?.id) {
            model?.setViewer(app.activeProfile?.id, lookBeyond: !app.isKidsMode)
        }
        .task(id: model.map { $0.query(text: query) } ?? "") {
            // Typing replaces this task: the server is asked once the typing pauses.
            guard let model else { return }
            try? await Task.sleep(for: .milliseconds(model.query(text: query).isEmpty ? 0 : 220))
            if Task.isCancelled { return }
            await model.search(text: query)
        }
        .onSubmit(of: .search) { model?.remember(text: query) }
        .sheet(item: $shownOutside) { title in
            if let model { OutsideTitleSheet(title: title, model: model) }
        }
    }

    @ViewBuilder
    private func content(_ model: SearchModel) -> some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let local = app.search(query)
        let categories = app.searchCategories(query)
        let music = app.music.isAvailable ? app.music.catalogue.search(query, limit: 12) : .init()
        let answer = model.isCurrent(text: query) ? model.answer : nil
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Space.m) {
                if !app.isKidsMode {
                    SearchFilterChips(model: model, answer: answer, text: $query)
                        .padding(.top, AppTheme.Space.s)
                }
                if !model.asksAnything(text: query) {
                    RecentSearchesList(model: model, query: $query)
                } else if let answer {
                    if !categories.isEmpty, !trimmed.isEmpty { categoryRow(categories) }
                    library(answer, model: model)
                    if !music.isEmpty { MusicSearchResults(result: music) }
                    if model.lookBeyond { OutsideResults(answer: model.outside, show: { shownOutside = $0 }) }
                    if answer.isEmpty, music.isEmpty, categories.isEmpty, model.outside?.isEmpty ?? true {
                        nothingFound
                    }
                } else if !trimmed.isEmpty, !local.isEmpty || !categories.isEmpty || !music.isEmpty {
                    // The device's own titles, until the server answers or when it cannot.
                    if !categories.isEmpty { categoryRow(categories) }
                    if !local.isEmpty { localTitles(local) }
                    if !music.isEmpty { MusicSearchResults(result: music) }
                    if model.phase == .failed { offlineNote }
                } else if model.phase == .searching {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, AppTheme.Space.xl)
                } else {
                    nothingFound
                }
            }
            .padding(.bottom, AppTheme.Space.xl)
        }
        .accessibilityIdentifier("search.results")
        .animation(motion.animation(.list), value: answer?.films.items.map(\.id))
    }

    private var nothingFound: some View {
        ContentUnavailableView.search(text: query)
            .padding(.top, AppTheme.Space.xl)
    }

    private var offlineNote: some View {
        Label("Only titles by their name: Lobby Server cannot be reached.", systemImage: "wifi.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, TileMetrics.margin(sizeClass))
    }

    private func localTitles(_ items: [Item]) -> some View {
        PosterGridBody(width: metrics.poster(sizeClass)) { width in
            ForEach(items) { item in
                NavigationLink(value: Route.item(item.id)) {
                    PosterTile(item: item, width: width)
                }
                .buttonStyle(.lobbyTile(opens: Route.item(item.id)))
            }
        }
    }

    @ViewBuilder
    private func library(_ answer: SearchAnswer, model: SearchModel) -> some View {
        if !answer.unknownPeople.isEmpty {
            Text("Nobody in the library is called \(answer.unknownPeople.joined(separator: ", ")).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, TileMetrics.margin(sizeClass))
        }
        if !answer.people.items.isEmpty {
            Shelf(title: "People") {
                ForEach(answer.people.items) { person in
                    NavigationLink(value: Route.person(person.id)) {
                        PersonTile(name: person.name, picture: person.picture, detail: person.detail)
                    }
                    .buttonStyle(.lobbyTile(opens: Route.person(person.id)))
                    .simultaneousGesture(TapGesture().onEnded { model.remember(text: query) })
                    .accessibilityIdentifier("search.person.\(person.name)")
                }
            }
        }
        titleGroup("Films", answer.films, model: model)
        titleGroup("Series", answer.series, model: model)
        titleGroup("Home Videos", answer.videos, model: model)
        if !answer.collections.items.isEmpty {
            Shelf(title: "Collections") {
                ForEach(answer.collections.items) { collection in
                    Button {
                        query = #"collection:"\#(collection.name)""#
                    } label: {
                        FilterChipLabel(title: "\(collection.name) · \(collection.itemIds.count)", symbol: "square.stack", isOn: false)
                    }
                    .buttonStyle(.lobbyPill)
                }
            }
        }
        if !answer.episodes.items.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                Text("Episodes").font(.title3.weight(.semibold))
                ForEach(answer.episodes.items) { episode in
                    NavigationLink(value: Route.item(episode.showId ?? episode.item.id)) {
                        EpisodeResultRow(episode: episode, show: episode.showId.flatMap(app.item))
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { model.remember(text: query) })
                }
            }
            .padding(.horizontal, TileMetrics.margin(sizeClass))
        }
    }

    @ViewBuilder
    private func titleGroup(_ title: String, _ group: SearchGroup<SearchTitle>, model: SearchModel) -> some View {
        if !group.items.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.title3.weight(.semibold))
                    if group.total > group.items.count {
                        Text("\(group.items.count) of \(group.total)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, TileMetrics.margin(sizeClass))
                PosterGridBody(width: metrics.poster(sizeClass)) { width in
                    ForEach(group.items) { found in
                        let item = app.item(found.item.id) ?? found.item
                        NavigationLink(value: Route.item(item.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                PosterTile(item: item, width: width)
                                if let reason = found.match?.reason {
                                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                RatingsLine(ratings: found.ratings)
                            }
                        }
                        .buttonStyle(.lobbyTile(opens: Route.item(item.id)))
                        .simultaneousGesture(TapGesture().onEnded { model.remember(text: query) })
                        .edgeEase(.vertical)
                    }
                }
            }
        }
    }

    /// Categories by their name: also the ones inside another, which the sidebar leaves out.
    private func categoryRow(_ categories: [CategoryShelf]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: TileMetrics.gap(sizeClass)) {
                ForEach(categories) { category in
                    NavigationLink(value: Route.category(category.id)) {
                        CategoryTile(category: category, width: metrics.category(sizeClass))
                    }
                    .buttonStyle(.lobbyTile(opens: Route.category(category.id)))
                    .accessibilityIdentifier("search.category.\(category.name)")
                }
            }
            .padding(.horizontal, TileMetrics.margin(sizeClass))
            .padding(.vertical, AppTheme.Space.s)
        }
        .scrollIndicators(.never)
    }
}

extension SearchPerson {
    /// "Actor · 3 titles".
    var detail: String {
        let role = roles.first.map(\.title)
        let count = titles == 1 ? "1 title" : "\(titles) titles"
        return [role, count].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A person: their picture in a circle, their name under it.
struct PersonTile: View {
    let name: String
    let picture: String?
    var detail: String? = nil
    var width: CGFloat = 96

    var body: some View {
        VStack(spacing: AppTheme.Space.xs) {
            SearchPicture(path: picture, symbol: "person.fill", maxPixels: 300)
                .frame(width: width, height: width)
                .clipShape(Circle())
            Text(name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width + 24)
        .accessibilityElement(children: .combine)
    }
}

/// An episode that matched: its show, its number and title.
struct EpisodeResultRow: View {
    let episode: SearchEpisode
    let show: Item?

    var body: some View {
        HStack(spacing: AppTheme.Space.m) {
            Image(systemName: "tv").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.item.title).font(.body.weight(.medium)).lineLimit(1)
                Text([show?.title, code].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.forward").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(.vertical, AppTheme.Space.xs)
        .contentShape(Rectangle())
    }

    private var code: String? {
        guard let season = episode.item.seasonNumber, let number = episode.item.episodeNumber else { return nil }
        return "S\(season) E\(number)"
    }
}

/// What this viewer searched for last, to search again.
struct RecentSearchesList: View {
    let model: SearchModel
    @Binding var query: String
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if model.recent.queries.isEmpty {
            ContentUnavailableView(
                "Search everything", systemImage: "magnifyingglass",
                description: Text(app.isKidsMode
                    ? "Find a film or a series by its name."
                    : "A title, an actor, a director, a year or a rating. Try “actor:\"Tom Hanks\" year:1990..1999”."))
                .padding(.top, AppTheme.Space.xl)
        } else {
            VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                HStack {
                    Text("Recent Searches").font(.title3.weight(.semibold))
                    Spacer()
                    Button("Clear") { model.forgetAll() }.buttonStyle(.lobbyText)
                }
                ForEach(model.recent.queries, id: \.self) { recent in
                    HStack {
                        Button {
                            query = recent
                        } label: {
                            Label(recent, systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            model.forget(recent)
                        } label: {
                            Image(systemName: "xmark").font(.footnote)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Forget \(recent)")
                    }
                    .padding(.vertical, AppTheme.Space.xs)
                }
            }
            .padding(.horizontal, TileMetrics.margin(sizeClass))
            .accessibilityIdentifier("search.recent")
        }
    }
}
