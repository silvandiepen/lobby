// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Observation

/// The search screen's state: the filter chips, the server's answer for the library and for
/// what is beyond it, and the viewer's recent searches. The field's text is the screen's; this
/// is told what it is (`search(text:)`).
///
/// Without the server the screen shows `AppModel.search(_:)`, titles from the device's copy.
@MainActor
@Observable
final class SearchModel {
    /// What the model asks; the app's connection, or a stand-in in the tests.
    struct Asking: Sendable {
        var library: @Sendable (_ query: String, _ profileID: String?) async throws -> SearchAnswer
        var outside: @Sendable (_ query: String, _ profileID: String?) async throws -> OutsideAnswer
        var person: @Sendable (_ id: Int, _ profileID: String?) async throws -> PersonPage
        var title: @Sendable (_ reference: TMDBReference, _ profileID: String?) async throws -> OutsideTitleDetail
    }

    enum Phase: Equatable {
        case idle
        case searching
        case done
        /// The server could not answer: the device's own titles stand in.
        case failed
    }

    var filters = SearchFilters.none
    private(set) var answer: SearchAnswer?
    private(set) var outside: OutsideAnswer?
    private(set) var phase = Phase.idle
    /// What `answer` was asked with.
    private(set) var answeredQuery = ""
    private(set) var recent = RecentSearches()

    /// Whether the viewer may look beyond the library: never in kids mode.
    var lookBeyond: Bool
    private let asking: Asking?
    private let store: RecentSearchStore
    private var viewer: String?

    init(asking: Asking?, store: RecentSearchStore, viewer: String?, lookBeyond: Bool) {
        self.asking = asking
        self.store = store
        self.viewer = viewer
        self.lookBeyond = lookBeyond
        recent = store.load(viewer: viewer)
    }

    /// What is sent for this text with the chips as they are.
    func query(text: String) -> String {
        filters.query(text: text)
    }

    /// Whether there is anything to ask: words, or a chip that is on.
    func asksAnything(text: String) -> Bool {
        !query(text: text).isEmpty
    }

    /// Another viewer is watching now: their own recent searches.
    func setViewer(_ viewer: String?, lookBeyond: Bool) {
        guard viewer != self.viewer || lookBeyond != self.lookBeyond else { return }
        self.viewer = viewer
        self.lookBeyond = lookBeyond
        recent = store.load(viewer: viewer)
        if !lookBeyond { outside = nil }
    }

    /// Asks the server about the library, then about what is beyond it. Meant to run in a task
    /// that is replaced while typing: a newer search cancels this one.
    func search(text: String) async {
        let query = query(text: text)
        guard !query.isEmpty else {
            answer = nil
            outside = nil
            answeredQuery = ""
            phase = .idle
            return
        }
        guard let asking else {
            phase = .failed
            return
        }
        phase = .searching
        do {
            let found = try await asking.library(query, viewer)
            try Task.checkCancellation()
            answer = found
            answeredQuery = query
            phase = .done
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            answer = nil
            phase = .failed
            return
        }
        guard lookBeyond else {
            outside = nil
            return
        }
        // TMDB is slower and counts against the server's allowance: only once the typing stops.
        do {
            try await Task.sleep(for: .milliseconds(400))
            let beyond = try await asking.outside(query, viewer)
            try Task.checkCancellation()
            outside = beyond
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            outside = nil
        }
    }

    /// A search the viewer finished, kept to offer again.
    func remember(text: String) {
        let query = query(text: text)
        recent.add(query)
        store.save(recent, viewer: viewer)
    }

    func forget(_ query: String) {
        recent.remove(query)
        store.save(recent, viewer: viewer)
    }

    func forgetAll() {
        recent.clear()
        store.save(recent, viewer: viewer)
    }

    /// Takes a filter the server understood out of what was typed.
    func removing(_ filter: UnderstoodFilter, from text: String) -> String {
        guard let range = text.range(of: filter.token) else { return text }
        var changed = text
        changed.removeSubrange(range)
        return changed.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    func person(_ id: Int) async throws -> PersonPage {
        guard let asking else { throw LobbyError.unreachable(.notConnectedToInternet) }
        return try await asking.person(id, viewer)
    }

    func outsideTitle(_ reference: TMDBReference) async throws -> OutsideTitleDetail {
        guard let asking, lookBeyond else { throw LobbyError.unreachable(.notConnectedToInternet) }
        return try await asking.title(reference, viewer)
    }

    /// Whether the answer shown is for this text.
    func isCurrent(text: String) -> Bool {
        answer != nil && answeredQuery == query(text: text)
    }
}

extension AppModel {
    /// A search screen's model, asking over this app's connection as the viewer watching now.
    func makeSearchModel() -> SearchModel {
        let asking = SearchModel.Asking(
            library: { [weak self] query, profile in
                guard let client = await self?.searchConnection else { throw LobbyError.unreachable(.notConnectedToInternet) }
                return try await client.search(query, profileID: profile)
            },
            outside: { [weak self] query, profile in
                guard let client = await self?.searchConnection else { throw LobbyError.unreachable(.notConnectedToInternet) }
                return try await client.searchOutside(query, profileID: profile)
            },
            person: { [weak self] id, profile in
                guard let client = await self?.searchConnection else { throw LobbyError.unreachable(.notConnectedToInternet) }
                return try await client.person(id, profileID: profile)
            },
            title: { [weak self] reference, profile in
                guard let client = await self?.searchConnection else { throw LobbyError.unreachable(.notConnectedToInternet) }
                return try await client.outsideTitle(reference, profileID: profile)
            })
        return SearchModel(
            asking: asking, store: environment.settings.recentSearches, viewer: activeProfile?.id,
            lookBeyond: !isKidsMode)
    }
}
