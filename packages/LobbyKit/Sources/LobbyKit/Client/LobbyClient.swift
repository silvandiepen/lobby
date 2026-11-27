// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The connection to one Lobby Server, as `docs/api.md` describes it.
///
/// A value: it holds the address, the device token (if the device is paired) and a `URLSession`.
/// After pairing, make the authenticated client with `authenticated(with:)`.
///
/// The token travels in the `Authorization` header, or in the `lobby_device` cookie for AVPlayer
/// (`deviceCookie()`). It never goes into a URL.
public struct LobbyClient: Sendable {
    public static let deviceCookieName = "lobby_device"

    public let baseURL: URL
    public let token: String?
    /// The road puts the credential on every request itself (`LoopbackServer`): nothing is said to
    /// a port of this device that only this app should have.
    public let isCarriedByRoad: Bool
    private let session: URLSession
    let base: URLComponents

    /// - Parameter baseURL: The server's address, e.g. `http://lobby.local:8484`. Without `/v1`.
    /// - Parameter isCarriedByRoad: The address is this app's own local server.
    public init(
        baseURL: URL, token: String? = nil, session: URLSession = .shared, isCarriedByRoad: Bool = false
    ) throws(LobbyError) {
        guard
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { throw .invalidServerAddress }

        components.query = nil
        components.fragment = nil
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        guard let normalised = components.url else { throw .invalidServerAddress }

        self.baseURL = normalised
        self.base = components
        self.token = token
        self.session = session
        self.isCarriedByRoad = isCarriedByRoad
    }

    private init(baseURL: URL, base: URLComponents, token: String?, session: URLSession, isCarriedByRoad: Bool) {
        self.baseURL = baseURL
        self.base = base
        self.token = token
        self.session = session
        self.isCarriedByRoad = isCarriedByRoad
    }

    /// The same connection with a device token, for after a claim or an approved pairing.
    public func authenticated(with token: String?) -> LobbyClient {
        LobbyClient(baseURL: baseURL, base: base, token: token, session: session, isCarriedByRoad: isCarriedByRoad)
    }

    // MARK: Server

    /// `GET /v1/server`. Open: works before pairing.
    public func serverInfo() async throws -> ServerInfo {
        try await get(["server"])
    }

    /// `GET /v1/server` with its own time limit, for trying one of several addresses.
    func serverInfo(timeout: TimeInterval) async throws -> ServerInfo {
        var request = request("GET", ["server"])
        request.timeoutInterval = timeout
        let (data, _) = try await perform(request)
        return try decode(data)
    }

    /// `GET /v1/me`.
    public func me() async throws -> Me {
        try await get(["me"])
    }

    /// `GET /v1/status`. Manager.
    public func status() async throws -> ServerStatus {
        try await get(["status"])
    }

    // MARK: Pairing and devices

    /// `POST /v1/pairing/claim`: the first manager claims a new server.
    ///
    /// - Parameter setupSecret: What the server printed when it first started, for a server
    ///   whose `ServerInfo.claim` is `.secret`. nil for an `.open` server: nothing is sent.
    public func claim(setupSecret: String? = nil, deviceName: String, platform: DevicePlatform) async throws -> DeviceGrant {
        struct Body: Encodable {
            var setupSecret: String?
            var deviceName: String
            var platform: DevicePlatform
        }
        return try await send("POST", ["pairing", "claim"], body: Body(setupSecret: setupSecret, deviceName: deviceName, platform: platform))
    }

    /// `POST /v1/pairing/requests`: a new device asks to join and shows the returned code.
    public func requestPairing(deviceName: String, platform: DevicePlatform) async throws -> PairingRequest {
        struct Body: Encodable {
            var deviceName: String
            var platform: DevicePlatform
        }
        return try await send("POST", ["pairing", "requests"], body: Body(deviceName: deviceName, platform: platform))
    }

    /// `POST /v1/pairing/requests/{id}/collect`, once.
    public func collectPairing(_ request: PairingRequest) async throws -> PairingCollectResult {
        struct Body: Encodable {
            var pollSecret: String
        }
        struct Answer: Decodable {
            var status: String
            var expiresAt: Date?
            var device: Device?
            var token: String?
        }

        let answer: Answer = try await send(
            "POST", ["pairing", "requests", request.id, "collect"], body: Body(pollSecret: request.pollSecret))
        switch answer.status {
        case "pending":
            return .pending(expiresAt: answer.expiresAt ?? request.expiresAt)
        case "approved":
            guard let device = answer.device, let token = answer.token else {
                throw LobbyError.invalidResponse("An approved pairing came without a device or token.")
            }
            return .approved(DeviceGrant(device: device, token: token))
        default:
            throw LobbyError.invalidResponse("Unknown pairing status \"\(answer.status)\".")
        }
    }

    /// Polls `collect` until a manager approves the request.
    ///
    /// Throws `.gone` when the request expired. A poll that finds the server unreachable is
    /// tried again until the request's own expiry, because the code on screen is still valid.
    ///
    /// - Parameters:
    ///   - interval: The API asks for a poll every two or three seconds.
    ///   - now: The clock, for tests.
    ///   - sleep: The wait between polls, for tests.
    public func awaitPairingApproval(
        of request: PairingRequest,
        pollEvery interval: Duration = .seconds(2),
        now: @Sendable () -> Date = { Date() },
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> DeviceGrant {
        while true {
            do {
                if case .approved(let grant) = try await collectPairing(request) {
                    return grant
                }
            } catch let error as LobbyError where error.isUnreachable {
                if now() >= request.expiresAt { throw error }
            }
            try await sleep(interval)
        }
    }

    /// `GET /v1/pairing/requests`. Manager.
    public func pendingPairingRequests() async throws -> [PendingPairingRequest] {
        struct Answer: Decodable {
            var requests: [PendingPairingRequest]
        }
        let answer: Answer = try await get(["pairing", "requests"])
        return answer.requests
    }

    /// `POST /v1/pairing/approve`. Manager. The manager types the code shown on the new device.
    public func approvePairing(code: String, role: DeviceRole) async throws -> PairingApproval {
        struct Body: Encodable {
            var code: String
            var role: DeviceRole
        }
        return try await send("POST", ["pairing", "approve"], body: Body(code: code, role: role))
    }

    /// `POST /v1/pairing/approve` for a device picked from `pendingPairingRequests`. Manager.
    public func approvePairing(requestID: String, role: DeviceRole) async throws -> PairingApproval {
        struct Body: Encodable {
            var requestId: String
            var role: DeviceRole
        }
        return try await send("POST", ["pairing", "approve"], body: Body(requestId: requestID, role: role))
    }

    /// `GET /v1/devices`. Manager.
    public func devices() async throws -> DeviceList {
        try await get(["devices"])
    }

    /// `DELETE /v1/devices/{id}`. Manager. The last manager cannot be revoked (`.conflict`).
    public func revokeDevice(id: String) async throws {
        try await sendDiscardingAnswer("DELETE", ["devices", id])
    }

    /// `PATCH /v1/devices/{id}`. Manager. Binds a device to a kids viewer, or (nil) frees it.
    public func bindDevice(id: String, toKidsProfile profileID: String?) async throws -> Device {
        struct Body: Encodable {
            var kidsProfileId: String?
            // An explicit null frees the device; a field left out would change nothing.
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(kidsProfileId, forKey: .kidsProfileId)
            }
            enum Key: String, CodingKey { case kidsProfileId }
        }
        return try await send("PATCH", ["devices", id], body: Body(kidsProfileId: profileID))
    }

    // MARK: Profiles

    /// `GET /v1/profiles`.
    public func profiles() async throws -> [Profile] {
        struct Answer: Decodable {
            var profiles: [Profile]
        }
        let answer: Answer = try await get(["profiles"])
        return answer.profiles
    }

    /// `POST /v1/profiles`. Manager.
    ///
    /// - Parameter kids: What a kids viewer may watch. nil: not a kids viewer.
    public func createProfile(name: String, color: String, avatar: String? = nil, kids: KidsSettings? = nil) async throws -> Profile {
        struct Body: Encodable {
            var name: String
            var color: String
            // Left out when nil.
            var avatar: String?
            var kids: KidsSettings?
        }
        return try await send("POST", ["profiles"], body: Body(name: name, color: color, avatar: avatar, kids: kids))
    }

    /// `PATCH /v1/profiles/{id}` with only `kids`. Manager. nil: no kids viewer any more.
    public func setKids(_ kids: KidsSettings?, profileID: String) async throws -> Profile {
        struct Body: Encodable {
            var kids: KidsSettings?
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(kids, forKey: .kids)
            }
            enum Key: String, CodingKey { case kids }
        }
        return try await send("PATCH", ["profiles", profileID], body: Body(kids: kids))
    }

    private struct KidsCode: Codable {
        var set: Bool
    }

    /// `GET /v1/kids/code`: whether the household has a code that leads out of kids mode.
    public func hasKidsCode() async throws -> Bool {
        let answer: KidsCode = try await get(["kids", "code"])
        return answer.set
    }

    /// `PUT /v1/kids/code`. Manager. Four digits, or nil: no code.
    public func setKidsCode(_ code: String?) async throws {
        struct Body: Encodable {
            var code: String?
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(code, forKey: .code)
            }
            enum Key: String, CodingKey { case code }
        }
        let _: KidsCode = try await send("PUT", ["kids", "code"], body: Body(code: code))
    }

    /// `POST /v1/kids/code/check`. `conflict` when there is no code, `rateLimited` after too
    /// many wrong ones.
    public func checkKidsCode(_ code: String) async throws -> Bool {
        struct Body: Encodable { var code: String }
        struct Answer: Decodable { var correct: Bool }
        let answer: Answer = try await send("POST", ["kids", "code", "check"], body: Body(code: code))
        return answer.correct
    }

    /// `PUT /v1/profiles/{id}/avatar`. Any device, for a viewer it may watch as. nil: the letter.
    public func setAvatar(_ avatar: String?, profileID: String) async throws -> Profile {
        struct Body: Encodable {
            var avatar: String?
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(avatar, forKey: .avatar)
            }
            enum Key: String, CodingKey { case avatar }
        }
        return try await send("PUT", ["profiles", profileID, "avatar"], body: Body(avatar: avatar))
    }

    /// `POST /v1/markers/items/{id}/detect`: a server admin has the intros and credits of a
    /// season (or show, or film) looked for again now. Returns how many files will be looked at.
    public func findMarkers(itemID: String) async throws -> Int {
        struct Answer: Decodable { var files: Int }
        let answer: Answer = try await send("POST", ["markers", "items", itemID, "detect"])
        return answer.files
    }

    /// `PUT /v1/profiles/{id}/skipping`: what a viewer wants at intros and credits. Any device
    /// but a child's, for a viewer it may watch as.
    public func setSkipPreferences(_ preferences: SkipPreferences, profileID: String) async throws -> Profile {
        try await send("PUT", ["profiles", profileID, "skipping"], body: preferences)
    }

    /// `PUT /v1/profiles/{id}/subtitles`. Any device, for a viewer it may watch as.
    public func setSubtitlePreferences(_ preferences: SubtitlePreferences, profileID: String) async throws -> Profile {
        try await send("PUT", ["profiles", profileID, "subtitles"], body: preferences)
    }

    /// `PUT /v1/profiles/{id}/playback`: what happens when something ends. Any device for an
    /// ordinary viewer it may watch as; a kids viewer's only from a manager's device.
    public func setPlaybackPreferences(_ preferences: PlaybackPreferences, profileID: String) async throws -> Profile {
        try await send("PUT", ["profiles", profileID, "playback"], body: preferences)
    }

    /// `GET /v1/profiles/{id}/subtitle-offsets/{itemId}`: how far this viewer moved the subtitles
    /// of this title, in milliseconds (negative: earlier). 0 when never.
    public func subtitleOffset(profileID: String, itemID: String) async throws -> Int {
        struct Answer: Decodable { var offsetMs: Int }
        let answer: Answer = try await get(["profiles", profileID, "subtitle-offsets", itemID])
        return answer.offsetMs
    }

    /// `PUT /v1/profiles/{id}/subtitle-offsets/{itemId}`. 0 forgets it.
    public func setSubtitleOffset(_ offsetMs: Int, profileID: String, itemID: String) async throws {
        struct Body: Encodable { var offsetMs: Int }
        struct Answer: Decodable { var offsetMs: Int }
        let _: Answer = try await send("PUT", ["profiles", profileID, "subtitle-offsets", itemID], body: Body(offsetMs: offsetMs))
    }

    /// `PATCH /v1/profiles/{id}`. Manager. Pass only what changes.
    public func updateProfile(id: String, name: String? = nil, color: String? = nil) async throws -> Profile {
        struct Body: Encodable {
            // Optional fields are left out when nil, which is what PATCH wants here.
            var name: String?
            var color: String?
        }
        return try await send("PATCH", ["profiles", id], body: Body(name: name, color: color))
    }

    /// `DELETE /v1/profiles/{id}`. Manager. Removes the profile and its progress.
    public func deleteProfile(id: String) async throws {
        try await sendDiscardingAnswer("DELETE", ["profiles", id])
    }

    // MARK: Library

    /// `GET /v1/library`: one page. `CatalogueStore.sync(using:)` drives the paging.
    ///
    /// - Parameters:
    ///   - cursor: nil for the whole catalogue, or the cursor of the previous response.
    ///   - limit: 1…1000. The server's default is 500.
    public func library(cursor: String?, limit: Int? = nil) async throws -> LibraryPage {
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await get(["library"], query: query)
    }

    /// `GET /v1/categories`: the household's categories, by part of the library, in its order.
    ///
    /// Throws `LobbyError.notFound` on a server that does not have the route yet;
    /// `CategoryGroupsStore.sync(using:)` reads that as "no groups".
    public func categories() async throws -> CategoryGroups {
        try await get(["categories"])
    }

    /// `GET /v1/popular`: what the household watched lately, most first.
    ///
    /// - Parameters:
    ///   - kidsOnly: Only what kids viewers watched. A kids device always gets that.
    ///   - knownTag: The tag of the answer the device already has.
    /// - Returns: The answer and its tag; nil when the known one still holds.
    ///
    /// Throws `LobbyError.notFound` on a server that does not have the route yet;
    /// `PopularStore.sync(using:)` reads that as "nothing known".
    public func popular(kidsOnly: Bool, knownTag: String? = nil) async throws -> (popular: Popular, tag: String?)? {
        var request = request("GET", ["popular"], query: [URLQueryItem(name: "viewers", value: kidsOnly ? "kids" : "all")])
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let knownTag { request.setValue(knownTag, forHTTPHeaderField: "If-None-Match") }
        let (data, http) = try await performAnyStatus(request)
        if http.statusCode == 304 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw LobbyError.from(status: http.statusCode, data: data, headers: http)
        }
        return (try decode(data), http.value(forHTTPHeaderField: "ETag"))
    }

    /// `GET /v1/logos/{id}`: where a category's logo is fetched, with the device's credential
    /// (`authorizedRequest(for:)`).
    public func logoURL(_ logo: CategoryLogo) -> URL {
        url(["logos", logo.id])
    }

    /// `GET /v1/items/{id}`.
    public func item(id: String) async throws -> ItemDetail {
        try await get(["items", id])
    }

    // MARK: Progress

    /// `GET /v1/profiles/{profileId}/progress`.
    ///
    /// - Parameter since: The `revision` of the previous answer, or nil for everything.
    public func progress(profileID: String, since: Int? = nil) async throws -> ProgressList {
        let query = since.map { [URLQueryItem(name: "since", value: String($0))] } ?? []
        return try await get(["profiles", profileID, "progress"], query: query)
    }

    /// `PUT /v1/profiles/{profileId}/progress/{itemId}`.
    ///
    /// Throws `.conflict(message:progress:)` when the server holds a later change: take the
    /// progress it carries. `ProgressStore` does this for queued changes.
    public func putProgress(profileID: String, itemID: String, update: ProgressUpdate) async throws -> PlaybackProgress {
        struct Answer: Decodable {
            var progress: PlaybackProgress
        }
        let answer: Answer = try await send("PUT", ["profiles", profileID, "progress", itemID], body: update)
        return answer.progress
    }

    // MARK: Media

    /// `/v1/assets/{assetId}/content`: the file's bytes, with byte-range support.
    ///
    /// For AVPlayer, pass `deviceCookie()` through `AVURLAssetHTTPCookiesKey`. For `URLSession`
    /// (downloads), use `authorizedRequest(for:)`.
    public func mediaURL(assetID: String) -> URL {
        url(["assets", assetID, "content"])
    }

    /// A request for a media, artwork or subtitle URL of this server, with the bearer header.
    public func authorizedRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token, !isCarriedByRoad {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// The `lobby_device` cookie that carries the token for APIs that cannot set headers.
    ///
    ///     AVURLAsset(url: client.mediaURL(assetID: id),
    ///                options: [AVURLAssetHTTPCookiesKey: [cookie]])
    ///
    /// nil when the client has no token, or the road carries it.
    public func deviceCookie() -> HTTPCookie? {
        guard let token, !isCarriedByRoad, let host = base.host else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: Self.deviceCookieName,
            .value: token,
            .domain: host,
            .path: "/",
            // No script of a page may read it, wherever it ends up.
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ]
        if base.scheme?.lowercased() == "https" {
            properties[.secure] = "TRUE"
        }
        return HTTPCookie(properties: properties)
    }

    // MARK: Requests

    /// A URL under `/v1`. Every segment is percent-encoded, so an opaque id cannot change the path.
    func url(_ segments: [String], query: [URLQueryItem] = []) -> URL {
        var components = base
        let encoded = segments.map { $0.addingPercentEncoding(withAllowedCharacters: .lobbyPathSegment) ?? $0 }
        components.percentEncodedPath = base.percentEncodedPath + "/v1/" + encoded.joined(separator: "/")
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            // `init` proved the base is an http(s) URL with a host, and the path added here is
            // absolute and percent-encoded, so URLComponents always has a URL for it.
            preconditionFailure("LobbyClient could not build a URL for \(segments)")
        }
        return url
    }

    /// A path the server returned (e.g. a prepared playback URL), resolved against this server.
    func resolve(serverPath: String) -> URL? {
        // Below the address's own path, if it has one.
        guard serverPath.hasPrefix("/"), !serverPath.hasPrefix("//") else {
            return URL(string: serverPath, relativeTo: baseURL)?.absoluteURL
        }
        return URL(string: baseURL.absoluteString + serverPath)
    }

    func get<Answer: Decodable>(_ segments: [String], query: [URLQueryItem] = []) async throws -> Answer {
        let (data, _) = try await perform(request("GET", segments, query: query))
        return try decode(data)
    }

    func send<Body: Encodable, Answer: Decodable>(_ method: String, _ segments: [String], body: Body) async throws -> Answer {
        var request = request(method, segments)
        request.httpBody = try LobbyJSON.encoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await perform(request)
        return try decode(data)
    }

    func send<Answer: Decodable>(_ method: String, _ segments: [String]) async throws -> Answer {
        let (data, _) = try await perform(request(method, segments))
        return try decode(data)
    }

    func sendDiscardingAnswer(_ method: String, _ segments: [String]) async throws {
        _ = try await perform(request(method, segments))
    }

    /// The bytes behind a URL of this server that is not JSON, e.g. a subtitle.
    func data(at url: URL) async throws -> Data {
        var request = authorizedRequest(for: url)
        request.httpMethod = "GET"
        return try await perform(request).0
    }

    func request(_ method: String, _ segments: [String], query: [URLQueryItem] = []) -> URLRequest {
        var request = authorizedRequest(for: url(segments, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: Downloads a manager puts on a device

    /// `GET /v1/me/wanted`: what a manager wants on this device.
    ///
    /// - Parameter knownRevision: The revision of the list the device already has.
    /// - Returns: nil when the list is still that one.
    public func myWanted(knownRevision: String? = nil) async throws -> DeviceWantedList? {
        var request = request("GET", ["me", "wanted"])
        if let knownRevision {
            request.setValue("\"\(knownRevision)\"", forHTTPHeaderField: "If-None-Match")
        }
        let (data, http) = try await performAnyStatus(request)
        if http.statusCode == 304 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw LobbyError.from(status: http.statusCode, data: data, headers: http)
        }
        return try decode(data)
    }

    /// `POST /v1/me/downloads`: says what this device has. Replaces the previous report.
    ///
    /// - Returns: The revision of this device's wanted list now.
    @discardableResult
    public func reportDownloads(_ report: DownloadsReport) async throws -> String {
        struct Answer: Decodable {
            var wantedRevision: String
        }
        let answer: Answer = try await send("POST", ["me", "downloads"], body: report)
        return answer.wantedRevision
    }

    /// `GET /v1/devices/wanted` (manager): one line per device.
    public func devicesWanted() async throws -> [DeviceWantedSummary] {
        struct Answer: Decodable {
            var devices: [DeviceWantedSummary]
        }
        let answer: Answer = try await get(["devices", "wanted"])
        return answer.devices
    }

    /// `GET /v1/devices/{id}/wanted` (manager): everything about one device's list.
    public func deviceWanted(deviceID: String) async throws -> DeviceWantedDetail {
        try await get(["devices", deviceID, "wanted"])
    }

    /// `POST /v1/devices/{id}/wanted` (manager): puts a film, episode, season or show on a device.
    @discardableResult
    public func addWanted(deviceID: String, itemID: String) async throws -> WantedEntry {
        struct Body: Encodable {
            var kind = "item"
            var itemId: String
        }
        struct Answer: Decodable {
            var entry: WantedEntry
        }
        let answer: Answer = try await send("POST", ["devices", deviceID, "wanted"], body: Body(itemId: itemID))
        return answer.entry
    }

    /// `POST /v1/devices/{id}/wanted` (manager): keeps the next `count` episodes a viewer has
    /// not watched on a device. Saying it again sets the new count.
    @discardableResult
    public func addWantedNextEpisodes(deviceID: String, showID: String, profileID: String, count: Int) async throws -> WantedEntry {
        struct Body: Encodable {
            var kind = "next_unwatched"
            var showId: String
            var profileId: String
            var count: Int
        }
        struct Answer: Decodable {
            var entry: WantedEntry
        }
        let answer: Answer = try await send(
            "POST", ["devices", deviceID, "wanted"], body: Body(showId: showID, profileId: profileID, count: count))
        return answer.entry
    }

    /// `DELETE /v1/devices/{id}/wanted/{wantedId}` (manager).
    public func removeWanted(deviceID: String, wantedID: String) async throws {
        try await sendDiscardingAnswer("DELETE", ["devices", deviceID, "wanted", wantedID])
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, http) = try await performAnyStatus(request)
        guard (200..<300).contains(http.statusCode) else {
            throw LobbyError.from(status: http.statusCode, data: data, headers: http)
        }
        return (data, http)
    }

    /// The answer whatever its status: for a call where one that is not 2xx means something.
    func performAnyStatus(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw LobbyError.unreachable(error.code)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LobbyError.invalidResponse("The answer was not HTTP.")
        }
        return (data, http)
    }

    func decode<Answer: Decodable>(_ data: Data) throws -> Answer {
        do {
            return try LobbyJSON.decoder().decode(Answer.self, from: data)
        } catch {
            throw LobbyError.invalidResponse(String(describing: error))
        }
    }
}

extension CharacterSet {
    /// RFC 3986 unreserved characters: what may appear in one path segment as it is.
    static let lobbyPathSegment = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
