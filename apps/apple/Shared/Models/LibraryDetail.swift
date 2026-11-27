// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// Whether the viewer has seen something.
enum WatchState: Hashable, Sendable {
    case unwatched
    /// 0…1, or nil when the duration is unknown.
    case inProgress(fraction: Double?)
    case watched

    init(progress: PlaybackProgress?, durationMs: Int?) {
        guard let progress else {
            self = .unwatched
            return
        }
        if progress.completed {
            self = .watched
        } else if progress.positionMs > 0 {
            self = .inProgress(
                fraction: MediaFormat.fraction(positionMs: progress.positionMs, durationMs: durationMs ?? progress.durationMs))
        } else {
            self = .unwatched
        }
    }

    /// For VoiceOver and for the text beside the symbol. Colour is never the only signal.
    var label: String? {
        switch self {
        case .unwatched: nil
        case .inProgress: "Started"
        case .watched: "Watched"
        }
    }
}

/// Everything the Movie screen shows, worked out from the catalogue and the viewer's progress.
struct MovieDetail: Hashable, Sendable {
    var item: Item
    /// "2019", "1 h 42 min".
    var facts: [String]
    /// The household's categories the film is in.
    var categories: [String]
    /// What kind of film it is, from its match (TMDB).
    var genres: [String]
    var overview: String?
    var action: PlayAction
    var watch: WatchState
    /// "28 min left", when part-watched.
    var remaining: String?
    /// Where the film is and what it is: "On Lobby Server", "2.1 GB", "MP4", "1080p".
    var fileFacts: [String]

    init(item: Item, progress: PlaybackProgress?, context: PlaybackContext) {
        self.item = item
        let action = PlayActionBuilder.action(for: item, progress: progress, context: context)
        let duration = item.displayDurationMs
        self.action = action
        facts = [item.year.map(String.init), MediaFormat.runtime(ms: duration)].compactMap { $0 }
        categories = item.categories
        genres = item.genres
        overview = item.overview.flatMap { $0.isEmpty ? nil : $0 }
        watch = WatchState(progress: progress, durationMs: duration)
        if case .inProgress = watch, let progress {
            remaining = MediaFormat.remaining(positionMs: progress.positionMs, durationMs: duration ?? progress.durationMs)
        } else {
            remaining = nil
        }
        fileFacts = Self.fileFacts(
            for: action.request?.file ?? item.mainFiles.first, isOnDevice: context.localCopies[item.id] != nil)
    }

    static func fileFacts(for file: MediaFile?, isOnDevice: Bool = false) -> [String] {
        guard let file else { return [] }
        return [
            isOnDevice ? "On this device and on Lobby Server" : "On Lobby Server",
            MediaFormat.size(bytes: file.sizeBytes),
            file.container.uppercased(),
            MediaFormat.resolution(height: file.video?.height, width: file.video?.width),
        ].compactMap { $0 }
    }
}

/// Everything the Show screen shows.
struct ShowDetail: Hashable, Sendable {
    struct Season: Hashable, Sendable, Identifiable {
        var id: String
        var name: String
        var episodes: [Episode]
    }

    struct Episode: Hashable, Sendable, Identifiable {
        var item: Item
        /// "2. Coastal Worlds".
        var title: String
        var runtime: String?
        var watch: WatchState
        var action: PlayAction

        var id: String { item.id }
    }

    struct Primary: Hashable, Sendable {
        var episode: Item
        var action: PlayAction
        /// "Resume S1 E2", "Play S1 E1".
        var label: String
    }

    var show: Item
    /// "Series", "3 Seasons".
    var facts: [String]
    var categories: [String]
    var genres: [String]
    var overview: String?
    var seasons: [Season]
    /// The episode the big button plays: where the viewer is in the show.
    var primary: Primary?
    /// The season to open on: the one the viewer is in.
    var currentSeasonID: String?
    /// The first episode from its first second, for someone who is further than that.
    var fromBeginning: PlayRequest?
    /// Whether the viewer has seen all of it, some of it or nothing. Specials do not count.
    var watch = WatchState.unwatched

    init(show: Item, catalogue: Catalogue, progress: [String: PlaybackProgress], context: PlaybackContext) {
        self.show = show
        overview = show.overview.flatMap { $0.isEmpty ? nil : $0 }
        categories = show.categories
        genres = show.genres

        seasons = EpisodeOrder.seasons(ofShow: show.id, in: catalogue).compactMap { season in
            let episodes = EpisodeOrder.episodes(ofSeason: season.id, in: catalogue).map { episode in
                Episode(
                    item: episode,
                    title: ItemText.episodeTitle(episode, show: show),
                    runtime: MediaFormat.runtime(ms: episode.displayDurationMs),
                    watch: WatchState(progress: progress[episode.id], durationMs: episode.displayDurationMs),
                    action: PlayActionBuilder.action(
                        for: episode, show: show, progress: progress[episode.id], context: context))
            }
            guard !episodes.isEmpty else { return nil }
            return Season(
                id: season.id,
                name: MediaFormat.seasonName(season.seasonNumber, fallback: season.title),
                episodes: episodes)
        }

        let numbered = seasons.count
        facts = ["Series", numbered == 1 ? "1 Season" : "\(numbered) Seasons", show.year.map(String.init)]
            .compactMap { $0 }

        // Where the viewer is: the same rule as the Continue Watching shelf. Someone who has
        // not started (or has finished everything) gets the first episode.
        let allEpisodes = seasons.flatMap(\.episodes)
        let continuing = Shelves.continueWatching(in: catalogue, progress: progress)
            .first { $0.show?.id == show.id }
        let target = continuing.flatMap { entry in allEpisodes.first { $0.id == entry.item.id } }
            ?? allEpisodes.first

        if let target {
            let code = MediaFormat.episodeCode(season: target.item.seasonNumber, episode: target.item.episodeNumber)
            let verb =
                switch target.action {
                case .play(_, .resume, _): "Resume"
                case .play(_, .playAgain, _): "Play Again"
                default: "Play"
                }
            primary = Primary(
                episode: target.item, action: target.action,
                label: [verb, code].compactMap { $0 }.joined(separator: " "))
            currentSeasonID = seasons.first { $0.episodes.contains { $0.id == target.id } }?.id
        } else {
            primary = nil
            currentSeasonID = seasons.first?.id
        }

        // Specials are no one's first episode, unless there is nothing else.
        let specials = Set(seasons.filter { $0.episodes.first?.item.seasonNumber == 0 }.map(\.id))
        let regular = seasons.filter { !specials.contains($0.id) }.flatMap(\.episodes)
        let counted = regular.isEmpty ? allEpisodes : regular
        if !counted.isEmpty, counted.allSatisfy({ $0.watch == .watched }) {
            watch = .watched
        } else if counted.contains(where: { $0.watch != .unwatched }) {
            watch = .inProgress(fraction: nil)
        }
        if let first = counted.first, primary?.episode.id != first.id || first.watch != .unwatched,
            var request = first.action.request
        {
            request.startPositionMs = 0
            fromBeginning = request
        }
    }
}

/// One card on Continue Watching, ready to draw.
struct ContinueCard: Hashable, Sendable, Identifiable {
    var id: String
    /// The film's title, or the show's for an episode.
    var title: String
    /// "S1 E2 · Coastal Worlds" for an episode.
    var subtitle: String?
    /// "28 min left", or "Next episode" for one that was not started.
    var status: String
    /// The one line under the title on the card: "S1 E2 · 28 min left", or "28 min left".
    var line: String
    /// 0…1, or nil for an episode that was not started.
    var fraction: Double?
    /// What opens when the card is tapped but cannot play: the film, or the show.
    var detailItemID: String
    var action: PlayAction
    var artwork: Artwork?
    /// The title the tile's colour comes from when there is no artwork.
    var tintTitle: String

    init(entry: ContinueWatchingEntry, context: PlaybackContext) {
        let item = entry.item
        id = entry.id
        title = entry.show?.title ?? item.title
        subtitle = item.kind == .episode ? ItemText.episodeLine(item, show: entry.show) : nil
        detailItemID = entry.show?.id ?? item.id
        action = PlayActionBuilder.action(for: item, show: entry.show, progress: entry.progress, context: context)
        artwork = item.artwork.still ?? item.artwork.backdrop ?? entry.show?.artwork.backdrop
        tintTitle = entry.show?.title ?? item.title

        let duration = item.displayDurationMs ?? entry.progress?.durationMs
        if let progress = entry.progress, entry.reason == .resume {
            fraction = MediaFormat.fraction(positionMs: progress.positionMs, durationMs: duration)
            status = MediaFormat.remaining(positionMs: progress.positionMs, durationMs: duration) ?? "Started"
        } else {
            fraction = nil
            status = "Next episode"
        }
        let code = item.kind == .episode
            ? MediaFormat.episodeCode(season: item.seasonNumber, episode: item.episodeNumber) : nil
        line = [code, status].compactMap { $0 }.joined(separator: " · ")
    }

    /// One sentence for VoiceOver.
    var accessibilityLabel: String {
        [title, subtitle, status].compactMap { $0 }.joined(separator: ", ")
    }
}

/// One card on Recently Added, ready to draw.
struct RecentCard: Hashable, Sendable, Identifiable {
    var id: String
    /// The film or the show.
    var title: String
    var year: Int?
    /// "Season 2" and "8 episodes" for a season: the lines under the poster.
    var captionLines: [String]
    /// What tapping opens. A season opens its show on that season.
    var detailItemID: String
    /// A season's series.
    var showID: String?
    var artwork: Artwork?
    /// Stands in while there is no poster.
    var picture: Artwork?

    init(entry: RecentlyAddedEntry) {
        id = entry.id
        switch entry {
        case .item(let item):
            title = item.title
            year = item.year
            captionLines = []
            detailItemID = item.id
            artwork = item.artwork.poster
            picture = item.artwork.backdrop
        case .season(let season, let show, let episodeCount, _):
            title = show?.title ?? season.title
            year = nil
            let name = MediaFormat.seasonName(season.seasonNumber, fallback: season.title)
            captionLines = [name, episodeCount == 1 ? "1 episode" : "\(episodeCount) episodes"]
            detailItemID = season.id
            showID = show?.id
            artwork = season.artwork.poster ?? show?.artwork.poster
            picture = season.artwork.backdrop ?? show?.artwork.backdrop
        }
    }

    var accessibilityLabel: String {
        ([title] + (captionLines.isEmpty ? [year.map(String.init)].compactMap { $0 } : captionLines))
            .joined(separator: ", ")
    }
}

/// The Library screen's rows, built from the device's copy of the catalogue.
struct LibraryShelves: Hashable, Sendable {
    static let recentlyAddedLimit = 30

    var continueWatching: [ContinueCard] = []
    var recentlyAdded: [RecentCard] = []
    /// The main part's films: none of a named part ("Kids") is among them.
    var movies: [Item] = []
    /// The main part's shows.
    var series: [Item] = []
    /// The main part's categories, without the ones that only repeat Movies or Series.
    var categories: [CategoryShelf] = []
    /// The household's named parts of the library, in its order, each with its categories.
    var groups: [LibraryGroup] = []

    static let empty = LibraryShelves()

    init() {}

    /// Continue Watching and Recently Added are across the whole library; Movies, Series and
    /// the categories are by the household's groups.
    init(
        catalogue: Catalogue, groups: CategoryGroups = .none, progress: [String: PlaybackProgress],
        context: PlaybackContext
    ) {
        continueWatching = Shelves.continueWatching(in: catalogue, progress: progress)
            .map { ContinueCard(entry: $0, context: context) }
        recentlyAdded = Shelves.recentlyAdded(in: catalogue, limit: Self.recentlyAddedLimit).map(RecentCard.init)
        let library = Shelves.library(in: catalogue, groups: groups)
        movies = library.movies
        series = library.series
        categories = library.categories
        self.groups = library.groups
    }

    /// A category of the main part or of a named one, also one inside another.
    func category(id: String) -> CategoryShelf? {
        allCategories.first { $0.id == id }
    }

    /// Every category with something in it: the top-level ones, each followed by those inside it.
    var allCategories: [CategoryShelf] {
        (categories + groups.flatMap(\.categories)).flatMap(\.withSubcategories)
    }

    /// The household's categories whose name has every word of `query`, those inside another
    /// among them: a way to a section that is not in the sidebar.
    func categories(matching query: String) -> [CategoryShelf] {
        let fold = { (text: String) in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        return allCategories.filter { shelf in
            shelf.source == .folder && words.allSatisfy { fold(shelf.name).contains($0) }
        }
    }

    func group(id: String) -> LibraryGroup? {
        groups.first { $0.id == id }
    }

    /// The choices above the Library on a phone: All, Movies, Series, then the household's
    /// own parts in its order.
    ///
    /// A pill with nothing behind it is left out, as on a device that shows only its
    /// downloads; Movies and Series stay while the library is empty altogether.
    var filters: [LibraryFilter] {
        let nothingAtAll = movies.isEmpty && series.isEmpty && groups.isEmpty
        return [.all]
            + (movies.isEmpty && !nothingAtAll ? [] : [.movies])
            + (series.isEmpty && !nothingAtAll ? [] : [.series])
            + groups.map { .group($0.id) }
    }

    func title(of filter: LibraryFilter) -> String {
        switch filter {
        case .all: "Home"
        case .movies: "Movies"
        case .series: "Series"
        case .group(let id): group(id: id)?.name ?? ""
        }
    }

    /// `filter`, or All when it names a part of the library that is no longer there.
    func resolved(_ filter: LibraryFilter) -> LibraryFilter {
        filters.contains(filter) ? filter : .all
    }
}

/// What the Library shows on a phone, chosen with the pills under its title.
enum LibraryFilter: Hashable, Sendable {
    /// Continue Watching, Recently Added, Movies, Series and every part of the library.
    case all
    /// The main part's films.
    case movies
    /// The main part's shows.
    case series
    /// A named part of the library, by its id: its categories.
    case group(String)
}
