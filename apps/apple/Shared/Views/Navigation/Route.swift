// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Where a tap in the library leads. Values, so every platform's navigation stack can carry them.
enum Route: Hashable, Sendable {
    /// A film, a show, or a season (which opens its show on that season).
    case item(String)
    case movies
    case series
    case recentlyAdded
    /// A category shelf, by `CategoryShelf.id`.
    case category(String)
    /// A named part of the library, by its id.
    case group(String)
    /// The manager's tools: devices and viewers.
    case manage
    /// The household's categories, for a manager.
    case categories
    /// Access from outside, for a manager.
    case outside
    /// The server's own settings, for a manager.
    case serverSettings
    /// The Apple TVs the server can wake, for a manager.
    case appleTVs
    case speakers
    /// Uploading files to the server, for a manager.
    case uploads
    /// The files of import folders and uploads that wait for a manager.
    case inbox
    /// What happened to imports.
    case importActivity
    /// The households that share the server, for a manager of the owner's.
    case households
    /// One of them, by id.
    case household(String)
    /// What the app is made with.
    case acknowledgements
    /// The servers this app holds: rename, reorder, remove, add.
    case servers
    /// A device's page, for a manager.
    case device(String)
    /// A viewer's page, for a manager.
    case viewer(String)
    /// What a viewer watched and listened to, and when: their own, or a child's for a grown-up.
    case viewerStats(String)
    /// The server's statistics, for a server admin.
    case serverStats
    /// A household's overview, for its admins.
    case householdStats
    /// When and what a kids viewer may do, for a grown-up who decides for it.
    case kidsPlan(String)
    /// A part of the music: its home, artists, albums…
    case music(MusicSection)
    case musicAlbum(String)
    case musicArtist(String)
    case musicBook(String)
    case musicPlaylist(String)
    /// A person from search, by TMDB's id: their titles here, then elsewhere.
    case person(Int)
}

/// The places of the music.
enum MusicSection: String, CaseIterable, Hashable, Sendable {
    case home, artists, albums, songs, books, playlists, favourites

    var title: String {
        switch self {
        case .home: "Music"
        case .artists: "Artists"
        case .albums: "Albums"
        case .songs: "Songs"
        case .books: "Stories"
        case .playlists: "Playlists"
        case .favourites: "Favourites"
        }
    }

    var symbol: String {
        switch self {
        case .home: AppSymbol.music
        case .artists: AppSymbol.artists
        case .albums: AppSymbol.albums
        case .songs: AppSymbol.songs
        case .books: AppSymbol.audiobooks
        case .playlists: AppSymbol.playlists
        case .favourites: AppSymbol.favourite
        }
    }
}

#if !os(tvOS)
extension View {
    /// Teaches a navigation stack to show the library's routes.
    func lobbyDestinations() -> some View {
        navigationDestination(for: Route.self) { RouteView(route: $0).opensPage($0) }
    }
}

struct RouteView: View {
    let route: Route
    @Environment(AppModel.self) private var app

    var body: some View {
        switch route {
        case .item(let id):
            ItemDetailView(itemID: id)
        case .movies:
            BrowseView(scope: .movies, title: "Movies")
        case .series:
            BrowseView(scope: .series, title: "Series")
        case .recentlyAdded:
            RecentlyAddedGridView()
        case .category(let id):
            CategoryPage(id: id)
        case .group(let id):
            GroupView(id: id)
        case .manage:
            ManagerView(model: app.manager())
        case .categories:
            CategoriesView(app: app)
        case .outside:
            OutsideView(app: app)
        case .serverSettings:
            ServerSettingsView(app: app)
        case .appleTVs:
            AppleTVsView(app: app)
        case .speakers:
            SpeakersView(app: app)
        case .uploads:
            UploadsView(app: app)
        case .inbox:
            InboxView(app: app)
        case .importActivity:
            ImportActivityView(app: app)
        case .households:
            HouseholdsView(app: app)
        case .household(let id):
            HouseholdPageView(app: app, householdID: id)
        case .acknowledgements:
            AcknowledgementsView()
        case .servers:
            ServersView()
        case .device(let id):
            DevicePageView(app: app, deviceID: id)
        case .viewer(let id):
            ViewerPageView(app: app, profileID: id)
        case .viewerStats(let id):
            ViewerStatsView(app: app, profileID: id)
        case .serverStats:
            ServerStatsView(app: app)
        case .householdStats:
            ServerStatsView(app: app, scope: .household)
        case .kidsPlan(let id):
            KidsPlanPage(app: app, profileID: id)
        case .music(let section):
            MusicSectionView(section: section)
        case .musicAlbum(let id):
            MusicAlbumView(albumID: id)
        case .musicArtist(let id):
            MusicArtistView(artistID: id)
        case .musicBook(let id):
            MusicBookView(bookID: id)
        case .musicPlaylist(let id):
            MusicPlaylistView(playlistID: id)
        case .person(let id):
            PersonPageView(personID: id)
        }
    }
}

/// Picks the screen for an item: Movie for a film or a home video, Show for a show or a season.
struct ItemDetailView: View {
    let itemID: String
    @Environment(AppModel.self) private var app

    var body: some View {
        if let item = app.item(itemID) {
            switch item.kind {
            case .show:
                ShowDetailView(show: item, initialSeasonID: nil)
            case .season:
                if let show = app.catalogue.show(of: item) {
                    ShowDetailView(show: show, initialSeasonID: item.id)
                } else {
                    missing
                }
            default:
                MovieDetailView(item: item)
            }
        } else {
            missing
        }
    }

    private var missing: some View {
        ContentUnavailableView(
            "No longer in the library", systemImage: "film.stack",
            description: Text("This was removed from Lobby Server."))
    }
}
#endif
