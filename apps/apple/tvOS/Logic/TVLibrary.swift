// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// The places of the TV app. The household's own parts of the library come from the server.
enum TVTab: Hashable, Sendable {
    case search
    case home
    case movies
    case series
    case group(String)
    case viewer
    /// The household's music: browse and play.
    case music
    /// A child's stories and music, while it may listen.
    case stories

    static func all(for shelves: LibraryShelves, hasMusic: Bool = false) -> [TVTab] {
        [.viewer, .search, .home] + shelves.filters.compactMap { filter in
            switch filter {
            case .all: nil
            case .movies: .movies
            case .series: .series
            case .group(let id): .group(id)
            }
        } + (hasMusic ? [.music] : [])
    }

    /// A child's places. No search, and nothing about the household. Stories while it may
    /// listen; in Only listening nothing else but its own page.
    static func kids(for library: KidsLibrary, listens: Bool = false, onlyListening: Bool = false) -> [TVTab] {
        if onlyListening, listens { return [.viewer, .stories] }
        return [.viewer, .home] + (listens ? [.stories] : []) + (library.movies.isEmpty ? [] : [.movies])
            + (library.series.isEmpty ? [] : [.series])
    }

    /// Where a child lands: the stories when there is nothing to watch now.
    static func kidsStart(in tabs: [TVTab]) -> TVTab {
        tabs.contains(.home) ? .home : tabs.contains(.stories) ? .stories : .viewer
    }

    /// `self`, or Home when it names a part of the library that is no longer there.
    func resolved(for shelves: LibraryShelves, hasMusic: Bool = false) -> TVTab {
        Self.all(for: shelves, hasMusic: hasMusic).contains(self) ? self : .home
    }
}

/// The rows of a page, in the order they stand on screen, for where the remote was.
enum TVHome {
    static func rows(of page: BrowsePage) -> [FocusMemory.Row] {
        page.rows.map { row in
            switch row.content {
            case .categories(let categories): .init(shelf: row.id, items: categories.map(\.id))
            // Two seasons of one series are two cards.
            case .recent(let cards): .init(shelf: row.id, items: cards.map(\.id))
            case .continuing, .items: .init(shelf: row.id, items: row.titleIDs)
            }
        }
        .filter { !$0.items.isEmpty }
    }
}

/// Which of the two ways the film is on screen: in the system's player, or under the app's own
/// controls.
enum TVPlayerSurface: Hashable, Sendable {
    /// `AVPlayerViewController`.
    case system
    /// The picture with the app's own words and buttons: nothing to play yet, a failure, the
    /// end of an episode, or a copy that is still being written, which the system's transport
    /// would show as a live broadcast.
    case own

    init(stage: PlayerModel.Stage, isBeingPrepared: Bool) {
        switch stage {
        case .playing: self = isBeingPrepared ? .own : .system
        case .loading, .preparing, .ended, .failed: self = .own
        }
    }
}

/// The pairing code, written to be read across a room: "482 913".
enum PairingCodeText {
    static func grouped(_ code: String) -> String {
        guard code.count >= 6, code.count.isMultiple(of: 2) else { return code }
        let middle = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<middle]) \(code[middle...])"
    }
}

extension AppModel {
    /// How long until the server is asked again. A TV stays on one screen for hours: no
    /// network change and no app switch makes it look.
    nonisolated static func secondsUntilNextLook(outOfReach: Bool, hasLibrary: Bool) -> Int {
        outOfReach || !hasLibrary ? 15 : 300
    }

    /// Runs for as long as the app is on screen: finds the server again by itself when it was
    /// out of reach, and picks up what is new. Not while a film plays: the link is the film's.
    func watchServer() async {
        while !Task.isCancelled {
            let wait = Self.secondsUntilNextLook(outOfReach: connectivity == .offline, hasLibrary: hasLibraryCopy)
            do { try await environment.sleep(.seconds(wait)) } catch { return }
            guard player == nil, phase == .library || phase == .chooseProfile else { continue }
            await refresh()
        }
    }
}
