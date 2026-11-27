// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The search screen's chips: Kind, Year, Rating (with its source), Person, Genre and Exact
/// title, the same pill chips as the lists' filter bar (`FilterChip`). They write the query
/// language (`SearchFilters`); what someone typed in it shows as chips of its own, to take out.
struct SearchFilterChips: View {
    @Bindable var model: SearchModel
    let answer: SearchAnswer?
    @Binding var text: String

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var asksPerson = false
    @State private var asksYears = false

    var body: some View {
        let options = TitleQuery.options(
            of: app.catalogue.items.filter { $0.parentId == nil }, context: app.titleQueryContext)
        ScrollView(.horizontal) {
            HStack(spacing: AppTheme.Space.s) {
                kindMenu
                yearMenu(options)
                ratingMenu
                FilterChip(
                    title: model.filters.people.isEmpty ? "Person" : model.filters.people.map(\.name).joined(separator: ", "),
                    symbol: "person", isOn: !model.filters.people.isEmpty
                ) { asksPerson = true }
                    .accessibilityIdentifier("search.filters.person")
                if !options.genres.isEmpty { genreMenu(options) }
                FilterChip(title: "Exact Title", isOn: model.filters.exactTitle) { model.filters.exactTitle.toggle() }
                ForEach(answer?.understood ?? []) { typed in
                    // A filter typed into the field: shown, and taken out of the words with a tap.
                    if text.contains(typed.token) {
                        FilterChip(title: typed.label, symbol: "xmark", isOn: true) {
                            text = model.removing(typed, from: text)
                        }
                    }
                }
                if !model.filters.isEmpty {
                    Button("Clear") { model.filters = .none }
                        .buttonStyle(.lobbyText)
                        .accessibilityIdentifier("search.filters.clear")
                }
            }
            .padding(.horizontal, TileMetrics.margin(sizeClass))
        }
        .scrollIndicators(.never)
        .sensoryFeedback(.selection, trigger: model.filters)
        .sheet(isPresented: $asksPerson) { PersonFilterSheet(filters: $model.filters, suggestions: answer?.people.items ?? []) }
        .sheet(isPresented: $asksYears) { YearsSheet(filters: $model.filters, years: options.years) }
    }

    private var kindMenu: some View {
        Menu {
            Picker("Kind", selection: $model.filters.kind) {
                Text("Films and Series").tag(TitleKind?.none)
                ForEach(TitleKind.allCases, id: \.self) { kind in Text(kind.title).tag(TitleKind?.some(kind)) }
            }
        } label: {
            FilterChipLabel(title: model.filters.kind?.title ?? "Kind", isOn: model.filters.kind != nil, isMenu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.lobbyPill)
    }

    private func yearMenu(_ options: TitleFilterOptions) -> some View {
        let filters = model.filters
        let title: String = switch (filters.yearFrom, filters.yearTo) {
        case let (from?, to?): from == to ? "\(from)" : "\(from)–\(to)"
        case let (from?, nil): "From \(from)"
        case let (nil, to?): "Until \(to)"
        case (nil, nil): "Year"
        }
        return Menu {
            Button("Any Year") {
                model.filters.yearFrom = nil
                model.filters.yearTo = nil
            }
            Button("From… To…") { asksYears = true }
            Divider()
            ForEach(options.decades.reversed(), id: \.self) { decade in
                Button(TitleText.decade(decade)) {
                    model.filters.yearFrom = decade
                    model.filters.yearTo = decade + 9
                }
            }
        } label: {
            FilterChipLabel(title: title, symbol: "calendar", isOn: filters.yearFrom != nil || filters.yearTo != nil, isMenu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.lobbyPill)
        .accessibilityIdentifier("search.filters.year")
    }

    private var ratingMenu: some View {
        let sources = answer?.sources ?? [.tmdb]
        let rating = model.filters.rating
        return Menu {
            Button("Any Rating") { model.filters.rating = nil }
            ForEach(sources, id: \.self) { source in
                Menu(source.name) {
                    ForEach(Self.steps(source), id: \.self) { step in
                        Button("\(source.text(step)) or more") {
                            model.filters.rating = .init(source: source, minimum: step)
                        }
                    }
                }
            }
        } label: {
            FilterChipLabel(
                title: rating.map { "\($0.source.shortName) ≥ \($0.source.text($0.minimum))" } ?? "Rating",
                symbol: "star", isOn: rating != nil, isMenu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.lobbyPill)
        .accessibilityIdentifier("search.filters.rating")
    }

    private func genreMenu(_ options: TitleFilterOptions) -> some View {
        Menu {
            ForEach(options.genres, id: \.self) { genre in
                Toggle(genre, isOn: Binding {
                    model.filters.genres.contains(genre)
                } set: { on in
                    model.filters.genres.removeAll { $0 == genre }
                    if on { model.filters.genres.append(genre) }
                })
            }
        } label: {
            FilterChipLabel(
                title: model.filters.genres.isEmpty ? "Genre" : model.filters.genres.joined(separator: ", "),
                isOn: !model.filters.genres.isEmpty, isMenu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.lobbyPill)
    }

    /// The minimums offered for a source, on its own scale.
    static func steps(_ source: RatingSource) -> [Double] {
        source.scale == 100 ? [50, 60, 70, 80, 90] : [5, 6, 7, 7.5, 8, 8.5]
    }
}

/// Who should be in it, and as what.
struct PersonFilterSheet: View {
    @Binding var filters: SearchFilters
    let suggestions: [SearchPerson]
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role = SearchFilters.Role.cast

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("search.person.name")
                    Picker("As", selection: $role) {
                        ForEach(SearchFilters.Role.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                if !suggestions.isEmpty {
                    Section("In the Library") {
                        ForEach(suggestions) { person in
                            Button(person.name) { name = person.name }
                        }
                    }
                }
                if !filters.people.isEmpty {
                    Section("Chosen") {
                        ForEach(filters.people, id: \.self) { person in
                            HStack {
                                Text(person.name)
                                Spacer()
                                Text(person.role.title).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { filters.people.remove(atOffsets: $0) }
                        Button("Remove All", role: .destructive) { filters.people = [] }
                    }
                }
            }
            .navigationTitle("Person")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        filters.people.append(.init(name: name.trimmingCharacters(in: .whitespaces), role: role))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 320, minHeight: 360)
    }
}

/// Years from and to, both ends in.
struct YearsSheet: View {
    @Binding var filters: SearchFilters
    let years: ClosedRange<Int>?
    @Environment(\.dismiss) private var dismiss
    @State private var from = 1990
    @State private var to = 1999

    var body: some View {
        let range = (years?.lowerBound ?? 1900)...max(years?.upperBound ?? 2030, Calendar.current.component(.year, from: Date()))
        NavigationStack {
            Form {
                Picker("From", selection: $from) {
                    ForEach(Array(range.reversed()), id: \.self) { Text(String($0)).tag($0) }
                }
                Picker("To", selection: $to) {
                    ForEach(Array(range.reversed()), id: \.self) { Text(String($0)).tag($0) }
                }
            }
            .navigationTitle("Years")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        filters.yearFrom = min(from, to)
                        filters.yearTo = max(from, to)
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            from = filters.yearFrom ?? years?.lowerBound ?? from
            to = filters.yearTo ?? years?.upperBound ?? to
        }
        .frame(minWidth: 320, minHeight: 260)
    }
}

/// "Not in your library": what TMDB has. Nothing here plays; each opens its links.
struct OutsideResults: View {
    let answer: OutsideAnswer?
    let show: (OutsideTitle) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if let answer {
            VStack(alignment: .leading, spacing: AppTheme.Space.m) {
                Divider().padding(.horizontal, TileMetrics.margin(sizeClass))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not in Your Library").font(.title3.weight(.semibold))
                    Text("From TMDB. These cannot be played here.").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, TileMetrics.margin(sizeClass))
                if let reason = answer.reason {
                    Text(reason.message)
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, TileMetrics.margin(sizeClass))
                } else if answer.isEmpty {
                    Text("Nothing more at TMDB.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, TileMetrics.margin(sizeClass))
                }
                outsideRow("Films", answer.films)
                outsideRow("Series", answer.series)
                if !answer.people.isEmpty {
                    Shelf(title: "People") {
                        ForEach(answer.people) { person in
                            NavigationLink(value: Route.person(person.id)) {
                                PersonTile(name: person.name, picture: person.picture, detail: person.knownFor)
                            }
                            .buttonStyle(.lobbyTile(opens: Route.person(person.id)))
                        }
                    }
                }
                if !answer.notApplied.isEmpty {
                    Text("Ratings from \(answer.notApplied.compactMap { RatingSource(rawValue: $0)?.name }.joined(separator: ", ")) are not known out here, so that filter is left out.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, TileMetrics.margin(sizeClass))
                }
                ForEach(answer.attribution, id: \.self) { line in
                    Text(line).font(.caption2).foregroundStyle(.tertiary)
                        .padding(.horizontal, TileMetrics.margin(sizeClass))
                }
            }
            .accessibilityIdentifier("search.outside")
        }
    }

    @ViewBuilder
    private func outsideRow(_ title: String, _ titles: [OutsideTitle]) -> some View {
        if !titles.isEmpty {
            Shelf(title: title) {
                ForEach(titles) { one in
                    Button { show(one) } label: { OutsideTile(title: one) }
                        .buttonStyle(.lobbyTile)
                        .accessibilityIdentifier("search.outside.\(one.title)")
                }
            }
        }
    }
}

/// A title beyond the library: poster, name, year and ratings. Dimmed a little: it does not play.
struct OutsideTile: View {
    let title: OutsideTitle
    var width: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            SearchPicture(path: title.poster)
                .frame(width: width, height: width / AppTheme.posterAspect)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption.weight(.semibold))
                        .padding(5)
                        .background(.thinMaterial, in: Circle())
                        .padding(AppTheme.Space.xs)
                }
            Text(title.title).font(.subheadline.weight(.medium)).lineLimit(2)
            Text([title.year.map(String.init), title.roles?.first].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            RatingsLine(ratings: title.ratings)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Not in your library. Opens its links.")
    }
}

/// One title beyond the library: what TMDB knows, every rating, and the links out.
struct OutsideTitleSheet: View {
    let title: OutsideTitle
    let model: SearchModel
    @Environment(\.dismiss) private var dismiss
    @State private var detail: OutsideTitleDetail?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Space.m) {
                    HStack(alignment: .top, spacing: AppTheme.Space.m) {
                        SearchPicture(path: title.poster, maxPixels: 600)
                            .frame(width: 120, height: 120 / AppTheme.posterAspect)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous))
                        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                            Text(title.title).font(.title2.weight(.semibold))
                            Text([title.year.map(String.init), detail?.runtimeMinutes.map { "\($0) min" }, detail?.genres.prefix(3).joined(separator: ", ")]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                            ForEach((detail?.ratings ?? title.ratings).known, id: \.source) { rating in
                                Text("\(rating.source.name): \(rating.source.text(rating.value))")
                                    .font(.subheadline)
                            }
                            Label("Not in your library", systemImage: "info.circle")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let overview = title.overview ?? detail?.overview {
                        Text(overview)
                    }
                    let links = detail?.links ?? title.links
                    HStack {
                        if let imdb = links.imdb {
                            Link(destination: imdb) { Label("Open on IMDb", systemImage: "arrow.up.forward") }
                                .buttonStyle(.borderedProminent)
                        }
                        Link(destination: links.tmdb) { Label("Open on TMDB", systemImage: "arrow.up.forward") }
                            .buttonStyle(.bordered)
                    }
                    if let people = detail?.people, !people.isEmpty {
                        Text("People").font(.headline)
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: AppTheme.Space.m) {
                                ForEach(people) { person in
                                    NavigationLink(value: Route.person(person.id)) {
                                        PersonTile(name: person.name, picture: person.picture, detail: person.character ?? person.role.title, width: 72)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .scrollIndicators(.never)
                    }
                    ForEach(detail?.attribution ?? [], id: \.self) { line in
                        Text(line).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding()
            }
            .navigationTitle(title.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .lobbyDestinations()
        }
        .task { detail = try? await model.outsideTitle(title.tmdb) }
        .frame(minWidth: 420, minHeight: 480)
    }
}
