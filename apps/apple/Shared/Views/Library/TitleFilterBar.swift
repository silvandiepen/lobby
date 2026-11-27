// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The films and series of a list, filtered and ordered as the viewer chose for that list:
/// the chips go above, `content` is given what passes. Remembered per list and viewer.
///
/// A page of its own hosts it around its grid: Movies, Series, a category or a genre, search
/// results, Downloads.
struct FilteredTitles<Content: View>: View {
    /// Stable for the list: "movies", "category:<id>", "search".
    let list: String
    let items: [Item]
    /// What every title of the list has in common, so it is not offered: a list of films
    /// offers no Kind, Downloads no Downloaded.
    var fixed: Set<TitleFilterPart> = []
    @ViewBuilder var content: (_ titles: [Item]) -> Content

    @Environment(AppModel.self) private var app

    var body: some View {
        let choice = app.titleChoice(for: list)
        let titles = app.titles(items, list: list)
        let binding = Binding { app.titleChoice(for: list) } set: { app.setTitleChoice($0, for: list) }
        VStack(alignment: .leading, spacing: AppTheme.Space.m) {
            if app.isKidsMode {
                KidsFilterChips(choice: binding, count: titles.count)
            } else {
                TitleFilterChips(items: items, fixed: fixed, choice: binding, count: titles.count)
            }
            if titles.isEmpty, !choice.filter.isEmpty {
                ContentUnavailableView {
                    Label("Nothing like that", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No title here passes these filters.")
                } actions: {
                    Button("Clear Filters") { binding.wrappedValue.filter = .none }
                }
                .frame(maxWidth: .infinity)
            } else {
                content(titles)
            }
        }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !app.isKidsMode { TitleFilterMenu(items: items, fixed: fixed, choice: binding) }
            }
        }
        #endif
    }
}

/// The parts of a filter, for what a list leaves out.
enum TitleFilterPart: Hashable, Sendable {
    case kind, downloaded, category
}

/// The most used filters as chips under the title: Filters, Sort, Year, Genre, Unwatched. The
/// rest is in the Filters sheet.
struct TitleFilterChips: View {
    let items: [Item]
    var fixed: Set<TitleFilterPart> = []
    @Binding var choice: TitleChoice
    let count: Int

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsSheet = false

    var body: some View {
        let options = TitleQuery.options(of: items, context: app.titleQueryContext)
        ScrollView(.horizontal) {
            HStack(spacing: AppTheme.Space.s) {
                FilterChip(
                    title: choice.filter.isEmpty ? "Filters" : "Filters · \(choice.filter.count)",
                    symbol: "line.3.horizontal.decrease", isOn: !choice.filter.isEmpty
                ) { showsSheet = true }
                    .accessibilityIdentifier("filters.open")
                sortMenu
                if options.decades.count > 1 || choice.filter.yearFrom != nil || choice.filter.yearTo != nil {
                    yearMenu(options)
                }
                if options.genres.count > 1 || !choice.filter.genres.isEmpty { genreMenu(options) }
                FilterChip(title: "Unwatched", isOn: choice.filter.watch == [.unwatched]) {
                    choice.filter.watch = choice.filter.watch == [.unwatched] ? [] : [.unwatched]
                }
                .accessibilityIdentifier("filters.unwatched")
                Text(TitleText.count(count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.leading, AppTheme.Space.xs)
                    .accessibilityIdentifier("filters.count")
                if !choice.filter.isEmpty {
                    Button("Clear") { choice.filter = .none }
                        .buttonStyle(.lobbyText)
                        .accessibilityIdentifier("filters.clear")
                }
            }
            .padding(.horizontal, TileMetrics.margin(sizeClass))
        }
        .scrollIndicators(.never)
        .sensoryFeedback(.selection, trigger: choice)
        .sheet(isPresented: $showsSheet) {
            TitleFilterSheet(options: options, fixed: fixed, categories: categories, choice: $choice, count: count)
        }
    }

    /// The categories of the list's titles, by name.
    private var categories: [(id: String, name: String)] {
        guard !fixed.contains(.category) else { return [] }
        let ids = Set(items.flatMap { ($0.categoryIds ?? []) + ($0.ruleCategoryIds ?? []) })
        return ids.compactMap { id in app.categoryName(id).map { (id, $0) } }.sorted { $0.name < $1.name }
    }

    private var sortMenu: some View {
        Menu {
            TitleSortPicker(choice: $choice)
        } label: {
            FilterChipLabel(
                title: choice.sort.key.title, symbol: choice.sort.ascending ? "arrow.up" : "arrow.down",
                isOn: choice.sort != .byTitle, isMenu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.lobbyPill)
        .accessibilityLabel("Sort by \(choice.sort.key.title), \(choice.sort.key.direction(ascending: choice.sort.ascending))")
        .accessibilityIdentifier("filters.sort")
    }

    private func yearMenu(_ options: TitleFilterOptions) -> some View {
        Menu {
            Button("Any Year") { choice.filter.setDecade(nil) }
            Divider()
            ForEach(options.decades.reversed(), id: \.self) { decade in
                Toggle(TitleText.decade(decade), isOn: Binding {
                    choice.filter.decade == decade
                } set: { on in
                    choice.filter.setDecade(on ? decade : nil)
                })
            }
        } label: {
            FilterChipLabel(title: TitleText.years(choice.filter) ?? "Year", isOn: choice.filter.yearFrom != nil || choice.filter.yearTo != nil, isMenu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.lobbyPill)
        .accessibilityIdentifier("filters.year")
    }

    private func genreMenu(_ options: TitleFilterOptions) -> some View {
        Menu {
            Button("Any Genre") { choice.filter.genres = [] }
            Divider()
            ForEach(options.genres.prefix(20), id: \.self) { name in
                Toggle(name, isOn: Binding {
                    choice.filter.genres.contains(name)
                } set: { on in
                    if on { choice.filter.genres.insert(name) } else { choice.filter.genres.remove(name) }
                })
            }
        } label: {
            let genres = choice.filter.genres.sorted()
            FilterChipLabel(
                title: genres.count == 1 ? genres[0] : genres.isEmpty ? "Genre" : "\(genres.count) Genres",
                isOn: !genres.isEmpty, isMenu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.lobbyPill)
        .accessibilityIdentifier("filters.genre")
    }
}

/// Order by, then which way.
struct TitleSortPicker: View {
    @Binding var choice: TitleChoice

    var body: some View {
        Picker("Sort By", selection: Binding { choice.sort.key } set: { choice.sort = TitleSort($0) }) {
            ForEach(TitleSortKey.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        Picker("Order", selection: $choice.sort.ascending) {
            Text(choice.sort.key.direction(ascending: true)).tag(true)
            Text(choice.sort.key.direction(ascending: false)).tag(false)
        }
        .pickerStyle(.inline)
    }
}

/// A chip that turns a filter on and off.
struct FilterChip: View {
    let title: String
    var symbol: String?
    let isOn: Bool
    let action: () -> Void
    @Environment(\.motion) private var motion

    var body: some View {
        Button {
            withAnimation(motion.animation(.section)) { action() }
        } label: {
            FilterChipLabel(title: title, symbol: symbol, isOn: isOn)
        }
        .buttonStyle(.lobbyPill)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct FilterChipLabel: View {
    let title: String
    var symbol: String?
    let isOn: Bool
    var isMenu = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: AppTheme.Space.xs) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(title)
            if isMenu { Image(systemName: "chevron.down").imageScale(.small).font(.caption.weight(.semibold)) }
        }
        .font(.subheadline.weight(isOn ? .semibold : .regular))
        .foregroundStyle(isOn ? Color.lobbyOnAccent : Color.primary)
        .padding(.horizontal, AppTheme.Space.m + 2)
        .frame(minHeight: 34)
        .background(isOn ? Color.lobbyAccent(.dark) : Color.lobbyChip(scheme), in: Capsule())
        .contentShape(Capsule())
    }
}

/// Every filter of a list, and its order.
struct TitleFilterSheet: View {
    let options: TitleFilterOptions
    var fixed: Set<TitleFilterPart> = []
    var categories: [(id: String, name: String)] = []
    @Binding var choice: TitleChoice
    let count: Int

    var body: some View {
        LobbySheet(title: "Filters", width: 460, height: 620) {
            Form {
                Section("Sort") { TitleSortPicker(choice: $choice) }
                if !fixed.contains(.kind), options.kinds.count > 1 {
                    Section("Kind") {
                        ForEach(options.kinds, id: \.self) { toggle($0.title, $0, in: \.kinds) }
                    }
                }
                Section("Watched") {
                    ForEach(TitleWatchState.allCases, id: \.self) { toggle($0.title, $0, in: \.watch) }
                }
                if let years = options.years {
                    Section("Year") {
                        Picker("Decade", selection: Binding { choice.filter.decade } set: { choice.filter.setDecade($0) }) {
                            Text("Any").tag(Int?.none)
                            ForEach(options.decades.reversed(), id: \.self) { Text(TitleText.decade($0)).tag(Int?.some($0)) }
                        }
                        Stepper(value: yearBinding(\.yearFrom, default: years.lowerBound), in: years) {
                            LabeledContent("From", value: choice.filter.yearFrom.map(String.init) ?? "Any")
                        }
                        Stepper(value: yearBinding(\.yearTo, default: years.upperBound), in: years) {
                            LabeledContent("Until", value: choice.filter.yearTo.map(String.init) ?? "Any")
                        }
                    }
                }
                if !options.genres.isEmpty {
                    Section("Genre") { ForEach(options.genres, id: \.self) { toggle($0, $0, in: \.genres) } }
                }
                if !options.lengths.isEmpty {
                    Section("Length") {
                        ForEach(options.lengths, id: \.self) { length in
                            Toggle(isOn: member(length, in: \.lengths)) {
                                LabeledContent(length.title, value: length.detail)
                            }
                        }
                    }
                }
                Section("Added") {
                    Picker("Added", selection: $choice.filter.added) {
                        Text("Any Time").tag(AddedWithin?.none)
                        ForEach(AddedWithin.allCases, id: \.self) { Text($0.title).tag(AddedWithin?.some($0)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if !categories.isEmpty {
                    Section("Category") {
                        ForEach(categories, id: \.id) { toggle($0.name, $0.id, in: \.categories) }
                    }
                }
                if !options.studios.isEmpty {
                    Section("Studio") { ForEach(options.studios) { toggle($0.name, $0.id, in: \.studios) } }
                }
                if options.hasUHD || !fixed.contains(.downloaded) && options.hasDownloads {
                    Section("Copy") {
                        if options.hasUHD { toggle("4K", .uhd, in: \.quality) }
                        if !fixed.contains(.downloaded), options.hasDownloads {
                            Toggle("On This Device", isOn: $choice.filter.downloaded)
                        }
                    }
                }
                if options.languages.count > 1 {
                    Section("Audio Language") {
                        ForEach(options.languages, id: \.self) { toggle(TitleText.language($0), $0, in: \.languages) }
                    }
                }
                Section {
                    Button("Clear Filters", role: .destructive) { choice.filter = .none }
                        .disabled(choice.filter.isEmpty)
                } footer: {
                    Text(TitleText.count(count))
                }
            }
            .formStyle(.grouped)
        }
        .accessibilityIdentifier("filters.sheet")
    }

    private func toggle<Value: Hashable>(
        _ title: String, _ value: Value, in path: WritableKeyPath<TitleFilter, Set<Value>>
    ) -> some View {
        Toggle(title, isOn: member(value, in: path))
    }

    private func member<Value: Hashable>(_ value: Value, in path: WritableKeyPath<TitleFilter, Set<Value>>) -> Binding<Bool> {
        Binding {
            choice.filter[keyPath: path].contains(value)
        } set: { on in
            if on { choice.filter[keyPath: path].insert(value) } else { choice.filter[keyPath: path].remove(value) }
        }
    }

    private func yearBinding(_ path: WritableKeyPath<TitleFilter, Int?>, default value: Int) -> Binding<Int> {
        Binding { choice.filter[keyPath: path] ?? value } set: { choice.filter[keyPath: path] = $0 }
    }
}

#if os(macOS)
/// The Mac's toolbar: order and every filter in one menu, beside the chips.
struct TitleFilterMenu: View {
    let items: [Item]
    var fixed: Set<TitleFilterPart> = []
    @Binding var choice: TitleChoice
    @Environment(AppModel.self) private var app

    var body: some View {
        let options = TitleQuery.options(of: items, context: app.titleQueryContext)
        Menu {
            Section("Sort By") { TitleSortPicker(choice: $choice) }
            Section("Watched") {
                ForEach(TitleWatchState.allCases, id: \.self) { state in
                    Toggle(state.title, isOn: member(state, in: \.watch))
                }
            }
            if !options.lengths.isEmpty {
                Menu("Length") {
                    ForEach(options.lengths, id: \.self) { Toggle("\($0.title) (\($0.detail))", isOn: member($0, in: \.lengths)) }
                }
            }
            if !options.decades.isEmpty {
                Menu("Year") {
                    Button("Any Year") { choice.filter.setDecade(nil) }
                    ForEach(options.decades.reversed(), id: \.self) { decade in
                        Toggle(TitleText.decade(decade), isOn: Binding { choice.filter.decade == decade } set: {
                            choice.filter.setDecade($0 ? decade : nil)
                        })
                    }
                }
            }
            if !options.genres.isEmpty {
                Menu("Genre") { ForEach(options.genres, id: \.self) { Toggle($0, isOn: member($0, in: \.genres)) } }
            }
            Menu("Added") {
                Picker("Added", selection: $choice.filter.added) {
                    Text("Any Time").tag(AddedWithin?.none)
                    ForEach(AddedWithin.allCases, id: \.self) { Text($0.title).tag(AddedWithin?.some($0)) }
                }
                .pickerStyle(.inline)
            }
            if !options.studios.isEmpty {
                Menu("Studio") { ForEach(options.studios) { Toggle($0.name, isOn: member($0.id, in: \.studios)) } }
            }
            if !fixed.contains(.kind), options.kinds.count > 1 {
                Menu("Kind") { ForEach(options.kinds, id: \.self) { Toggle($0.title, isOn: member($0, in: \.kinds)) } }
            }
            if options.hasUHD { Toggle("4K", isOn: member(.uhd, in: \.quality)) }
            if !fixed.contains(.downloaded), options.hasDownloads {
                Toggle("On This Device", isOn: $choice.filter.downloaded)
            }
            if options.languages.count > 1 {
                Menu("Audio Language") {
                    ForEach(options.languages, id: \.self) { Toggle(TitleText.language($0), isOn: member($0, in: \.languages)) }
                }
            }
            Divider()
            Button("Clear Filters") { choice.filter = .none }
                .disabled(choice.filter.isEmpty)
        } label: {
            Label("Filter and Sort", systemImage: choice.filter.isEmpty
                ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Filter and sort")
        .accessibilityIdentifier("filters.menu")
    }

    private func member<Value: Hashable>(_ value: Value, in path: WritableKeyPath<TitleFilter, Set<Value>>) -> Binding<Bool> {
        Binding {
            choice.filter[keyPath: path].contains(value)
        } set: { on in
            if on { choice.filter[keyPath: path].insert(value) } else { choice.filter[keyPath: path].remove(value) }
        }
    }
}
#endif

/// Kids mode: a few big, colourful filters, and the order by title or newest.
struct KidsFilterChips: View {
    @Binding var choice: TitleChoice
    let count: Int
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.motion) private var motion

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: AppTheme.Space.m) {
                ForEach(KidsTitleFilter.allCases, id: \.self) { kind in
                    let isOn = kind.isOn(in: choice.filter)
                    Button {
                        withAnimation(motion.animation(.section)) { kind.toggle(in: &choice.filter) }
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(isOn ? Color.white : Color.lobbyProfile(kind.color))
                            .padding(.horizontal, AppTheme.Space.l)
                            .frame(minHeight: 52)
                            .background(Color.lobbyProfile(kind.color).opacity(isOn ? 1 : 0.18), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.lobbyPill)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityIdentifier("kids.filter.\(kind.rawValue)")
                }
                let newest = choice.sort.key == .added
                Button {
                    withAnimation(motion.animation(.section)) { choice.sort = newest ? .byTitle : TitleSort(.added) }
                } label: {
                    Label(newest ? "Newest" : "A to Z", systemImage: newest ? "clock" : "textformat")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, AppTheme.Space.l)
                        .frame(minHeight: 52)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.lobbyPill)
                .accessibilityLabel(newest ? "Newest first" : "A to Z")
                .accessibilityIdentifier("kids.filter.sort")
            }
            .padding(.horizontal, TileMetrics.margin(sizeClass))
        }
        .scrollIndicators(.never)
        .accessibilityValue(TitleText.count(count))
    }
}
