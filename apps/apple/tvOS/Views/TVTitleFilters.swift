// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The films and series of a list on the TV, filtered and ordered as the viewer chose for it:
/// one row of large buttons above, `content` given what passes. A swipe on the remote, or on
/// the Remote app, moves along the row one button at a time; down leaves it for the titles.
struct TVFilteredTitles<Content: View>: View {
    let list: String
    let items: [Item]
    var fixed: Set<TVFilterPart> = []
    @ViewBuilder var content: (_ titles: [Item]) -> Content

    @Environment(AppModel.self) private var app

    var body: some View {
        let titles = app.titles(items, list: list)
        let choice = Binding { app.titleChoice(for: list) } set: { app.setTitleChoice($0, for: list) }
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            if app.isKidsMode {
                TVKidsFilterRow(choice: choice, count: titles.count)
            } else {
                TVFilterRow(items: items, fixed: fixed, choice: choice, count: titles.count)
            }
            if titles.isEmpty, !choice.wrappedValue.filter.isEmpty {
                TVDeadEnd(title: "Nothing like that", symbol: "line.3.horizontal.decrease.circle", text: "No title here passes these filters.")
            } else {
                content(titles)
            }
        }
    }
}

enum TVFilterPart: Hashable, Sendable {
    case kind, category
}

/// Sort, Year, Genre, Unwatched and Filters, as large buttons in one row.
struct TVFilterRow: View {
    let items: [Item]
    var fixed: Set<TVFilterPart> = []
    @Binding var choice: TitleChoice
    let count: Int

    @Environment(AppModel.self) private var app
    @State private var showsAll = false

    var body: some View {
        let options = TitleQuery.options(of: items, context: app.titleQueryContext)
        ScrollView(.horizontal) {
            HStack(spacing: AppTheme.Space.l) {
                Menu {
                    Picker("Sort By", selection: Binding { choice.sort.key } set: { choice.sort = TitleSort($0) }) {
                        ForEach(TitleSortKey.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Order", selection: $choice.sort.ascending) {
                        Text(choice.sort.key.direction(ascending: true)).tag(true)
                        Text(choice.sort.key.direction(ascending: false)).tag(false)
                    }
                } label: {
                    label("Sort: \(choice.sort.key.title)", symbol: choice.sort.ascending ? "arrow.up" : "arrow.down", isOn: choice.sort != .byTitle)
                }
                .accessibilityIdentifier("filters.sort")
                if options.decades.count > 1 || choice.filter.yearFrom != nil {
                    Menu {
                        Button("Any Year") { choice.filter.setDecade(nil) }
                        ForEach(options.decades.reversed(), id: \.self) { decade in
                            Button(TitleText.decade(decade)) { choice.filter.setDecade(decade) }
                        }
                    } label: {
                        label(TitleText.years(choice.filter) ?? "Year", symbol: "calendar", isOn: choice.filter.yearFrom != nil)
                    }
                    .accessibilityIdentifier("filters.year")
                }
                if options.genres.count > 1 || !choice.filter.genres.isEmpty {
                    Menu {
                        Button("Any Genre") { choice.filter.genres = [] }
                        ForEach(options.genres.prefix(20), id: \.self) { name in
                            Button(name) { choice.filter.genres = [name] }
                        }
                    } label: {
                        label(choice.filter.genres.sorted().first ?? "Genre", symbol: "theatermasks", isOn: !choice.filter.genres.isEmpty)
                    }
                    .accessibilityIdentifier("filters.genre")
                }
                Button {
                    choice.filter.watch = choice.filter.watch == [.unwatched] ? [] : [.unwatched]
                } label: {
                    label("Unwatched", symbol: "eye.slash", isOn: choice.filter.watch == [.unwatched])
                }
                .accessibilityIdentifier("filters.unwatched")
                Button {
                    showsAll = true
                } label: {
                    label(choice.filter.isEmpty ? "Filters" : "Filters · \(choice.filter.count)", symbol: "line.3.horizontal.decrease", isOn: !choice.filter.isEmpty)
                }
                .accessibilityIdentifier("filters.open")
                if !choice.filter.isEmpty {
                    Button("Clear") { choice.filter = .none }
                        .accessibilityIdentifier("filters.clear")
                }
                Text(TitleText.count(count))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("filters.count")
            }
            .padding(.vertical, AppTheme.Space.m)
        }
        .scrollClipDisabled()
        .focusSection()
        .sheet(isPresented: $showsAll) {
            TVFilterList(options: options, fixed: fixed, choice: $choice, count: count)
        }
    }

    private func label(_ title: String, symbol: String, isOn: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline.weight(isOn ? .bold : .regular))
            .foregroundStyle(isOn ? Color.lobbyAccent(.dark) : Color.primary)
            .padding(.horizontal, AppTheme.Space.s)
    }
}

/// Every filter, as a list a remote goes down.
private struct TVFilterList: View {
    let options: TitleFilterOptions
    var fixed: Set<TVFilterPart>
    @Binding var choice: TitleChoice
    let count: Int

    var body: some View {
        NavigationStack {
            List {
                if !fixed.contains(.kind), options.kinds.count > 1 {
                    Section("Kind") { ForEach(options.kinds, id: \.self) { toggle($0.title, $0, in: \.kinds) } }
                }
                Section("Watched") { ForEach(TitleWatchState.allCases, id: \.self) { toggle($0.title, $0, in: \.watch) } }
                if !options.lengths.isEmpty {
                    Section("Length") {
                        ForEach(options.lengths, id: \.self) { toggle("\($0.title) · \($0.detail)", $0, in: \.lengths) }
                    }
                }
                Section("Added") {
                    ForEach(AddedWithin.allCases, id: \.self) { added in
                        Toggle(added.title, isOn: Binding { choice.filter.added == added } set: { choice.filter.added = $0 ? added : nil })
                    }
                }
                if !options.decades.isEmpty {
                    Section("Decade") {
                        ForEach(options.decades.reversed(), id: \.self) { decade in
                            Toggle(TitleText.decade(decade), isOn: Binding { choice.filter.decade == decade } set: {
                                choice.filter.setDecade($0 ? decade : nil)
                            })
                        }
                    }
                }
                if !options.genres.isEmpty {
                    Section("Genre") { ForEach(options.genres, id: \.self) { toggle($0, $0, in: \.genres) } }
                }
                if !options.studios.isEmpty {
                    Section("Studio") { ForEach(options.studios) { toggle($0.name, $0.id, in: \.studios) } }
                }
                if options.hasUHD {
                    Section("Picture") { toggle("4K", .uhd, in: \.quality) }
                }
                if options.languages.count > 1 {
                    Section("Audio Language") {
                        ForEach(options.languages, id: \.self) { toggle(TitleText.language($0), $0, in: \.languages) }
                    }
                }
                Section {
                    Button("Clear Filters") { choice.filter = .none }
                        .disabled(choice.filter.isEmpty)
                } footer: {
                    Text(TitleText.count(count))
                }
            }
            .navigationTitle("Filters")
        }
        .accessibilityIdentifier("filters.sheet")
    }

    private func toggle<Value: Hashable>(_ title: String, _ value: Value, in path: WritableKeyPath<TitleFilter, Set<Value>>) -> some View {
        Toggle(title, isOn: Binding {
            choice.filter[keyPath: path].contains(value)
        } set: { on in
            if on { choice.filter[keyPath: path].insert(value) } else { choice.filter[keyPath: path].remove(value) }
        })
    }
}

/// Kids mode on the TV: three big, colourful filters and the order.
struct TVKidsFilterRow: View {
    @Binding var choice: TitleChoice
    let count: Int

    var body: some View {
        HStack(spacing: TVMetrics.gap) {
            ForEach(KidsTitleFilter.allCases, id: \.self) { kind in
                let isOn = kind.isOn(in: choice.filter)
                Button {
                    kind.toggle(in: &choice.filter)
                } label: {
                    Label(kind.title, systemImage: kind.symbol)
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(isOn ? Color.white : Color.lobbyProfile(kind.color))
                        .padding(.horizontal, AppTheme.Space.l)
                        .padding(.vertical, AppTheme.Space.s)
                }
                .buttonStyle(.bordered)
                .tint(Color.lobbyProfile(kind.color).opacity(isOn ? 1 : 0.35))
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("kids.filter.\(kind.rawValue)")
            }
            let newest = choice.sort.key == .added
            Button {
                choice.sort = newest ? .byTitle : TitleSort(.added)
            } label: {
                Label(newest ? "Newest" : "A to Z", systemImage: newest ? "clock" : "textformat")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .padding(.horizontal, AppTheme.Space.l)
                    .padding(.vertical, AppTheme.Space.s)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("kids.filter.sort")
        }
        .padding(.vertical, AppTheme.Space.m)
        .focusSection()
        .accessibilityValue(TitleText.count(count))
    }
}
