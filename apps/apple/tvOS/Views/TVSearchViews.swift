// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Search on the TV: the same server search as the other apps, with the filters as menus a
/// remote can use. What is not in the library opens a page with a QR code: the TV has no web
/// browser, so its links are for a phone.
struct TVSearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.motion) private var motion
    @State private var query = ""
    @State private var model: SearchModel?
    @State private var shownOutside: OutsideTitle?

    var body: some View {
        ScrollView {
            if let model {
                content(model)
            }
        }
        .scrollClipDisabled()
        .searchable(text: $query, prompt: app.isKidsMode ? "Films and series" : "Titles, people, years")
        .onSubmit(of: .search) { model?.remember(text: query) }
        .onAppear {
            if model == nil { model = app.makeSearchModel() }
        }
        .onChange(of: app.activeProfile?.id) {
            model?.setViewer(app.activeProfile?.id, lookBeyond: !app.isKidsMode)
        }
        .task(id: model.map { $0.query(text: query) } ?? "") {
            guard let model else { return }
            try? await Task.sleep(for: .milliseconds(model.asksAnything(text: query) ? 300 : 0))
            if Task.isCancelled { return }
            await model.search(text: query)
        }
        .fullScreenCover(item: $shownOutside) { title in
            if let model { TVOutsidePage(title: title, model: model) }
        }
    }

    @ViewBuilder
    private func content(_ model: SearchModel) -> some View {
        let local = app.search(query)
        let categories = app.searchCategories(query)
        let answer = model.isCurrent(text: query) ? model.answer : nil
        VStack(alignment: .leading, spacing: TVMetrics.shelfGap) {
            if !app.isKidsMode { TVSearchFilterRow(model: model, answer: answer) }
            if !model.asksAnything(text: query) {
                recent(model)
            } else if let answer {
                if !categories.isEmpty {
                    TVShelf(title: "Categories") {
                        ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                            TVCategoryTile(category: category, tint: NavigationTint.category(app.look(of: category), at: index))
                        }
                    }
                }
                if !answer.people.items.isEmpty {
                    TVShelf(title: "People") {
                        ForEach(answer.people.items) { person in
                            NavigationLink(value: Route.person(person.id)) {
                                TVPersonLabel(name: person.name, picture: person.picture, detail: "\(person.titles) here")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                group("Films", answer.films)
                group("Series", answer.series)
                group("Home Videos", answer.videos)
                if !answer.episodes.items.isEmpty {
                    TVShelf(title: "Episodes") {
                        ForEach(answer.episodes.items) { episode in
                            NavigationLink(value: Route.item(episode.showId ?? episode.item.id)) {
                                TVPosterLabel(
                                    title: episode.item.title,
                                    detail: episode.showId.flatMap(app.item)?.title ?? "", year: nil,
                                    artwork: episode.item.artwork.still, picture: nil, width: TVMetrics.still)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                if model.lookBeyond { outside(model.outside) }
                if answer.isEmpty, categories.isEmpty, model.outside?.isEmpty ?? true {
                    ContentUnavailableView.search(text: query)
                }
            } else if !local.isEmpty {
                TVGrid(items: local)
            } else if model.phase == .searching {
                ProgressView()
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
        .padding(.vertical, AppTheme.Space.xl)
        .animation(motion.animation(.list), value: answer?.films.items.map(\.id))
    }

    @ViewBuilder
    private func group(_ title: String, _ group: SearchGroup<SearchTitle>) -> some View {
        if !group.items.isEmpty {
            TVShelf(title: title) {
                ForEach(group.items) { found in
                    TVItemLink(item: app.item(found.item.id) ?? found.item)
                }
            }
        }
    }

    @ViewBuilder
    private func outside(_ answer: OutsideAnswer?) -> some View {
        if let answer {
            VStack(alignment: .leading, spacing: AppTheme.Space.l) {
                Text("Not in Your Library").font(.title3.weight(.semibold))
                Text(answer.reason?.message ?? "From TMDB. These cannot be played here: choose one to open it on your phone.")
                    .foregroundStyle(.secondary)
                ForEach([("Films", answer.films), ("Series", answer.series)], id: \.0) { title, titles in
                    if !titles.isEmpty {
                        TVShelf(title: title) {
                            ForEach(titles) { one in
                                Button { shownOutside = one } label: {
                                    TVOutsideLabel(title: one)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if !answer.people.isEmpty {
                    TVShelf(title: "People") {
                        ForEach(answer.people) { person in
                            NavigationLink(value: Route.person(person.id)) {
                                TVPersonLabel(name: person.name, picture: person.picture, detail: person.knownFor ?? "")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                ForEach(answer.attribution, id: \.self) { Text($0).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }

    @ViewBuilder
    private func recent(_ model: SearchModel) -> some View {
        if model.recent.queries.isEmpty {
            ContentUnavailableView(
                "Search everything", systemImage: AppSymbol.search,
                description: Text(app.isKidsMode ? "Find a film or a series by its name." : "A title, an actor, a director, a year."))
        } else {
            VStack(alignment: .leading, spacing: AppTheme.Space.m) {
                Text("Recent Searches").font(.headline)
                ScrollView(.horizontal) {
                    HStack(spacing: AppTheme.Space.l) {
                        ForEach(model.recent.queries, id: \.self) { recent in
                            Button(recent) { query = recent }
                        }
                        Button("Clear", role: .destructive) { model.forgetAll() }
                    }
                    .padding(.vertical, AppTheme.Space.m)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }
}

/// The search filters as menus: Kind, Decade, Rating with its source, Person, Genre.
struct TVSearchFilterRow: View {
    @Bindable var model: SearchModel
    let answer: SearchAnswer?
    @Environment(AppModel.self) private var app

    var body: some View {
        let options = TitleQuery.options(of: app.catalogue.items.filter { $0.parentId == nil }, context: app.titleQueryContext)
        let filters = model.filters
        ScrollView(.horizontal) {
            HStack(spacing: AppTheme.Space.l) {
                Menu {
                    Button("Films and Series") { model.filters.kind = nil }
                    ForEach(TitleKind.allCases, id: \.self) { kind in
                        Button(kind == .movie ? "Films" : kind == .show ? "Series" : "Home Videos") { model.filters.kind = kind }
                    }
                } label: {
                    label(filters.kind.map { $0 == .movie ? "Films" : $0 == .show ? "Series" : "Home Videos" } ?? "Kind", symbol: "film", isOn: filters.kind != nil)
                }
                Menu {
                    Button("Any Year") {
                        model.filters.yearFrom = nil
                        model.filters.yearTo = nil
                    }
                    ForEach(options.decades.reversed(), id: \.self) { decade in
                        Button("\(decade)s") {
                            model.filters.yearFrom = decade
                            model.filters.yearTo = decade + 9
                        }
                    }
                } label: {
                    label(filters.yearFrom.map { "\($0)s" } ?? "Year", symbol: "calendar", isOn: filters.yearFrom != nil)
                }
                Menu {
                    Button("Any Rating") { model.filters.rating = nil }
                    ForEach(answer?.sources ?? [.tmdb], id: \.self) { source in
                        Menu(source.name) {
                            ForEach(source.scale == 100 ? [60.0, 70, 80, 90] : [6.0, 7, 7.5, 8], id: \.self) { step in
                                Button("\(source.text(step)) or more") { model.filters.rating = .init(source: source, minimum: step) }
                            }
                        }
                    }
                } label: {
                    label(filters.rating.map { "\($0.source.name) ≥ \($0.source.text($0.minimum))" } ?? "Rating", symbol: "star", isOn: filters.rating != nil)
                }
                if let people = answer?.people.items, !people.isEmpty || !filters.people.isEmpty {
                    Menu {
                        Button("Anyone") { model.filters.people = [] }
                        ForEach(people) { person in
                            Button(person.name) { model.filters.people = [.init(name: person.name, role: .any)] }
                        }
                    } label: {
                        label(filters.people.first?.name ?? "Person", symbol: "person", isOn: !filters.people.isEmpty)
                    }
                }
                if !options.genres.isEmpty {
                    Menu {
                        Button("Any Genre") { model.filters.genres = [] }
                        ForEach(options.genres.prefix(20), id: \.self) { name in
                            Button(name) { model.filters.genres = [name] }
                        }
                    } label: {
                        label(filters.genres.first ?? "Genre", symbol: "theatermasks", isOn: !filters.genres.isEmpty)
                    }
                }
                if !filters.isEmpty {
                    Button("Clear") { model.filters = .none }
                }
            }
            .padding(.vertical, AppTheme.Space.m)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func label(_ title: String, symbol: String, isOn: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline.weight(isOn ? .bold : .regular))
            .foregroundStyle(isOn ? Color.lobbyAccent(.dark) : Color.primary)
            .padding(.horizontal, AppTheme.Space.s)
    }
}

/// A person in a circle, the way the system lifts it.
struct TVPersonLabel: View {
    let name: String
    let picture: String?
    let detail: String

    var body: some View {
        VStack(spacing: AppTheme.Space.s) {
            SearchPicture(path: picture, symbol: "person.fill", maxPixels: 400)
                .frame(width: 200, height: 200)
                .clipShape(Circle())
                .hoverEffect(.highlight)
            Text(name).font(.callout.weight(.medium)).lineLimit(1)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(width: 240)
    }
}

/// A title beyond the library.
struct TVOutsideLabel: View {
    let title: OutsideTitle

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
            SearchPicture(path: title.poster, maxPixels: 600)
                .frame(width: TVMetrics.poster, height: TVMetrics.poster / AppTheme.posterAspect)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous))
                .hoverEffect(.highlight)
            Text(title.title).font(.callout.weight(.medium)).lineLimit(1)
            Text([title.year.map(String.init), title.ratings.known.first.map { "\($0.source.name) \($0.source.text($0.value))" }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: TVMetrics.poster, alignment: .leading)
        .accessibilityHint("Not in your library")
    }
}

/// One title beyond the library: what it is, its ratings, and QR codes to open it on a phone.
struct TVOutsidePage: View {
    let title: OutsideTitle
    let model: SearchModel
    @Environment(\.dismiss) private var dismiss
    @State private var detail: OutsideTitleDetail?

    var body: some View {
        let links = detail?.links ?? title.links
        HStack(alignment: .top, spacing: TVMetrics.shelfGap) {
            SearchPicture(path: title.poster, maxPixels: 900)
                .frame(width: 400, height: 400 / AppTheme.posterAspect)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous))
            VStack(alignment: .leading, spacing: AppTheme.Space.l) {
                Text(title.title).font(.title.weight(.bold))
                Text([title.year.map(String.init), detail?.runtimeMinutes.map { "\($0) min" }].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                ForEach((detail?.ratings ?? title.ratings).known, id: \.source) { rating in
                    Text("\(rating.source.name): \(rating.source.text(rating.value))")
                }
                if let overview = title.overview ?? detail?.overview { Text(overview).lineLimit(6) }
                Text("Not in your library. Open it on your phone:").foregroundStyle(.secondary)
                HStack(spacing: TVMetrics.shelfGap) {
                    if let imdb = links.imdb {
                        VStack { QRCodeView(text: imdb.absoluteString, size: 220, label: "IMDb, for a camera"); Text("IMDb") }
                    }
                    VStack { QRCodeView(text: links.tmdb.absoluteString, size: 220, label: "TMDB, for a camera"); Text("TMDB") }
                }
                Button("Done") { dismiss() }
                ForEach(detail?.attribution ?? [], id: \.self) { Text($0).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .padding(TVMetrics.shelfGap)
        .task { detail = try? await model.outsideTitle(title.tmdb) }
    }
}

/// A person: their titles here first, then elsewhere, as on the other devices.
struct TVPersonPage: View {
    let personID: Int
    @Environment(AppModel.self) private var app
    @State private var model: SearchModel?
    @State private var page: PersonPage?
    @State private var failed = false
    @State private var shownOutside: OutsideTitle?

    var body: some View {
        ScrollView {
            if let page {
                VStack(alignment: .leading, spacing: TVMetrics.shelfGap) {
                    HStack(spacing: TVMetrics.gap) {
                        SearchPicture(path: page.person.picture ?? page.outside?.picture, symbol: "person.fill", maxPixels: 500)
                            .frame(width: 220, height: 220)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                            Text(page.person.name).font(.title.weight(.bold))
                            if let known = page.outside?.knownFor { Text(known).foregroundStyle(.secondary) }
                            if let biography = page.outside?.biography { Text(biography).lineLimit(4) }
                        }
                    }
                    if !page.titles.isEmpty {
                        TVShelf(title: "In Your Library") {
                            ForEach(page.titles) { found in TVItemLink(item: app.item(found.item.id) ?? found.item) }
                        }
                    }
                    if let outside = page.outside, !outside.elsewhere.isEmpty {
                        TVShelf(title: "Not in Your Library") {
                            ForEach(outside.elsewhere) { one in
                                Button { shownOutside = one } label: { TVOutsideLabel(title: one) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .padding(.vertical, AppTheme.Space.xl)
            } else if failed {
                ContentUnavailableView(
                    "This person cannot be shown", systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Lobby Server could not be reached, or they are in nothing here."))
            } else {
                ProgressView()
            }
        }
        .scrollClipDisabled()
        .task(id: personID) {
            let model = model ?? app.makeSearchModel()
            self.model = model
            do {
                page = try await model.person(personID)
            } catch {
                failed = true
            }
        }
        .fullScreenCover(item: $shownOutside) { title in
            if let model { TVOutsidePage(title: title, model: model) }
        }
    }
}
