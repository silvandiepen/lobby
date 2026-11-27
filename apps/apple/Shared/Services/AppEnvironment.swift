// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import LobbyPush

/// How this device introduces itself when it pairs.
struct DeviceIdentity: Hashable, Sendable {
    var name: String
    var platform: DevicePlatform
}

/// Everything the app model needs from outside itself. One per app, made at launch.
///
/// Tests build one with a stubbed `URLSession`, an in-memory credential store and files in a
/// temporary folder. The stores, the client and the queue are the real ones either way.
struct AppEnvironment: Sendable {
    var catalogueStore: CatalogueStore
    /// The household's parts of the library ("Kids") and their categories, kept for offline.
    var categoryGroupsStore: CategoryGroupsStore
    /// What the household watches, for the home page, kept for offline.
    var popularStore: PopularStore
    var progressStore: ProgressStore
    var credentials: any CredentialStore
    /// The keys servers seal pushes with through the relay, shared with the notification
    /// service extension (docs/decisions.md, "Push through a relay").
    var pushKeys: any PushKeyStore = InMemoryPushKeyStore()
    var preferences: ConnectionPreferences
    var settings: LocalSettings
    var artwork: ArtworkLoader
    var downloads: DownloadManager
    /// Uploads to the server (a manager's iPhone, iPad or Mac). nil: this device does not upload.
    var uploads: UploadQueue? = nil
    #if os(iOS)
    /// The background session the uploads' pieces go through, for a background launch.
    var uploadPieces: BackgroundPieceTransport? = nil
    #endif
    /// Music's library, viewers' own, books and downloads. nil: none kept between launches.
    var music: MusicStorage? = nil
    var session: URLSession
    var device: DeviceIdentity
    var capabilities: DeviceCapabilities
    /// Looks for Lobby Servers on the local network (Bonjour), and works out the address of
    /// one that was found. Tests put their own network here, as they do for HTTP.
    var discover: @Sendable () -> AsyncStream<DiscoveryUpdate> = { ServerBrowser.updates() }
    var addressOfDiscovered: @Sendable (DiscoveredServer) async throws -> URL = { try await ServerBrowser.address(of: $0) }
    /// How long the home address gets to answer once the server answered at another one.
    var locateGrace: @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) }
    /// How long one of the server's addresses gets to answer at all.
    var locateTimeout: TimeInterval = 4
    /// Chooses between home, Tailscale and the direct connection. nil: only the addresses.
    var road: ServerRoad?
    /// False on the Apple TV: tvOS gives an app no lasting storage, so nothing is downloaded,
    /// and the library stays whole while the server is out of reach.
    var keepsDownloads = true
    /// Asks for a grown-up before kids mode is left: Face ID, Touch ID or the passcode. A
    /// platform without kids screens has no such question, and nobody passes it there.
    var hasKidsScreens = false
    var confirmGrownUp: @Sendable () async -> GrownUpCheck = { .unavailable }
    /// How a kids viewer's places are followed. nil: the device's Location.
    var followPlaces: KidsPlaceWatcher.Follow?
    /// Asks who is watching when the app opens, as `LocalSettings.viewerQuestion` says: a TV
    /// is everybody's.
    var asksWhoIsWatching = false
    var now: @Sendable () -> Date = { Date() }
    /// Where the signed copy of a kids viewer's plan is kept for offline; nil: only in memory.
    var kidsPlanURL: URL? = nil
    /// Whether the App Store has a newer Lobby. Asks nothing unless set.
    var updates = UpdateSource.none
    /// The wait between two polls (pairing approval, a file being prepared).
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// Where the real app keeps its servers.
    ///
    /// - Parameter namespace: Keeps a second copy of the app's state apart from the one a person
    ///   uses: its own preferences, Keychain service and files. The test runs pass
    ///   `-lobby-namespace <name>`; a person's copy has none.
    static func accountsStore(namespace: String? = nil) throws -> ServerAccountsStore {
        var directory = try LobbyStorage.defaultDirectory()
        var caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        if let namespace {
            directory.append(path: namespace, directoryHint: .isDirectory)
            caches.append(path: namespace, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let suffix = namespace.map { ".\($0)" } ?? ""
        return ServerAccountsStore(
            root: directory, caches: caches, base: bundleID + suffix, legacySuite: namespace.map { _ in bundleID + suffix })
    }

    static let bundleID = "mt.sil.lobby"

    /// The downloads of one server: a background session of its own, so the system carries
    /// on with them while the app is not running or uses another server. One per account for
    /// as long as the app runs: a background session's identifier may be in use once.
    static func liveDownloads(of account: ServerAccount, in store: ServerAccountsStore) throws -> DownloadManager {
        DownloadManager(
            directory: LobbyStorage.downloadsDirectory(in: try store.directory(of: account)),
            sessionConfiguration: backgroundDownloads(identifier: account.storage.downloadsSession))
    }

    #if os(iOS) || os(macOS)
    /// The uploads of one server (a manager's iPhone, iPad or Mac).
    struct LiveUploads {
        var queue: UploadQueue
        #if os(iOS)
        /// The background session its pieces go through.
        var pieces: BackgroundPieceTransport
        #endif
    }

    /// Each server's uploads, by account id. One per account for as long as the app runs, like
    /// its downloads: a background session's identifier may be in use once, and one queue
    /// writes its file. Switching away leaves them to go on with the server they were sent to.
    @MainActor private static var uploadsByAccount: [String: LiveUploads] = [:]

    /// The background session of an account's uploads: beside its downloads' one.
    static func uploadsSession(of account: ServerAccount) -> String {
        let downloads = account.storage.downloadsSession
        return downloads.hasSuffix(".downloads") ? String(downloads.dropLast(".downloads".count)) + ".uploads" : downloads + ".uploads"
    }

    @MainActor
    static func liveUploads(of account: ServerAccount, directory: URL, caches: URL) -> LiveUploads {
        if let known = uploadsByAccount[account.id] { return known }
        let pieces = caches.appending(path: "UploadPieces", directoryHint: .isDirectory)
        #if os(iOS)
        // Pieces go on in the background; the queue is kept so they go on after a relaunch too.
        let transport = BackgroundPieceTransport(identifier: uploadsSession(of: account), orphaned: {})
        let made = LiveUploads(
            queue: UploadQueue(
                storeFile: directory.appending(path: "Uploads/queue.json", directoryHint: .notDirectory),
                pieceDirectory: pieces, transport: transport),
            pieces: transport)
        #else
        // The Mac uploads while the app is open, from the files as they are.
        let made = LiveUploads(queue: UploadQueue(storeFile: nil, pieceDirectory: pieces, transport: SessionPieceTransport()))
        #endif
        uploadsByAccount[account.id] = made
        return made
    }

    /// Stops a removed server's uploads and forgets its queue.
    @MainActor
    static func forgetUploads(of account: ServerAccount) async {
        guard let known = uploadsByAccount.removeValue(forKey: account.id) else { return }
        await known.queue.setClient(nil)
    }
    #endif

    /// The environment of the real app, for one of its servers.
    @MainActor
    static func live(
        account: ServerAccount, in store: ServerAccountsStore, downloads: DownloadManager, device: DeviceIdentity
    ) throws -> AppEnvironment {
        let directory = try store.directory(of: account)
        let caches = store.cachesDirectory(of: account) ?? directory.appending(path: "Caches", directoryHint: .isDirectory)
        let suite = account.storage.defaultsSuite
        #if os(tvOS)
        // A wall of posters on a slow link must not keep "how do I play this?" waiting behind
        // it: pictures get connections of their own, and few of them.
        let pictures = URLSessionConfiguration.default
        pictures.httpMaximumConnectionsPerHost = 3
        let artworkSession = URLSession(configuration: pictures)
        #else
        let artworkSession = URLSession.shared
        #endif
        var environment = AppEnvironment(
            catalogueStore: CatalogueStore(fileURL: LobbyStorage.catalogueFile(in: directory)),
            categoryGroupsStore: CategoryGroupsStore(fileURL: LobbyStorage.categoriesFile(in: directory)),
            popularStore: PopularStore(fileURL: LobbyStorage.popularFile(in: directory)),
            progressStore: ProgressStore(fileURL: LobbyStorage.progressFile(in: directory)),
            credentials: KeychainCredentialStore(service: account.storage.keychainService),
            preferences: ConnectionPreferences(suiteName: suite),
            settings: LocalSettings(suiteName: suite),
            artwork: ArtworkLoader(
                directory: caches.appending(path: "Artwork", directoryHint: .isDirectory),
                // Beside the catalogue, not in Caches: these have to be there without the server.
                keptDirectory: directory.appending(path: "DownloadArtwork", directoryHint: .isDirectory),
                session: artworkSession),
            downloads: downloads,
            session: .shared,
            device: device,
            capabilities: .current())
        environment.music = MusicStorage(directory: directory.appending(path: "Music", directoryHint: .isDirectory))
        environment.kidsPlanURL = directory.appending(path: "kids-plan.json")
        environment.pushKeys = KeychainPushKeyStore.shared(service: "\(account.storage.keychainService).push")
        #if os(iOS) || os(macOS)
        let uploads = liveUploads(of: account, directory: directory, caches: caches)
        environment.uploads = uploads.queue
        #if os(iOS)
        environment.uploadPieces = uploads.pieces
        #endif
        #endif
        environment.road = ServerRoad(
            credentials: environment.credentials, memory: RoadMemory(suiteName: suite),
            usesDirect: environment.settings.usesDirect)
        environment.updates = .live(suiteName: suite)
        environment.hasKidsScreens = true
        #if !os(tvOS)
        environment.confirmGrownUp = { await GrownUpGate.ask() }
        #endif
        #if os(tvOS)
        environment.keepsDownloads = false
        environment.asksWhoIsWatching = true
        // Abroad, the first packets over a tailnet can take longer than at home.
        environment.locateTimeout = 10
        #endif
        return environment
    }
}

extension AppEnvironment {
    /// Which of the server's addresses works from where the device is now, home first. nil
    /// when it answers at none. An address where another server answers is never returned.
    func locate(_ connection: SavedConnection) async -> URL? {
        await ServerLocator.locate(
            serverID: connection.serverID, among: connection.candidates, session: session, timeout: locateTimeout,
            grace: locateGrace)
    }

    /// Where the server answers now and over which road. Without a road of its own, the addresses.
    func find(_ connection: SavedConnection, token: String) async -> ServerRoad.Found? {
        if let road { return await road.find(connection, token: token) { await locate(connection) } }
        guard let url = await locate(connection), let client = try? LobbyClient(baseURL: url, token: token, session: session)
        else { return nil }
        return ServerRoad.Found(road: ServerRoad.road(of: url, in: connection), client: client)
    }

    /// A background session: the system carries on with a download while the app is not
    /// running, and starts the app again to hand over the result.
    static func backgroundDownloads(identifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        // The viewer asked for it now: not when the system finds a convenient moment.
        configuration.isDiscretionary = false
        return configuration
    }

    /// Tells the paired server to send this device no more pushes, while the credential is
    /// still there. Only a try, at the address last used: a server out of reach keeps the token
    /// until the device is removed there, and it never pushes to a removed device.
    func unregisterPush() async {
        #if os(iOS) || os(macOS)
        guard let saved = preferences.connection,
            let token = try? await credentials.token(forServer: saved.serverID),
            let client = try? LobbyClient(baseURL: saved.serverAddress, token: token, session: session)
        else { return }
        do {
            try await client.unregisterPush()
        } catch {
            // Out of reach, or a server without push: nothing more to do from here.
        }
        #endif
    }

    /// Removes the credential, the preferences and every stored file.
    func forgetEverything() async throws {
        if let serverID = preferences.connection?.serverID {
            try await credentials.removeToken(forServer: serverID)
            await road?.forget(serverID: serverID)
            #if os(iOS) || os(macOS)
            // The relay forgets this device's handle, and the Keychain the server's push key.
            await PushRegistrar(keys: pushKeys).forget(serverID: serverID)
            #endif
        }
        try await credentials.removeToken(forServer: AppModel.pendingPairingKey)
        preferences.connection = nil
        preferences.activeProfileID = nil
        settings.removeAll()
        try await catalogueStore.clear()
        try await categoryGroupsStore.clear()
        try await popularStore.clear()
        try await progressStore.clear()
        await artwork.clear()
        await downloads.removeAll()
        await uploads?.removeAll()
        try await music?.clear()
        updates.memory.clear()
    }
}

/// What the app remembers beside LobbyKit's `ConnectionPreferences`. Preferences only: the
/// device token is in the Keychain.
struct LocalSettings: Sendable {
    private static let addressKey = "lobby.lastServerAddress"
    private static let profilesKey = "lobby.cachedProfiles"
    private static let deviceKey = "lobby.cachedDevice"
    private static let cellularKey = "lobby.downloadsUseMobileData"
    private static let downloadedOnlyKey = "lobby.downloadedOnly"
    private static let kidsModeKey = "lobby.kidsModeProfileID"
    private static let directKey = "lobby.usesDirectConnection"
    private static let introducerKey = "lobby.introducer"
    private static let viewerQuestionKey = "lobby.viewerQuestion"
    private static let lastUsedKey = "lobby.lastUsedAt"
    private static let sidebarGenresKey = "lobby.sidebarShowsGenres"
    private static let sidebarFoldedKey = "lobby.sidebarFoldedGroups"
    private static let sidebarAllKey = "lobby.sidebarShowsAllOfGroups"
    private static let kidsTrailersKey = "lobby.kidsTrailers"

    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// What each list was last filtered and ordered by, per viewer.
    var titleChoices: TitleChoiceStore { TitleChoiceStore(suiteName: suiteName) }

    /// What each viewer searched for last, on this device only.
    var recentSearches: RecentSearchStore { RecentSearchStore(suiteName: suiteName) }

    /// The address as the person typed it, kept when the device is removed or signs out, so
    /// pairing again does not start with an empty field.
    var lastServerAddress: String? {
        get { defaults.string(forKey: Self.addressKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.addressKey) }
    }

    /// The viewers as the server last listed them, so the app opens on the right one offline.
    var profiles: [Profile] {
        get { read([Profile].self, Self.profilesKey) ?? [] }
        nonmutating set { write(newValue, Self.profilesKey) }
    }

    /// This device as the server last described it, for the role on the Settings screen.
    var device: Device? {
        get { read(Device.self, Self.deviceKey) }
        nonmutating set { write(newValue, Self.deviceKey) }
    }

    /// Whether downloads may use mobile data. Off unless the viewer turns it on.
    var downloadsUseMobileData: Bool {
        get { defaults.bool(forKey: Self.cellularKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.cellularKey) }
    }

    /// The viewer asked to see only what is on the device, although the server is in reach.
    var downloadedOnly: Bool {
        get { defaults.bool(forKey: Self.downloadedOnlyKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.downloadedOnlyKey) }
    }

    /// Whether the direct connection may be used, where the server offers it. On unless the
    /// person turns it off.
    var usesDirect: Bool {
        get { defaults.object(forKey: Self.directKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.directKey) }
    }

    /// Where the household's introducer is, from the last pairing from outside, so that it need not
    /// be typed again. Not a secret.
    var introducer: String? {
        get { defaults.string(forKey: Self.introducerKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.introducerKey) }
    }

    /// The kids viewer this device was in kids mode for when it was last used. Apart from the
    /// list of viewers, so that kids mode outlives a list that cannot be read.
    var kidsModeProfileID: String? {
        get { defaults.string(forKey: Self.kidsModeKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.kidsModeKey) }
    }

    /// When a shared screen asks who is watching.
    var viewerQuestion: ViewerQuestion {
        get { defaults.string(forKey: Self.viewerQuestionKey).flatMap(ViewerQuestion.init(rawValue:)) ?? .eachTime }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.viewerQuestionKey) }
    }

    /// When the app was last put away.
    var lastUsedAt: Date? {
        get { defaults.object(forKey: Self.lastUsedKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.lastUsedKey) }
    }

    /// Whether the sidebar's genres are opened.
    var sidebarShowsGenres: Bool {
        get { defaults.bool(forKey: Self.sidebarGenresKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.sidebarGenresKey) }
    }

    /// The sidebar's groups that are folded away, by id.
    var sidebarFoldedGroups: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.sidebarFoldedKey) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: Self.sidebarFoldedKey) }
    }

    /// The sidebar's long groups that show all their categories, not only the first, by id.
    var sidebarShowsAllOfGroups: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.sidebarAllKey) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: Self.sidebarAllKey) }
    }

    /// Whether a kids viewer sees trailers on this device. On unless a grown-up turns it off.
    var kidsTrailers: Bool {
        get { defaults.object(forKey: Self.kidsTrailersKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.kidsTrailersKey) }
    }

    /// Forgets the viewers and the device. The address stays.
    func forgetConnection() {
        defaults.removeObject(forKey: Self.kidsModeKey)
        defaults.removeObject(forKey: Self.profilesKey)
        defaults.removeObject(forKey: Self.deviceKey)
    }

    /// Forgets everything, for a namespace that starts clean.
    func removeAll() {
        forgetConnection()
        defaults.removeObject(forKey: Self.addressKey)
        defaults.removeObject(forKey: Self.directKey)
        defaults.removeObject(forKey: Self.introducerKey)
        defaults.removeObject(forKey: Self.viewerQuestionKey)
        defaults.removeObject(forKey: Self.lastUsedKey)
        defaults.removeObject(forKey: Self.sidebarGenresKey)
        defaults.removeObject(forKey: Self.sidebarFoldedKey)
        defaults.removeObject(forKey: Self.sidebarAllKey)
        defaults.removeObject(forKey: Self.kidsTrailersKey)
    }

    private func read<Value: Decodable>(_ type: Value.Type, _ key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? LobbyJSON.decoder().decode(type, from: $0) }
    }

    private func write<Value: Encodable>(_ value: Value?, _ key: String) {
        if let value, let data = try? LobbyJSON.encoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
