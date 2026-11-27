// SPDX-License-Identifier: MPL-2.0
/// What a tap on the kids screens leads to: a film, a series, or one of the categories.
struct KidsRoute: Hashable, Sendable {
    var itemID = ""
    /// `CategoryShelf.id`. Then there is no film or series.
    var categoryID: String? = nil
    /// Opened from On here: a series shows only the episodes on this device.
    var onlyOnDevice = false
}

/// The four places of the kids screens.
enum KidsSection: String, CaseIterable, Hashable, Sendable {
    case home, movies, series, onHere

    var theme: KidsTheme.Section {
        switch self {
        case .home: .home
        case .movies: .movies
        case .series: .series
        case .onHere: .onHere
        }
    }

    /// On the tab.
    var name: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .series: "Series"
        case .onHere: "On here"
        }
    }

    var symbol: String {
        switch self {
        case .home: AppSymbol.library
        case .movies: AppSymbol.movies
        case .series: AppSymbol.series
        case .onHere: AppSymbol.downloads
        }
    }
}
