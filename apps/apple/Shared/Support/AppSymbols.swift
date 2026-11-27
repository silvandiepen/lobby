// SPDX-License-Identifier: MPL-2.0
import LobbyKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The one table of symbols: one SF Symbol per meaning, used by every button, pill, heading
/// and row that means it. A new meaning gets its line here, not a literal at the call site.
enum AppSymbol {
    // MARK: Places
    static let library = "house.fill"
    static let everything = "square.grid.2x2.fill"
    static let movies = "movieclapper.fill"
    static let series = "tv.fill"
    static let downloads = "arrow.down.circle.fill"
    static let search = "magnifyingglass"
    static let devices = "person.2.badge.gearshape.fill"
    static let settings = "gearshape"
    static let server = "server.rack"
    /// The households that share the server.
    static let households = "house.and.flag.fill"
    static let viewers = "person.2.fill"
    static let thisDevice = phone
    static let category = "folder.fill"
    static let genre = "tag.fill"
    static let music = "music.note"
    static let artists = "music.microphone"
    static let albums = "square.stack.fill"
    static let songs = "music.note.list"
    static let audiobooks = "book.closed.fill"
    static let playlists = "list.bullet.rectangle.portrait.fill"
    static let favourite = "heart.fill"

    // MARK: Devices
    static let phone = "iphone"
    static let pad = "ipad"
    static let mac = "macbook"
    static let television = "appletv"
    static let playOn = "airplayvideo"
    static let trailer = "film"
    static let commandLine = "terminal"
    static let space = "internaldrive"
    static let seen = "clock"
    static let info = "info.circle"
    static let update = "arrow.down.app"

    // MARK: States
    static let done = "checkmark.circle.fill"
    static let underway = "arrow.down.circle.dotted"
    static let problem = "exclamationmark.circle"

    // MARK: Actions
    static let edit = "pencil"
    static let picture = "person.crop.circle"
    static let putBack = "arrow.uturn.backward"
    static let noMatch = "nosign"
    static let frame = "film"
    static let reorder = "line.3.horizontal"
    static let moveUp = "arrow.up"
    static let moveDown = "arrow.down"
    static let photos = "photo.on.rectangle"
    static let folder = "externaldrive"
    static let categories = "square.grid.2x2"
    static let sendToDevice = "ipad.and.arrow.forward"
    static let nextEpisodes = "list.number"
    static let play = "play.fill"
    static let startOver = "arrow.counterclockwise"
    static let markWatched = "checkmark.circle"
    static let markUnwatched = "circle"
    static let download = "arrow.down.circle"
    static let remove = "trash"
    static let add = "plus"
    static let approve = "checkmark.circle"
    static let outside = "globe"
    static let reconnecting = "arrow.triangle.2.circlepath"
    static let road = "point.topleft.down.to.point.bottomright.curvepath"
    static let scan = "qrcode.viewfinder"
    static let acknowledgements = "doc.text"
    static let approveAsManager = "person.badge.key.fill"
    static let refresh = "arrow.clockwise"
    static let copy = "doc.on.doc"
    static let setUp = "wand.and.stars"
    static let pair = "link"
    static let enterAddress = "keyboard"
    static let onThisNetwork = "wifi"
    static let secret = "key.fill"
    static let back = "chevron.backward"
    static let sayIt = "speaker.wave.2.fill"
    static let kids = "face.smiling.fill"
    static let blocked = "nosign"
    static let signOut = "rectangle.portrait.and.arrow.right"
    static let more = "ellipsis"
    static let waiting = "hourglass"
    static let upload = "arrow.up.circle"
    static let inbox = "tray.full"
    static let importFolder = "folder.badge.plus"
    static let pause = "pause.circle"
    static let resume = "play.circle"

    // MARK: The household's own parts and categories

    // Categories and groups are the household's settings. Their symbol, colour and logo come
    // from the server; nothing about them is decided here by name. Without one, or with a
    // name this system has no symbol for, they get these.
    static let group = "square.stack.fill"
    /// A category inside another, and putting one there.
    static let inside = "arrow.turn.down.right"
    static let takeOut = "arrow.up.left"
    static let undo = "arrow.uturn.backward.circle"
    static let studio = "building.2"

    /// `name` when this system has a symbol of that name, nil otherwise: a symbol the
    /// household typed, or one from a newer system, must not leave an empty space.
    static func existing(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        #if canImport(UIKit)
        return UIImage(systemName: name) == nil ? nil : name
        #else
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? nil : name
        #endif
    }

    /// The pill above the Library.
    static func filter(_ filter: LibraryFilter, groupSymbol: (String) -> String?) -> String {
        switch filter {
        case .all: library
        case .movies: movies
        case .series: series
        case .group(let id): groupSymbol(id) ?? group
        }
    }
}
