// SPDX-License-Identifier: MPL-2.0
import Foundation

// `/v1/search…` (docs/api.md, Search).
extension LobbyClient {
    /// `GET /v1/search`: the library, by words and the query language.
    ///
    /// - Parameter profileID: The viewer searching; a kids viewer's limits then hold, also on a
    ///   device without limits of its own.
    public func search(_ query: String, profileID: String?, limit: Int = 30) async throws -> SearchAnswer {
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]
        if let profileID { items.append(URLQueryItem(name: "profile", value: profileID)) }
        return try await get(["search"], query: items)
    }

    /// `GET /v1/search/outside`: films, shows and people at TMDB that are not in the library.
    public func searchOutside(_ query: String, profileID: String?) async throws -> OutsideAnswer {
        var items = [URLQueryItem(name: "q", value: query)]
        if let profileID { items.append(URLQueryItem(name: "profile", value: profileID)) }
        return try await get(["search", "outside"], query: items)
    }

    /// `GET /v1/search/outside/{type}/{id}`: one of those, with its people and every rating.
    public func outsideTitle(_ reference: TMDBReference, profileID: String?) async throws -> OutsideTitleDetail {
        let items = profileID.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        return try await get(["search", "outside", reference.type.rawValue, String(reference.id)], query: items)
    }

    /// `GET /v1/search/people/{id}`: a person's titles here, then elsewhere.
    public func person(_ id: Int, profileID: String?) async throws -> PersonPage {
        let items = profileID.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        return try await get(["search", "people", String(id)], query: items)
    }

    /// `GET /v1/search/picture?path=`: a poster or a person's picture from TMDB, through the
    /// server, with the device's credential (`authorizedRequest(for:)`).
    public func searchPictureURL(path: String) -> URL {
        url(["search", "picture"], query: [URLQueryItem(name: "path", value: path)])
    }

    /// The bytes of such a picture.
    public func searchPicture(path: String) async throws -> Data {
        try await data(at: searchPictureURL(path: path))
    }
}
