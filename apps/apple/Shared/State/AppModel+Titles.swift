// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// Filtering and ordering the lists of films and series: Movies, Series, a category, a genre,
/// search results and Downloads. The logic is LobbyKit's `TitleQuery`, on the device's copy of
/// the catalogue, so a list filters the same with the server out of reach.
extension AppModel {
    /// What the lists are filtered with now.
    var titleQueryContext: TitleQueryContext {
        TitleQueryContext(
            catalogue: catalogue, progress: progress, groups: categoryGroups,
            downloaded: Set(downloads.values.filter(\.isPlayable).map(\.itemID)), popular: popularOrder, now: Date())
    }

    /// What `list` was last filtered and ordered by, by the viewer watching now.
    func titleChoice(for list: String) -> TitleChoice {
        let viewer = activeProfile?.id
        if let made = titleChoiceCache[Self.choiceKey(list, viewer)] { return made }
        return environment.settings.titleChoices.choice(for: list, viewer: viewer) ?? TitleChoice()
    }

    func setTitleChoice(_ choice: TitleChoice, for list: String) {
        let viewer = activeProfile?.id
        titleChoiceCache[Self.choiceKey(list, viewer)] = choice
        environment.settings.titleChoices.save(choice, for: list, viewer: viewer)
    }

    /// `items` as `list` is filtered and ordered now.
    func titles(_ items: [Item], list: String) -> [Item] {
        let choice = titleChoice(for: list)
        if choice == TitleChoice() { return items }
        return TitleQuery.apply(choice.filter, sort: choice.sort, to: items, context: titleQueryContext)
    }

    /// The name of a category by id, for a chip.
    func categoryName(_ id: String) -> String? {
        categoryGroups.groups.lazy.flatMap(\.entries).first { $0.id == id }?.name
    }

    private static func choiceKey(_ list: String, _ viewer: String?) -> String {
        "\(viewer ?? "-")|\(list)"
    }
}

/// The few big filters of kids mode.
enum KidsTitleFilter: String, CaseIterable, Hashable, Sendable {
    case short, new, notSeen

    var title: String {
        switch self {
        case .short: "Short"
        case .new: "New"
        case .notSeen: "Not seen yet"
        }
    }

    var symbol: String {
        switch self {
        case .short: "timer"
        case .new: "sparkles"
        case .notSeen: "eye.slash"
        }
    }

    /// A colour name of the app's palette.
    var color: String {
        switch self {
        case .short: "teal"
        case .new: "orange"
        case .notSeen: "purple"
        }
    }

    func isOn(in filter: TitleFilter) -> Bool {
        switch self {
        case .short: filter.lengths == [.short]
        case .new: filter.added == .month
        case .notSeen: filter.watch == [.unwatched]
        }
    }

    func toggle(in filter: inout TitleFilter) {
        let on = isOn(in: filter)
        switch self {
        case .short: filter.lengths = on ? [] : [.short]
        case .new: filter.added = on ? nil : .month
        case .notSeen: filter.watch = on ? [] : [.unwatched]
        }
    }
}

extension TitleSortKey {
    var title: String {
        switch self {
        case .title: "Title"
        case .year: "Year"
        case .added: "Date Added"
        case .popular: "Popular"
        case .length: "Length"
        case .rating: "Rating"
        }
    }

    /// The words of each way: "A to Z", "Newest First".
    func direction(ascending: Bool) -> String {
        switch self {
        case .title: ascending ? "A to Z" : "Z to A"
        case .year: ascending ? "Oldest First" : "Newest First"
        case .added: ascending ? "Longest Here First" : "Newest First"
        case .popular: ascending ? "Least Watched First" : "Most Watched First"
        case .length: ascending ? "Shortest First" : "Longest First"
        case .rating: ascending ? "Lowest First" : "Highest First"
        }
    }
}

extension TitleLength {
    var title: String {
        switch self {
        case .short: "Short"
        case .standard: "Standard"
        case .long: "Long"
        }
    }

    var detail: String {
        switch self {
        case .short: "Under 40 min"
        case .standard: "40 min to 2½ h"
        case .long: "Over 2½ h"
        }
    }
}

extension TitleWatchState {
    var title: String {
        switch self {
        case .unwatched: "Unwatched"
        case .inProgress: "In Progress"
        case .watched: "Watched"
        }
    }
}

extension AddedWithin {
    var title: String {
        switch self {
        case .week: "This Week"
        case .month: "This Month"
        case .year: "This Year"
        }
    }
}

extension TitleKind {
    var title: String {
        switch self {
        case .movie: "Films"
        case .show: "Series"
        case .personal: "Home Videos"
        }
    }
}

enum TitleText {
    /// "12 titles".
    static func count(_ count: Int) -> String {
        count == 1 ? "1 title" : "\(count) titles"
    }

    /// "1990s".
    static func decade(_ decade: Int) -> String { "\(decade)s" }

    /// "English" for "eng", or the code when the device does not know it.
    static func language(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    /// The chip of the years chosen: "1990s", "2000–2010", "From 2000".
    static func years(_ filter: TitleFilter) -> String? {
        if let decade = filter.decade { return Self.decade(decade) }
        switch (filter.yearFrom, filter.yearTo) {
        case (let from?, let to?): return from == to ? "\(from)" : "\(from)–\(to)"
        case (let from?, nil): return "From \(from)"
        case (nil, let to?): return "Until \(to)"
        case (nil, nil): return nil
        }
    }
}
