// SPDX-License-Identifier: MPL-2.0
import CoreGraphics
import Foundation
import LobbyDirect
import LobbyKit
import Observation

/// The app's one UI-facing state object: the connection, the viewer, the device's copy of the
/// library and the player. Made at launch and passed down through the environment.
///
/// Views render what is here and call its methods. They do not talk to LobbyKit themselves.
@MainActor
@Observable
final class AppModel {
    enum Phase: Hashable, Sendable {
        /// Reading what was saved. Shown for a moment at launch.
        case launching
        /// Not paired (any more).
        case connect
        /// Paired, and nobody chose who is watching yet.
        case chooseProfile
        case library
    }

    /// Why the Connect screen is showing although this device was paired before.
    enum ConnectNotice: Hashable, Sendable {
        /// A manager removed this device (`device_revoked`).
        case deviceRemoved
        /// The server does not know this device's credential (`unauthorized`): it was set up
        /// again, or this is another server at the same address.
        case credentialNotRecognised
    }

    enum Connectivity: Hashable, Sendable {
        case unknown
        case online
        /// The server did not answer. The app keeps working from its own copy.
        case offline
    }

    let environment: AppEnvironment

    private(set) var phase: Phase = .launching {
        didSet {
            if phase != .chooseProfile { grownUpIsPresent = false }
            if phase == .library { playPendingIfReady() }
        }
    }
    private(set) var connectNotice: ConnectNotice?
    /// Whether the server's first setup is still to do. Only a manager at home is told.
    var serverSetup: ServerSetup?
    /// The manager said "Later" to the first setup, until the app starts again.
    var postponesSetup = false
    private(set) var connection: SavedConnection? {
        didSet { if connection != oldValue { account.connectionChanged(connection) } }
    }
    /// What the app's list of servers (`ServersModel`) wants to know of this one, and says of the others.
    @ObservationIgnored var account = AccountHooks()
    /// Another server is in use now: this one is being taken down, and starts nothing new.
    private(set) var isSuspended = false
    /// A grown-up proved to be one to leave the kids screens, and the picker is still up: they
    /// may also switch to another server without being asked again.
    private(set) var grownUpIsPresent = false
    /// A download of this server to play once a viewer is chosen: it was chosen from another
    /// server's Downloads.
    @ObservationIgnored private var pendingPlay: String?
    /// The start shows Who is watching, though a viewer was chosen before: the library was just chosen.
    @ObservationIgnored private var asksForViewer = false
    private(set) var device: Device? {
        didSet { if device?.kidsProfileId != oldValue?.kidsProfileId { musicFollowsViewer() } }
    }
    /// The server's viewers: one list for the household, the same on every device.
    private(set) var profiles: [Profile] = []
    /// The server's list was fetched at least once since this device was paired or launched.
    /// Until then an empty list means "not known yet", not "there are none".
    private(set) var hasFetchedProfiles = false
    private(set) var activeProfile: Profile? {
        didSet {
            if activeProfile?.id != oldValue?.id || (activeProfile?.kids == nil) != (oldValue?.kids == nil) {
                musicFollowsViewer()
            }
            // A grown-up's viewer, or none: the child's places are not watched.
            if !isKidsMode { places.stop() }
        }
    }
    /// What the Library, search and the detail pages show: everything, or only what can play
    /// from this device (`showsDownloadedOnly`).
    private(set) var catalogue = Catalogue()
    /// Everything the server has, as of the last sync.
    private(set) var wholeCatalogue = Catalogue()
    /// What of that the viewer may watch. All of it, except for a kids viewer.
    private var viewerCatalogue = Catalogue()
    /// The viewer's own switch: only what is on the device, although the server is in reach.
    private(set) var downloadedOnly = false
    private(set) var progress: [String: PlaybackProgress] = [:]
    private(set) var shelves = LibraryShelves.empty
    /// The Home page. The others are made when they are opened (`page(_:)`).
    private(set) var homePage = BrowsePage.empty
    @ObservationIgnored private var builder: BrowseBuilder?
    /// By scope, and for a category with others inside it by the section shown.
    @ObservationIgnored private var pages: [PageKey: BrowsePage] = [:]

    private struct PageKey: Hashable {
        var scope: BrowseScope
        var section: String?
    }
    @ObservationIgnored private var relatedRows: [String: [BrowseRow]] = [:]
    /// What the household watches, as of the last time the server said.
    private var popular = Popular.none
    /// Titles by how much the household watches them, most first: for ordering by Popular.
    var popularOrder: [String] { popular.titles.map(\.itemId) }
    /// What lists were filtered and ordered by this session, by viewer and list.
    var titleChoiceCache: [String: TitleChoice] = [:]
    /// What the kids screens show. Empty outside kids mode.
    private(set) var kidsLibrary = KidsLibrary.empty
    var kidsSection = KidsSection.home
    /// The film or series that is open on them.
    var kidsPath: [KidsRoute] = []
    /// What the grown-up behind the avatar reads. Set by `askToLeaveKidsMode`.
    var grownUpNotice: GrownUpNotice?
    private var isAskingGrownUp = false
    /// The pill chosen above the Library on a phone.
    var libraryFilter = LibraryFilter.all
    /// The household's parts of the library, as of the last time the server answered.
    private(set) var categoryGroups = CategoryGroups.none
    private(set) var connectivity: Connectivity = .unknown

    /// How the server is reached now. nil while it is not.
    private(set) var road: Road?
    /// How the direct connection is doing, while it is used.
    private(set) var roadCondition: ServerRoad.Condition = .steady
    /// The server offers the direct connection and this device is ready for it.
    private(set) var hasDirect = false
    private(set) var usesDirect = true

    /// The server answers at none of its addresses. More than a request that failed: one
    /// hiccup does not change what is on screen, this does.
    private(set) var serverIsOutOfReach = false {
        didSet {
            guard serverIsOutOfReach != oldValue else { return }
            // In reach or out of it: the same Library, with everything or with the downloads.
            // The refresh that found this out rebuilds the shelves before it returns.
            showCatalogue()
        }
    }

    /// The Library is limited to what is on this device: the server is out of reach, or the
    /// viewer asked for it.
    var showsDownloadedOnly: Bool { environment.keepsDownloads && (downloadedOnly || serverIsOutOfReach) }
    private(set) var lastSyncedAt: Date?
    private(set) var isRefreshing = false
    /// Something the viewer should know that is not about the connection (a full disk, a
    /// refusal from the server). Shown once and dismissed.
    var problem: String?
    /// What the viewer keeps on this device, by item id.
    private(set) var downloads: [String: DownloadRecord] = [:]
    /// The Downloads screen.
    private(set) var downloadsOverview = DownloadsOverview.empty
    private(set) var downloadsUseMobileData = false
    /// The film or episode on screen in the player, if any.
    private(set) var player: PlayerModel?
    /// A play from another device is on its way: this TV was woken for it (docs/decisions.md, "Wake and Play"). Who is watching
    /// is not asked meanwhile; the play says who.
    private(set) var awaitsRemotePlay = false
    private var awaitsRemotePlayEnd: Task<Void, Never>?
    /// The title a play from another device opened, for the screens to show its page behind the
    /// player instead of what was open before.
    private(set) var remoteOpened: RemoteOpened?

    struct RemoteOpened: Hashable, Sendable {
        let id = UUID()
        /// The film, or the series of an episode.
        let itemID: String
    }

    /// Which section the sidebar shows, on the iPad and the Mac. Here, so that menu commands
    /// and keyboard shortcuts can change it.
    var sidebarSelection: SidebarItem? = .library
    /// What is open on top of that section: a film, a show, a full list.
    var libraryPath: [Route] = []
    /// What is typed into the search field of the sidebar layout.
    var searchText = ""
    /// Whether that search field has the keyboard. Set by Find (⌘F).
    var isSearching = false

    private var client: LobbyClient? {
        didSet { if client == nil { music.setConnection(nil, outOfReach: true) } }
    }
    /// The household's music, apart from the films: its library, the viewer's own and the player.
    @ObservationIgnored private(set) lazy var music = MusicModel(
        storage: environment.music,
        coverLoader: { [weak self] artwork, width in await self?.artwork(artwork, pixelWidth: width) },
        sleep: environment.sleep)
    /// The address in use was checked on the network the device is on now.
    private var hasFoundServer = false
    /// Counts the networks the device was on.
    private var networkCount = 0
    /// The looking that is under way, for everyone who needs the server.
    private var finding: Task<Bool, Never>?
    private var artworkKeeping: Task<Void, Never>?
    /// The revision of the manager's list this device has applied in full.
    private var wantedRevision: String?
    private var lastReported: [String]?
    private var isSyncingWanted = false
    private var shelfGeneration = 0
    private var newestRebuild: Task<Void, Never>?

    private let startsClean: Bool

    /// - Parameter startsClean: Forget everything stored before starting. For a test run in
    ///   its own namespace (`AppEnvironment.live(device:namespace:)`).
    init(environment: AppEnvironment, startsClean: Bool = false) {
        self.environment = environment
        self.startsClean = startsClean
        updates = UpdateModel(source: environment.updates, now: environment.now)
        remote.app = self
    }

    // MARK: Updates

    /// Whether the App Store has a newer Lobby.
    let updates: UpdateModel

    /// The server as it last described itself, for its version.
    private(set) var serverInfo: ServerInfo?
    /// Whose household this device is in, as the server last said. nil until then, and from a
    /// server from before households.
    private(set) var household: HouseholdSummary?

    /// Whether this app and its server work together. Compatible until the server has said.
    var serverCompatibility: ServerCompatibility {
        guard let serverInfo else { return .compatible }
        return ServerCompatibility(serverVersion: serverInfo.version, serverNeedsApp: serverInfo.minAppVersion, app: updates.running)
    }

    /// What the screen is doing, for whether a notice may come up.
    var noticeMoment: NoticeMoment {
        NoticeMoment(
            isInLibrary: phase == .library, isKidsMode: isKidsMode || showsKidsScreens,
            isPlaying: player != nil || music.player.isPlaying, isManager: isOwnerManager)
    }

    /// The notice to show now, if any: a newer Lobby in the App Store, or for a manager an app
    /// and a server that do not work together. Never over a film or the kids screens.
    var updateNotice: UpdateNotice? {
        let moment = noticeMoment
        if let mismatch = updates.mismatch(serverCompatibility, in: moment) { return .mismatch(mismatch) }
        return updates.notice(in: moment).map(UpdateNotice.release)
    }

    /// Asks the App Store when it is time to (`UpdateModel.checkIfDue`).
    func checkForUpdatesIfDue() async {
        await updates.checkIfDue()
    }

    /// Playing on another device: the household's other devices, and this one for them.
    let remote = RemoteModel()

    /// When and what the kids viewer in front may do, and the questions children ask the
    /// grown-ups (docs/kids-control.md).
    @ObservationIgnored private(set) lazy var kidsControl: KidsControlModel = {
        let url = environment.kidsPlanURL
        let cache = url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? LobbyJSON.decoder().decode(KidsPlanCache.self, from: $0) } ?? KidsPlanCache()
        return KidsControlModel(cache: cache) { cache in
            guard let url, let data = try? LobbyJSON.encoder().encode(cache) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }()

    var playbackContext: PlaybackContext {
        PlaybackContext(
            capabilities: environment.capabilities,
            localCopies: downloads.compactMapValues { record in
                record.isPlayable
                    ? .init(assetID: record.assetID, isOutOfDate: record.staleness != nil || record.state != .verified)
                    : nil
            },
            serverIsOutOfReach: serverIsOutOfReach, keepsDownloads: environment.keepsDownloads,
            explainsPreparation: isOwnerManager)
    }

    /// iPhone, iPad and Mac. The Apple TV limits what a kids viewer sees, in its ordinary
    /// screens.
    var hasKidsScreens: Bool { environment.hasKidsScreens }

    /// The kids screens are up, and a viewer cannot be chosen without a grown-up.
    var showsKidsScreens: Bool { hasKidsScreens && isKidsMode }

    /// Manages a household: a household admin, or a server admin (docs/api.md, Households).
    var isManager: Bool { (device?.level ?? .viewer) != .viewer }

    /// The device is in a guest household: the server and its library are someone else's
    /// (docs/api.md, Households). Its managers manage that household only.
    var isGuest: Bool { (device?.householdId ?? HouseholdSummary.ownerID) != HouseholdSummary.ownerID }

    /// A server admin: the server itself, its library, settings and households.
    var isOwnerManager: Bool { device?.level == .admin }

    /// The connection, for the manager's tools. nil on a viewer device: it has none.
    var managerClient: LobbyClient? { isManager ? client : nil }

    /// One of a manager's calls, sent to the server where it is reached from now: at home, or
    /// from elsewhere. Nothing is sent to an address that was not found to be the server on
    /// this network. When the address stops answering, the others are tried once.
    func asManager<Answer: Sendable>(_ call: (LobbyClient) async throws -> Answer) async throws -> Answer {
        guard isManager else { throw LobbyError.forbidden(message: "Only a manager can do this.") }
        // A household admin manages their household from where they are; a server admin from home.
        let fromAnywhere = !isOwnerManager
        // Home may be in reach again: that is where managing works.
        if !fromAnywhere, road?.allowsManaging == false { hasFoundServer = false }
        guard await findServer() else { throw LobbyError.unreachable(.cannotConnectToHost) }
        if !fromAnywhere, road?.allowsManaging == false {
            throw LobbyError.forbidden(message: "Managing works at home or over Tailscale, not over the direct connection.")
        }
        return try await atServer(call)
    }

    /// A call for what a person waits for, sent as `asManager` says.
    private func atServer<Answer: Sendable>(_ call: (LobbyClient) async throws -> Answer) async throws -> Answer {
        guard await findServer(), let client else { throw LobbyError.unreachable(.cannotConnectToHost) }
        do {
            return try await call(client)
        } catch let error as LobbyError where error.isUnreachable {
            hasFoundServer = false
            // The same address again would only repeat what may have arrived already.
            guard await findServer(), let moved = self.client, moved.baseURL != client.baseURL else { throw error }
            return try await call(moved)
        }
    }

    /// One of a viewer's calls that a person waits for, such as their statistics: sent as
    /// `asManager` sends, from wherever the server is reached now.
    func asViewer<Answer: Sendable>(_ call: (LobbyClient) async throws -> Answer) async throws -> Answer {
        try await atServer(call)
    }

    /// What a person reads when one of their calls failed. A lost credential goes to Connect.
    func managerProblem(_ error: any Error) async -> String? {
        if error is CancellationError { return nil }
        guard let error = error as? LobbyError else { return error.localizedDescription }
        if error.requiresPairing {
            await credentialLost(error)
            return nil
        }
        return error.localizedDescription
    }

    /// The manager's page. One for the app, so that it keeps what was typed while the viewer
    /// looks at something else.
    private(set) var storedManager: ManagerModel?

    func manager() -> ManagerModel {
        if let storedManager { return storedManager }
        let model = ManagerModel(app: self)
        storedManager = model
        return model
    }

    /// The first setup of a fresh server, offered to its manager over the library.
    var showsServerSetup: Bool {
        isManager && serverSetup?.needed == true && !postponesSetup && (phase == .library || phase == .chooseProfile)
    }

    /// The server's settings, for a manager. One for the app, like the manager's page.
    private(set) var storedServerSettings: ServerSettingsModel?

    @ObservationIgnored private(set) var storedUploads: UploadsModel?
    /// The Mac's uploads, over the window: from the menu, or files dropped on it.
    var showsUploads = false

    /// The uploads of this device: one model for as long as the app runs, so they go on whichever
    /// screen is shown.
    func uploads() -> UploadsModel {
        if let storedUploads { return storedUploads }
        let model = UploadsModel(app: self)
        storedUploads = model
        return model
    }

    func serverSettings() -> ServerSettingsModel {
        if let storedServerSettings { return storedServerSettings }
        let model = ServerSettingsModel(app: self)
        storedServerSettings = model
        return model
    }

    /// The catalogue was never fetched: there is nothing to show yet, which is not the same as
    /// an empty library.
    var hasLibraryCopy: Bool { lastSyncedAt != nil }

    // MARK: Launch and refresh

    /// Reads what was saved and shows it at once, then asks the server what changed.
    func start() async {
        guard phase == .launching else { return }
        if startsClean {
            do {
                try await environment.forgetEverything()
            } catch {
                problem = "The stored state could not be cleared. \(error.localizedDescription)"
            }
        }
        downloadsUseMobileData = environment.settings.downloadsUseMobileData
        usesDirect = environment.settings.usesDirect
        if startsClean { updates.forget() }
        // Apart from the server: the App Store is asked whatever the server does.
        Task { await checkForUpdatesIfDue() }
        // Also before pairing: music follows the device from then on.
        await startMusic()
        guard let saved = environment.preferences.connection else {
            await environment.downloads.start(using: nil)
            phase = .connect
            return
        }

        let token: String?
        do {
            token = try await environment.credentials.token(forServer: saved.serverID)
        } catch {
            problem = "The Keychain could not be read. \(error.localizedDescription)"
            token = nil
        }
        guard let token, let client = try? LobbyClient(baseURL: saved.serverAddress, token: token, session: environment.session)
        else {
            // Not paired any more. What was downloaded is still on the device.
            connection = saved
            await environment.downloads.start(using: nil)
            phase = .connect
            return
        }

        connection = saved
        self.client = client
        hasDirect = await environment.road?.identity(forServer: saved.serverID) != nil
        device = environment.settings.device
        profiles = environment.settings.profiles
        downloadedOnly = environment.settings.downloadedOnly
        // Who is watching comes before what there is: nothing is on screen that this viewer
        // may not see, not for a moment.
        restoreViewer()
        wholeCatalogue = await environment.catalogueStore.catalogue()
        categoryGroups = await environment.categoryGroupsStore.groups()
        popular = await environment.popularStore.popular(kidsOnly: isKidsMode)
        showCatalogue()
        lastSyncedAt = await environment.catalogueStore.lastSyncedAt()
        // The downloads get the connection once the server is found at it (`findServer`):
        // until then nothing of theirs is sent anywhere.
        await environment.downloads.start(using: nil)
        applyDownloads(await environment.downloads.all())

        #if os(tvOS)
        // Opened by Lobby Server, which woke the TV for a play: the live channel says so within a
        // moment, and until then who is watching waits (docs/decisions.md, "Wake and Play").
        heardOfRemotePlay(waiting: true, for: .seconds(3))
        #endif
        if let profile = activeProfile {
            progress = await environment.progressStore.progress(profileID: profile.id)
            await rebuildShelves()
            phase = asksWhoIsWatching(isLaunch: true) || (asksForViewer && !isKidsMode) ? .chooseProfile : .library
            asksForViewer = false
        } else {
            phase = .chooseProfile
        }
        await refresh()
    }

    /// Sends queued progress and fetches what changed: this device, the viewers, the catalogue
    /// and the active viewer's progress. Called at launch, when the app comes to the front,
    /// when the network comes back and on pull to refresh.
    func refresh() async {
        guard client != nil, !isRefreshing, !isSuspended else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // First find the server, and make sure it is the server: nothing below is sent to an
        // address before that.
        let lookedJustNow = !hasFoundServer
        guard await findServer(), let client else {
            connectivity = .offline
            serverIsOutOfReach = true
            // Without the server, the signed copy of the plan: never more than it allows.
            if isKidsMode {
                kidsControl.wentOffline()
                await kidsModeChanged()
            }
            music.setConnection(self.client, outOfReach: true)
            await rebuildShelves()
            return
        }
        serverIsOutOfReach = false
        music.setConnection(client, outOfReach: false)

        do {
            let me = try await client.me()
            await applyDevice(me.device)
            serverSetup = me.server.setup
            serverInfo = me.server
            household = me.household
            if var saved = connection, saved.serverName != me.server.name || saved.addresses != me.server.addresses {
                saved.serverName = me.server.name
                // Where else the server can be reached: kept for the day this address does
                // not answer. A server that does not say leaves what is known as it is.
                saved.addresses = me.server.addresses ?? saved.addresses
                connection = saved
                environment.preferences.connection = saved
            }
            await keepReadyForOutside(client)

            try await applyProfiles(try await client.profiles())

            // Questions children asked while this device did not listen.
            if !isKidsMode, isManager { await kidsControl.refreshQuestions(using: client) }
            await registerPushIfNeeded()

            // When and what: in Nothing, Only listening or Ask to open the films are not asked
            // for at all, and what the device has stays as it is.
            if isKidsMode {
                await refreshKidsControl(using: client)
                if !kidsControl.screen.showsFilms {
                    connectivity = .online
                    await rebuildShelves()
                    return
                }
            }

            // Before the catalogue, so that its pages land in the right part of the library.
            categoryGroups = try await environment.categoryGroupsStore.sync(using: client)
            // The parts a kids viewer may see can hold other categories now.
            if activeProfile?.kids != nil { showCatalogue() }

            // A first fetch comes in pages: show each as it arrives, not a spinner until the last.
            wholeCatalogue = try await environment.catalogueStore.sync(using: client) { [weak self] partial in
                await self?.show(partial)
            }
            if isKidsMode {
                // What the viewer may see changes without the setup changing: the parts that
                // came before the titles can be those of a moment ago.
                categoryGroups = try await environment.categoryGroupsStore.sync(using: client)
            }
            showCatalogue()
            lastSyncedAt = await environment.catalogueStore.lastSyncedAt()
            // Only now is it known what the server has: a copy of a replaced or removed file
            // is flagged, and what waited for the server starts.
            await environment.downloads.reconcile(with: wholeCatalogue)
            await stopWhatIsNotAllowed()
            keepArtworkOfDownloads()
            await syncWanted()
            await environment.downloads.retryWaiting()
            popular = try await environment.popularStore.sync(kidsOnly: isKidsMode, using: client)

            if let profile = activeProfile {
                try await environment.progressStore.synchronise(profileID: profile.id, using: client)
                progress = await environment.progressStore.progress(profileID: profile.id)
            }
            if !isKidsMode { await music.refresh(using: client) }
            connectivity = .online
        } catch {
            // The plan switched while this ran: the mode, not a problem.
            if (error as? LobbyError)?.isKidsMode == true {
                await refreshKidsControl(using: client)
                await rebuildShelves()
                return
            }
            await handle(error)
            if !lookedJustNow, (error as? LobbyError)?.isUnreachable == true {
                // The address that worked a moment ago does not any more (the device left
                // home, or came back): look at all of them, once, and go on from there.
                isRefreshing = false
                return await refresh()
            }
        }
        await rebuildShelves()
    }

    /// Finds the address at which the server answers from where the device is now (home
    /// first, then from elsewhere) and moves the connection and the downloads there.
    ///
    /// Asked once per network: again after the network changed or the server stopped
    /// answering. The asking carries no credential, and an address where something else
    /// answers is never used.
    ///
    /// - Returns: false when the server answers nowhere.
    private func findServer() async -> Bool {
        if let finding { return await finding.value }
        guard connection != nil, client != nil else { return false }
        if hasFoundServer { return true }
        let task = Task { await lookForServer() }
        finding = task
        let found = await task.value
        finding = nil
        return found
    }

    private func lookForServer() async -> Bool {
        // The network can change while it looks: what was found is then of the old one.
        for _ in 0..<3 {
            guard let saved = connection, let current = client, let token = current.token else { return false }
            let network = networkCount
            let found = await environment.find(saved, token: token)
            guard connection?.serverID == saved.serverID, client?.token == token else { return false }
            if network != networkCount { continue }
            guard let found else {
                road = nil
                return false
            }
            hasFoundServer = true
            await move(to: found)
            return true
        }
        return false
    }

    /// From now on everything goes over this road. What plays goes on.
    private func move(to found: ServerRoad.Found) async {
        guard var saved = connection, let current = client else { return }
        road = found.road
        guard found.client.baseURL != current.baseURL || found.client.isCarriedByRoad != current.isCarriedByRoad else {
            await environment.downloads.setClient(current)
            return
        }
        client = found.client
        if !found.client.isCarriedByRoad {
            saved.serverAddress = found.client.baseURL
            connection = saved
            environment.preferences.connection = saved
        }
        player?.move(to: found.client)
        await environment.downloads.setClient(found.client)
    }

    /// At home or in the tailnet: ready for the day it is needed.
    private func keepReadyForOutside(_ client: LobbyClient) async {
        guard let outside = environment.road, let serverID = connection?.serverID, road?.allowsManaging == true else { return }
        await outside.keepReady(client, serverID: serverID)
        hasDirect = await outside.identity(forServer: serverID) != nil
    }

    /// The person's switch for the direct connection.
    func setUsesDirect(_ uses: Bool) async {
        usesDirect = uses
        environment.settings.usesDirect = uses
        await environment.road?.setUsesDirect(uses)
        hasFoundServer = false
        await refresh()
    }

    /// In a few words, for Settings. nil when there is nothing to say yet.
    var roadText: String? {
        guard client != nil else { return nil }
        guard let road, !serverIsOutOfReach else { return connectivity == .unknown ? nil : "Offline" }
        return switch road {
        case .home: "Home network"
        case .tailscale: "Tailscale"
        case .direct: "Direct"
        case .relay: "Relay"
        }
    }

    /// Why the direct connection is not there, when it should be what is used.
    var roadProblem: String? {
        guard hasDirect, usesDirect, road == nil || road?.allowsManaging == false, case .lost(let problem) = roadCondition
        else { return nil }
        return problem.localizedDescription
    }

    /// The direct connection is being made again: what plays waits a moment.
    var isReconnecting: Bool { roadCondition == .reconnecting && client?.isCarriedByRoad == true }

    /// Runs for as long as the app does: follows the direct connection.
    func watchRoad() async {
        guard let outside = environment.road else { return }
        for await condition in await outside.conditions() {
            let before = roadCondition
            roadCondition = condition
            // It came back after the app had given up on it.
            if condition == .steady, before != .steady, serverIsOutOfReach, hasDirect { await refresh() }
        }
    }

    /// What has arrived of the catalogue so far, while the rest is still on its way.
    private func show(_ partial: Catalogue) async {
        wholeCatalogue = partial
        showCatalogue()
        await rebuildShelves()
    }

    /// Puts on screen what there is to show: everything, or what can play from this device.
    private func showCatalogue() {
        viewerCatalogue = activeProfile?.kids.map { wholeCatalogue.limited(to: $0, groups: categoryGroups) } ?? wholeCatalogue
        catalogue = showsDownloadedOnly
            ? viewerCatalogue.limited(to: Set(playbackContext.localCopies.keys)) : viewerCatalogue
        music.showsDownloadedOnly = showsDownloadedOnly
    }

    // MARK: Music

    /// Music reads what it kept, for the viewer of now.
    private func startMusic() async {
        music.isForKids = isKidsMode
        await music.start(profileID: isKidsMode ? nil : activeProfile?.id) { [weak self] in
            self?.keepArtworkOfDownloads()
        }
        music.setDownloadsUseMobileData(downloadsUseMobileData)
    }

    /// Another viewer, or kids mode began or ended: music follows. A child has none.
    private func musicFollowsViewer() {
        let forKids = isKidsMode
        music.isForKids = forKids
        if forKids { music.player.stop() }
        let profile = forKids ? nil : activeProfile?.id
        Task { await music.viewerChanged(profile) }
    }

    // MARK: Kids mode

    /// A manager bound this device to a kids viewer: nothing on the device changes that.
    var isBoundToKids: Bool { device?.kidsProfileId != nil }

    /// The device shows a kids viewer's screens and nothing else.
    var isKidsMode: Bool { isBoundToKids || activeProfile?.kids != nil }

    /// Which statistics this device offers: by its level, and none in kids mode.
    var statsAccess: StatsAccess {
        StatsAccess(
            level: device?.level ?? .viewer, isKidsMode: isKidsMode, viewerID: activeProfile?.id,
            householdID: device?.householdId ?? HouseholdSummary.ownerID)
    }

    /// Whoever was watching, from what this device kept. A kids viewer it can no longer find
    /// stays one, with nothing to watch: never the picker, never somebody else's library.
    private func restoreViewer() {
        let saved = environment.preferences.activeProfileID
        if let bound = device?.kidsProfileId {
            activeProfile = kidsProfile(bound)
        } else if let saved, environment.settings.kidsModeProfileID == saved,
            !profiles.contains(where: { $0.id == saved })
        {
            activeProfile = kidsProfile(saved)
        } else {
            activeProfile = saved.flatMap { id in profiles.first { $0.id == id } }
        }
        rememberKidsMode()
    }

    /// The kids viewer of that id as it is known, with nothing allowed when it is not.
    private func kidsProfile(_ id: String) -> Profile {
        let known = profiles.first { $0.id == id } ?? (activeProfile?.id == id ? activeProfile : nil)
        guard let known else { return Profile(id: id, name: "", color: "pink", kids: KidsSettings()) }
        return known.kids == nil ? Self.withNothingToWatch(known) : known
    }

    private static func withNothingToWatch(_ profile: Profile) -> Profile {
        Profile(
            id: profile.id, name: profile.name, color: profile.color, avatar: profile.avatar,
            saysAvatar: profile.saysAvatar, kids: KidsSettings())
    }

    private func rememberKidsMode() {
        environment.settings.kidsModeProfileID = isKidsMode ? activeProfile?.id : nil
    }

    /// What the server says about this device, with the binding known before when an older
    /// server says nothing about it.
    private func applyDevice(_ told: Device) async {
        let device = told.keepingKidsProfile(of: self.device)
        self.device = device
        environment.settings.device = device
        await followBinding()
    }

    /// Makes a bound device's viewer the one it is bound to.
    private func followBinding() async {
        guard let bound = device?.kidsProfileId else {
            rememberKidsMode()
            return
        }
        let profile = kidsProfile(bound)
        let changesViewer = activeProfile?.id != bound
        if changesViewer || phase == .chooseProfile { await player?.close() }
        // Another name or picture changes nothing there is to watch.
        let changesLimits = changesViewer || activeProfile?.kids != profile.kids
        activeProfile = profile
        environment.preferences.activeProfileID = bound
        rememberKidsMode()
        if changesViewer {
            startAtTheTop()
            progress = await environment.progressStore.progress(profileID: bound)
        }
        if changesLimits {
            popular = await environment.popularStore.popular(kidsOnly: true)
            showCatalogue()
            await rebuildShelves()
        }
        if phase == .chooseProfile { phase = .library }
    }

    /// Another viewer does not land where the last one was.
    private func startAtTheTop() {
        kidsPath = []
        kidsSection = .home
        libraryPath = []
        sidebarSelection = .library
        libraryFilter = .all
        searchText = ""
        isSearching = false
    }

    /// A film that a manager just took away does not play on, and a device that belongs to the
    /// viewer does not keep it. (A device that others use too keeps their downloads.) Only
    /// after the server's whole answer arrived.
    private func stopWhatIsNotAllowed() async {
        guard isKidsMode else { return }
        if let player, viewerCatalogue.item(player.request.item.id) == nil { await player.close() }
        guard isBoundToKids else { return }
        for id in downloads.keys where wholeCatalogue.item(id) == nil {
            await environment.downloads.remove(itemID: id)
        }
    }

    /// What the server says the kids viewer in front may do now, and its signed plan for offline.
    func refreshKidsControl(using client: LobbyClient) async {
        guard isKidsMode, let device else {
            places.stop()
            return kidsControl.reset()
        }
        do {
            let me = try await client.kidsMe(profileID: isBoundToKids ? nil : activeProfile?.id)
            kidsControl.update(me, deviceID: device.id)
        } catch let error as LobbyError {
            // A server from before plans: as it always was.
            if case .notFound = error { kidsControl.reset() } else if error.isUnreachable { kidsControl.wentOffline() }
        } catch {}
        await kidsModeChanged()
    }

    /// The live channel said something of kids control: a mode, a question or its answer.
    func kidsHeard(_ event: LiveEvent) async {
        switch event {
        case .kidsMode(let profileID, let now):
            guard isKidsMode, profileID == (device?.kidsProfileId ?? activeProfile?.id) else { return }
            let before = kidsControl.screen
            kidsControl.heard(now)
            await kidsModeChanged()
            // Films come back: fetch what there is.
            if !before.showsFilms, kidsControl.screen.showsFilms { await refresh() }
        case .kidsRequest(let request):
            kidsControl.heard(request, closed: false)
            if isKidsMode { await kidsModeChanged() }
            #if os(iOS) || os(macOS)
            if !isKidsMode, !remote.isForeground, request.state == .waiting { PushCenter.shared.notify(request) }
            #endif
        case .kidsRequestClosed(let request):
            kidsControl.heard(request, closed: true)
            #if os(iOS) || os(macOS)
            PushCenter.shared.forget(request.id)
            #endif
        default:
            break
        }
    }

    /// Ends what the new mode does not allow, and asks when the screens are asking.
    func kidsModeChanged() async {
        guard isKidsMode else { return }
        if let player {
            let item = player.request.item
            if !kidsControl.allowsVideo(of: [item.id] + (item.parentId.map { [$0] } ?? [])) {
                kidsNotice = .filmWaits
                await player.close()
            }
        }
        if kidsControl.now?.at.listening == false { music.player.stop() }
        // Music for a kids viewer, where the plan lets it listen.
        let listens = kidsControl.now?.at.listening == true
        if music.kidsMayListen != listens {
            music.kidsMayListen = listens
            if listens, let client { await music.refresh(using: client) }
        }
        places.watch(kidsControl.places, for: self)
        if let client {
            await kidsControl.askIfNeeded(using: client, profileID: isBoundToKids ? nil : activeProfile?.id)
        }
    }

    /// Said once to the child when a switch ended its film.
    var kidsNotice: KidsNotice?

    /// Watches the child's places on this device, when its plan has any.
    @ObservationIgnored private(set) lazy var places = KidsPlaceWatcher(follow: environment.followPlaces)
    /// The push token this server was told last.
    @ObservationIgnored private var toldPushToken: Data?

    /// Tells the server where this device gets pushes, once there is a token it was not told.
    func registerPushIfNeeded() async {
        #if os(iOS) || os(macOS)
        guard
            let token = PushCenter.shared.token, token != toldPushToken, let client = liveClient,
            let serverID = connection?.serverID
        else { return }
        do {
            // Through the relay, or directly, as this server sends them (docs/decisions.md, "Push
            // through a relay").
            _ = try await PushRegistrar(keys: environment.pushKeys).register(
                token: token, environment: PushCenter.environment, serverID: serverID, client: client)
            toldPushToken = token
        } catch {
            // A server without push, or a relay that cannot be reached: tried again next time.
        }
        #endif
    }

    /// Tells the server to send this device no more pushes: signing out, removing this server, or
    /// notifications turned off. Only a try: a server out of reach keeps the token until the
    /// device is removed there, and it never pushes to a removed device.
    func unregisterPush() async {
        #if os(iOS) || os(macOS)
        toldPushToken = nil
        guard let client else { return }
        do {
            try await client.unregisterPush()
        } catch {
            // Out of reach, or a server without push: nothing more to do from here.
        }
        #endif
    }

    /// Signed out or removed: no more pushes from that server, and its key is gone.
    private func forgetPush(serverID: String) async {
        #if os(iOS) || os(macOS)
        toldPushToken = nil
        await PushRegistrar(keys: environment.pushKeys).forget(serverID: serverID)
        #endif
    }

    /// What each kids viewer may do now, for the viewer list. By viewer id.
    private(set) var kidsGlances: [String: KidsNow] = [:]

    func refreshKidsGlances() async {
        guard let client = liveClient, !isKidsMode else { return }
        if let glances = try? await client.kidsNow() { kidsGlances = glances }
    }

    /// "Ask to watch" for one title, in Ask per title.
    func askToWatch(_ itemID: String) async {
        guard let client else { return }
        await kidsControl.ask(.title, itemID: itemID, using: client, profileID: isBoundToKids ? nil : activeProfile?.id)
    }

    /// Where this device is, as far as the child's places go: never coordinates.
    func reportKidsPlace(_ report: KidsPlaceReport) async {
        guard isKidsMode else { return }
        if let client = liveClient,
            let now = try? await client.reportKidsPlace(report, profileID: isBoundToKids ? nil : activeProfile?.id)
        {
            kidsControl.heard(now)
            await kidsModeChanged()
        } else if kidsControl.isOffline {
            kidsControl.wentOffline(place: report)
        }
    }

    /// A grown-up answers a child's question.
    func answerKids(_ id: String, _ answer: KidsAnswer, length: KidsLength? = nil) async {
        guard let client else { return }
        await kidsControl.answer(id, answer, length: length, using: client)
    }

    /// "Try again" on the asking screen.
    func askKidsAgain() async {
        guard let client else { return }
        await kidsControl.askAgain(using: client, profileID: isBoundToKids ? nil : activeProfile?.id)
    }

    /// A film stopped while a child watched. If that is because it is not allowed any more,
    /// the refresh closes it and takes it off the pages.
    func kidsPlaybackFailed() async {
        await refresh()
    }

    /// The avatar in kids mode: a grown-up proves to be one, and then chooses who watches. On
    /// a bound device there is nothing to choose: the grown-up reads who can change that.
    func askToLeaveKidsMode() async {
        guard isKidsMode, phase == .library, !isAskingGrownUp else { return }
        isAskingGrownUp = true
        defer { isAskingGrownUp = false }
        switch await environment.confirmGrownUp() {
        case .confirmed:
            if isBoundToKids {
                grownUpNotice = .bound
            } else {
                // Still the kids viewer until somebody else is chosen: opening the app again
                // is kids mode again.
                phase = .chooseProfile
                grownUpIsPresent = true
            }
        case .refused:
            break
        case .unavailable:
            grownUpNotice = .noPasscode
        }
    }

    /// The grown-ups' code, where there is no Face ID: the Apple TV. Only the server knows it,
    /// so without the server the child stays where it is.
    func leaveKidsMode(code: String) async -> KidsCodeCheck {
        guard !isBoundToKids else { return .bound }
        guard isKidsMode, phase == .library, !isAskingGrownUp else { return .wrong }
        isAskingGrownUp = true
        defer { isAskingGrownUp = false }
        do {
            guard try await atServer({ try await $0.checkKidsCode(code) }) else { return .wrong }
        } catch LobbyError.rateLimited(_, let seconds) {
            return .locked(seconds: Int((seconds ?? 600).rounded(.up)))
        } catch LobbyError.conflict, LobbyError.notFound {
            return .noCode
        } catch let error as LobbyError where error.requiresPairing {
            await credentialLost(error)
            return .unreachable
        } catch {
            return .unreachable
        }
        // A manager may have bound the device while the server looked.
        guard !isBoundToKids else { return .bound }
        guard isKidsMode, phase == .library else { return .wrong }
        phase = .chooseProfile
        grownUpIsPresent = true
        return .confirmed
    }

    /// Whether the household has a code. Throws when the server does not say.
    func hasKidsCode() async throws -> Bool {
        do {
            return try await atServer { try await $0.hasKidsCode() }
        } catch LobbyError.notFound {
            return false
        }
    }

    /// Sets the household's code, or (nil) takes it away. Only a manager may.
    func setKidsCode(_ code: String?) async throws {
        do {
            try await asManager { try await $0.setKidsCode(code) }
        } catch LobbyError.notFound {
            throw KidsUnsupported()
        }
    }

    // MARK: What a manager wants on this device

    /// Reads the list a manager keeps for this device, makes the downloads follow it, and
    /// tells the server what the device has. Quiet when the server is out of reach or too old
    /// to know about lists: nothing here is the viewer's doing.
    func syncWanted() async {
        // Only at an address that was found to be the server on this network.
        guard environment.keepsDownloads, let client, hasFoundServer, !serverIsOutOfReach, !isSyncingWanted else { return }
        isSyncingWanted = true
        defer { isSyncingWanted = false }
        do {
            // Twice at most: a report can be answered with a newer list.
            for _ in 0..<2 {
                if let list = try await client.myWanted(knownRevision: wantedRevision) {
                    let playing = Set([player?.request.item.id].compactMap { $0 })
                    await environment.downloads.applyWanted(
                        list.assets, catalogue: wholeCatalogue, playing: playing, allowsCellular: downloadsUseMobileData)
                    // A file of a title the catalogue does not have yet, or one that is
                    // playing, was left as it is: the list is read in full again next time.
                    let allKnown = list.assets.allSatisfy { wholeCatalogue.item($0.itemId) != nil }
                    wantedRevision = allKnown && playing.isEmpty ? list.revision : nil
                }
                let report = await environment.downloads.report()
                let current = try await client.reportDownloads(report)
                lastReported = Self.outline(of: report)
                if current == wantedRevision || wantedRevision == nil { break }
            }
        } catch {
            // Tried again at the next turn.
        }
    }

    /// Runs for as long as the app does: keeps the server's picture of this device fresh
    /// while something is on its way, and looks at the manager's list once a minute.
    func watchWanted() async {
        var turn = 0
        while !Task.isCancelled {
            do {
                try await environment.sleep(.seconds(30))
            } catch {
                return
            }
            turn += 1
            // What a manager allows or takes away reaches a child's device while it is in use.
            if isKidsMode, turn.isMultiple(of: 2) { await refresh() }
            let isFetching = downloads.values.contains { $0.state == .downloading }
            if turn.isMultiple(of: 2) || isFetching {
                await syncWanted()
            }
        }
    }

    /// What of a report matters for telling the server at once: which files, in which state.
    private static func outline(of report: DownloadsReport) -> [String] {
        report.downloads.map { "\($0.assetId) \($0.revision) \($0.state.rawValue) \($0.own)" }
    }

    /// A download started, finished, failed or went: the server hears it now, not at the
    /// next turn.
    private func reportIfDownloadsChanged() {
        guard client != nil, hasFoundServer, !serverIsOutOfReach else { return }
        Task {
            let report = await environment.downloads.report()
            guard Self.outline(of: report) != lastReported else { return }
            await syncWanted()
        }
    }

    /// The viewer's switch in Settings: only what is on the device, for a slow or costly
    /// connection.
    func setDownloadedOnly(_ only: Bool) async {
        downloadedOnly = only
        environment.settings.downloadedOnly = only
        showCatalogue()
        await rebuildShelves()
    }

    /// Waits until the pictures of the downloads are in place. For tests.
    func finishKeepingArtwork() async {
        await artworkKeeping?.value
    }

    /// The pictures of what is downloaded stay on the device: fetched when a download is
    /// done, removed with it.
    private func keepArtworkOfDownloads() {
        let copies = Set(playbackContext.localCopies.keys)
        // Music's covers stay beside the films' pictures.
        let wanted = DownloadArtwork.wanted(for: copies, in: wholeCatalogue) + music.keptCovers
        let banners = DownloadArtwork.banners(for: copies, in: wholeCatalogue)
        let client = serverIsOutOfReach ? nil : client
        artworkKeeping?.cancel()
        artworkKeeping = Task { [artwork = environment.artwork] in
            await artwork.keep(wanted, banners: banners, using: client)
        }
    }

    /// The app came to the front.
    func becameActive() async {
        if phase != .launching { Task { await checkForUpdatesIfDue() } }
        guard phase == .library || phase == .chooseProfile else { return }
        if let outside = environment.road, await outside.becameActive() != nil {
            // The local server has another address than before.
            hasFoundServer = false
        }
        await refresh()
        // Whatever the refresh found: a download that waited for the network gets another try.
        await environment.downloads.retryWaiting()
    }

    /// Runs for as long as the app does: follows the downloads as they move.
    func watchDownloads() async {
        for await records in await environment.downloads.updates() {
            applyDownloads(records)
        }
    }

    func applyDownloads(_ records: [DownloadRecord]) {
        let previous = playbackContext.localCopies
        downloads = Dictionary(records.map { ($0.itemID, $0) }, uniquingKeysWith: { _, newer in newer })
        downloadsOverview = DownloadsOverview(records: records)
        if pendingPlay != nil { playPendingIfReady() }
        reportIfDownloadsChanged()
        // A copy arrived or went: Continue Watching says whether its film can play.
        if playbackContext.localCopies != previous {
            showCatalogue()
            keepArtworkOfDownloads()
            Task { await rebuildShelves() }
        }
    }

    /// Runs for as long as the app does: refreshes when the network comes back.
    func watchNetwork() async {
        var last: NetworkSignature?
        for await path in Reachability.paths() {
            await environment.road?.networkChanged(path)
            await environment.downloads.setOnMobileData(path.isExpensive)
            music.setOnMobileData(path.isExpensive)
            guard path.isUsable else {
                last = path
                continue
            }
            // Another network: the server may be at its other address now, and what answers
            // at the old one may be something else.
            hasFoundServer = false
            if path != last { networkCount += 1 }
            last = path
            // A refresh that still waits on the old network does not hold this up, nor what plays.
            _ = await findServer()
            await refresh()
        }
    }

    private func applyProfiles(_ listed: [Profile]) async throws {
        hasFetchedProfiles = true
        // An older server says nothing about kids limits or pictures: then what was known stays.
        let listed = listed.map { profile in
            let known = profiles.first { $0.id == profile.id } ?? (activeProfile?.id == profile.id ? activeProfile : nil)
            return profile.keepingUnsaid(of: known)
        }
        profiles = listed
        environment.settings.profiles = listed
        if isBoundToKids { return await followBinding() }
        guard let active = activeProfile else { return }
        if let current = listed.first(where: { $0.id == active.id }) {
            guard current != active else { return }
            activeProfile = current
            rememberKidsMode()
            if current.kids != active.kids {
                if (current.kids == nil) != (active.kids == nil) { startAtTheTop() }
                popular = await environment.popularStore.popular(kidsOnly: isKidsMode)
                showCatalogue()
                await rebuildShelves()
            }
        } else if active.kids != nil {
            // The kids viewer was deleted. The child keeps the kids screens, with nothing on
            // them; a grown-up leaves through the avatar.
            activeProfile = Self.withNothingToWatch(active)
            showCatalogue()
            await rebuildShelves()
        } else {
            // The viewer was deleted on the server, with their progress.
            try await environment.progressStore.removeProfile(active.id)
            activeProfile = nil
            progress = [:]
            environment.preferences.activeProfileID = nil
            phase = .chooseProfile
        }
    }

    private func handle(_ error: any Error) async {
        guard let error = error as? LobbyError else {
            if !(error is CancellationError) {
                problem = error.localizedDescription
            }
            return
        }
        if error.isUnreachable {
            connectivity = .offline
            // The next try looks at every address again.
            hasFoundServer = false
        } else if error.requiresPairing {
            await credentialLost(error)
        } else {
            // The server answered, so it is there. What it said is for the viewer to read.
            connectivity = .online
            problem = error.localizedDescription
        }
    }

    /// The server refused this device's credential: forget it and go back to Connect.
    ///
    /// The address, the catalogue and progress that was not sent yet stay. Pairing again with
    /// the same server picks them up; pairing with another one clears them.
    func credentialLost(_ error: LobbyError) async {
        guard client != nil else { return }
        if case .deviceRevoked = error {
            connectNotice = .deviceRemoved
        } else {
            connectNotice = .credentialNotRecognised
        }
        if let serverID = connection?.serverID {
            do {
                try await environment.credentials.removeToken(forServer: serverID)
            } catch {
                problem = "The old credential could not be removed from the Keychain. \(error.localizedDescription)"
            }
            await environment.road?.forget(serverID: serverID)
            await forgetPush(serverID: serverID)
        }
        await player?.close()
        places.stop()
        client = nil
        // Copies already on the device stay and play. Nothing new starts until it pairs again.
        await environment.downloads.setClient(nil)
        connectivity = .unknown
        road = nil
        hasDirect = false
        phase = .connect
    }

    // MARK: Pairing

    /// The address the Connect screen starts with.
    var rememberedAddress: String {
        environment.settings.lastServerAddress
            ?? environment.preferences.connection.map { ServerAddress.display($0.serverAddress) }
            ?? ""
    }

    func rememberAddress(_ text: String) {
        environment.settings.lastServerAddress = text
    }

    /// A manager approved this device, or it claimed the server: store the credential and move on.
    ///
    /// - Parameter found: The road, when it is not the address itself.
    func completePairing(address: URL, server: ServerInfo, grant: DeviceGrant, over found: ServerRoad.Found? = nil) async throws {
        // Two accounts of one server would be two devices that are one: the other one is used.
        if let other = account.otherAccountName(server.id) { throw ServerAlreadyAdded(name: other) }
        if let previous = environment.preferences.connection, previous.serverID != server.id {
            // Another household's server: nothing of the old one applies.
            try await forgetLibrary()
        }

        try await environment.credentials.setToken(grant.token, forServer: server.id)
        let saved = SavedConnection(
            serverAddress: address, serverID: server.id, serverName: server.name, deviceID: grant.device.id,
            pairedAddress: address)
        // Pairing just talked to this server at this address.
        hasFoundServer = true
        environment.preferences.connection = saved
        connection = saved
        // Who was watching before the device had to pair again, kids mode included.
        if activeProfile == nil {
            profiles = environment.settings.profiles
            restoreViewer()
        }
        device = grant.device
        environment.settings.device = grant.device
        await followBinding()
        let client = try found?.client ?? LobbyClient(baseURL: address, token: grant.token, session: environment.session)
        self.client = client
        road = found?.road ?? ServerRoad.road(of: address, in: saved)
        await environment.road?.askAgainAfterPairing(serverID: server.id)
        await environment.downloads.setClient(client)
        connectNotice = nil
        hasFetchedProfiles = false
        phase = activeProfile == nil ? .chooseProfile : .library
        await refresh()
    }

    // MARK: Pairing from outside

    /// What was received and not finished yet: kept, because a credential is handed out once.
    static let pendingPairingKey = "direct-pairing"

    private struct PendingPairing: Codable {
        var token: String
        var device: Device
        var identity: String
    }

    /// The manager approved this device from outside. Its credential is in the Keychain before
    /// anything else happens.
    func keepOutsidePairing(_ direct: DirectGrant) async throws {
        let pending = PendingPairing(token: direct.grant.token, device: direct.grant.device, identity: try direct.identity.encoded())
        let data = try LobbyJSON.encoder().encode(pending)
        try await environment.credentials.setToken(String(decoding: data, as: UTF8.self), forServer: Self.pendingPairingKey)
        environment.settings.introducer = direct.identity.introducer
    }

    /// A link that was opened on this device, until Connect takes it.
    private(set) var invitation: String?

    /// `lobby://pair…`, from the camera or a message. Only for a device that is not paired, and it
    /// only fills in what a person would type.
    func open(_ url: URL) {
        guard phase == .connect || phase == .launching, HouseholdInvitation.isPairingLink(url.absoluteString) else { return }
        invitation = url.absoluteString
    }

    func takeInvitation() -> String? {
        defer { invitation = nil }
        return invitation
    }

    static let noAddress = "direct.invalid"

    func hasOutsidePairing() async -> Bool { await pendingPairing() != nil }

    private func pendingPairing() async -> PendingPairing? {
        guard let text = try? await environment.credentials.token(forServer: Self.pendingPairingKey) else { return nil }
        return try? LobbyJSON.decoder().decode(PendingPairing.self, from: Data(text.utf8))
    }

    func forgetOutsidePairing() async {
        try? await environment.credentials.removeToken(forServer: Self.pendingPairingKey)
    }

    /// Connects for the first time over the direct road, learns which server it is, and moves on.
    func finishOutsidePairing() async throws {
        guard let outside = environment.road, let pending = await pendingPairing(),
            let identity = DirectIdentity(encoded: pending.identity)
        else { throw DirectError.badIdentity }
        let found = try await outside.enter(identity, token: pending.token)
        let me = try await found.client.me()
        try await outside.keep(identity, forServer: me.server.id)
        hasDirect = true
        // Where it is at home, for the day this device is there. A server that does not say has no
        // address: a name that never exists (RFC 2606) stands for it, and nothing is asked anywhere.
        guard let address = me.server.addresses?.inOrder.first ?? URL(string: "https://\(Self.noAddress)") else {
            throw DirectError.badIdentity
        }
        do {
            try await completePairing(
                address: address, server: me.server, grant: DeviceGrant(device: me.device, token: pending.token), over: found)
        } catch let error as ServerAlreadyAdded {
            // Kept, it would be tried again at every launch.
            await forgetOutsidePairing()
            await outside.close()
            hasDirect = false
            throw error
        }
        await forgetOutsidePairing()
    }

    /// Runs while the viewer picker is open: fetches the list apart from the library, again
    /// and again, so that it appears however the first try went and follows other devices.
    func watchProfiles() async {
        while !Task.isCancelled {
            await fetchProfiles()
            do { try await Task.sleep(for: .seconds(hasFetchedProfiles ? 5 : 2)) } catch { return }
        }
    }

    func fetchProfiles() async {
        guard let client else { return }
        do {
            try await applyProfiles(try await client.profiles())
            connectivity = .online
        } catch {
            // The picker closed while the answer was on its way; that says nothing about the server.
            guard !Task.isCancelled else { return }
            await handle(error)
        }
    }

    /// Sign out: forget the credential and everything fetched with it.
    func signOut() async {
        await player?.close()
        places.stop()
        // While the credential is still there to say who stops getting pushes.
        await unregisterPush()
        if let client {
            // One last try to deliver what the viewer watched. Offline, it cannot be delivered,
            // and signing out says to forget it.
            _ = try? await environment.progressStore.flush(using: client)
        }
        do {
            if let serverID = connection?.serverID {
                try await environment.credentials.removeToken(forServer: serverID)
                await environment.road?.forget(serverID: serverID)
                await forgetPush(serverID: serverID)
            }
            await forgetOutsidePairing()
            try await forgetLibrary()
        } catch {
            problem = "Signing out did not finish. \(error.localizedDescription)"
        }
        environment.preferences.connection = nil
        connection = nil
        client = nil
        road = nil
        hasDirect = false
        household = nil
        device = nil
        serverInfo = nil
        connectNotice = nil
        connectivity = .unknown
        phase = .connect
    }

    private func forgetLibrary() async throws {
        environment.preferences.activeProfileID = nil
        environment.settings.forgetConnection()
        activeProfile = nil
        profiles = []
        hasFetchedProfiles = false
        wholeCatalogue = Catalogue()
        viewerCatalogue = Catalogue()
        catalogue = Catalogue()
        kidsLibrary = .empty
        grownUpNotice = nil
        wantedRevision = nil
        lastReported = nil
        categoryGroups = .none
        popular = .none
        progress = [:]
        shelves = .empty
        homePage = .empty
        builder = nil
        pages = [:]
        relatedRows = [:]
        lastSyncedAt = nil
        serverSetup = nil
        storedServerSettings = nil
        try await environment.catalogueStore.clear()
        try await environment.categoryGroupsStore.clear()
        try await environment.popularStore.clear()
        try await environment.progressStore.clear()
        await environment.artwork.clear()
        await environment.downloads.removeAll()
        await music.signOut()
    }

    // MARK: Viewers

    /// Chooses who is watching. Their Continue Watching and resume positions replace the
    /// previous viewer's at once, from the device's copy, and are then brought up to date.
    func selectProfile(_ profile: Profile) async {
        // In kids mode the choice is behind the grown-up's question, and on a bound device
        // there is none.
        guard !isBoundToKids, phase == .chooseProfile || !showsKidsScreens else { return }
        // As it is now: what was on screen may be from before a change.
        let profile = profiles.first { $0.id == profile.id } ?? profile
        if activeProfile?.id != profile.id { startAtTheTop() }
        activeProfile = profile
        environment.preferences.activeProfileID = profile.id
        // The server keeps some things to the viewer in front: it hears of the switch at once.
        remote.changed()
        rememberKidsMode()
        showCatalogue()
        progress = await environment.progressStore.progress(profileID: profile.id)
        popular = await environment.popularStore.popular(kidsOnly: isKidsMode)
        await rebuildShelves()
        phase = .library
        await syncProgress()
    }

    /// Back to the viewer picker, e.g. from the profile menu.
    func chooseAnotherProfile() {
        guard !showsKidsScreens else { return }
        phase = .chooseProfile
    }

    /// Who was watching before Who is watching? was opened: the picker offers the way back to
    /// them. nil at the start, when nobody was chosen yet.
    var viewerToReturnTo: Profile? {
        phase == .chooseProfile ? activeProfile : nil
    }

    /// The picker was left without choosing: whoever was watching still is.
    func returnToLibrary() {
        if viewerToReturnTo != nil { phase = .library }
    }

    private func asksWhoIsWatching(isLaunch: Bool) -> Bool {
        // Never out of kids mode, and not where there is nobody else.
        environment.asksWhoIsWatching && !isKidsMode && profiles.count > 1
            && environment.settings.viewerQuestion.asks(
                isLaunch: isLaunch, lastUsed: environment.settings.lastUsedAt, now: environment.now())
    }

    /// Back in front: asks who is watching when it was away for long enough.
    func cameBack() {
        if phase == .library, player == nil, asksWhoIsWatching(isLaunch: false) {
            #if os(tvOS)
            // Brought to the front by Lobby Server for a play, perhaps: the channel says so in a moment.
            heardOfRemotePlay(waiting: true, for: .seconds(3))
            #endif
            phase = .chooseProfile
        }
    }

    /// `POST /v1/profiles`. Only a manager device may.
    ///
    /// - Parameter kids: What a kids viewer may watch. nil: not a kids viewer.
    func addProfile(name: String, color: String, avatar: String? = nil, kids: KidsSettings? = nil) async throws {
        guard let client else { return }
        let added = try await client.createProfile(name: name, color: color, avatar: avatar, kids: kids)
        if kids != nil, added.kids == nil {
            // An older server made an ordinary viewer of it: the person must know.
            try await applyProfiles(try await client.profiles())
            throw KidsUnsupported()
        }
        // The server's list, not this device's idea of it.
        try await applyProfiles(try await client.profiles())
    }

    /// Marks a film or episode watched for the active viewer.
    func markWatched(itemID: String) async {
        await changeProgress { store, profileID in
            try await store.markWatched(
                profileID: profileID, itemID: itemID, durationMs: self.wholeCatalogue.item(itemID)?.displayDurationMs)
        }
    }

    /// Marks it unwatched, which also forgets where the viewer stopped.
    func markUnwatched(itemID: String) async {
        await changeProgress { store, profileID in
            try await store.markUnwatched(profileID: profileID, itemID: itemID)
        }
    }

    /// Marks every episode of a series or season, as if each were marked.
    func markEpisodes(of itemID: String, watched: Bool) async {
        let episodes = wholeCatalogue.descendants(of: itemID).filter { $0.kind == .episode }
        await changeProgress { store, profileID in
            for episode in episodes {
                // What already is that way keeps its own date.
                let known = self.progress[episode.id]
                if watched, known?.completed != true {
                    try await store.markWatched(profileID: profileID, itemID: episode.id, durationMs: episode.displayDurationMs)
                } else if !watched, let known, known.completed || known.positionMs > 0 {
                    try await store.markUnwatched(profileID: profileID, itemID: episode.id)
                }
            }
        }
    }

    private func changeProgress(_ change: (ProgressStore, String) async throws -> Void) async {
        guard let profile = activeProfile else { return }
        do {
            try await change(environment.progressStore, profile.id)
        } catch {
            problem = "That could not be saved on this device. \(error.localizedDescription)"
        }
        await reloadProgress()
        await syncProgress()
    }

    /// Makes a viewer a kids viewer, changes what they may watch, or (nil) makes them an
    /// ordinary viewer. Only a manager may.
    func setKids(_ kids: KidsSettings?, profileID: String) async throws {
        let changed = try await asManager { try await $0.setKids(kids, profileID: profileID) }
        guard changed.saysKids, changed.kids == kids || (changed.kids != nil && kids != nil) else { throw KidsUnsupported() }
        try await applyProfiles(profiles.map { $0.id == changed.id ? changed : $0 })
    }

    /// Whether there are pictures to choose: not with a server from before them. It is not known
    /// until there is a viewer.
    var offersAvatars: Bool { profiles.isEmpty || profiles.contains(where: \.saysAvatar) }

    /// Gives a viewer another picture, or (nil) their letter. Not only for managers. Nothing is
    /// kept to be sent later: out of reach it fails.
    func setAvatar(_ avatar: String?, profileID: String) async throws {
        do {
            let changed = try await atServer { try await $0.setAvatar(avatar, profileID: profileID) }
            guard changed.saysAvatar else { throw AvatarsUnsupported() }
            try await applyProfiles(profiles.map { $0.id == changed.id ? changed : $0 })
        } catch LobbyError.notFound(let message) {
            guard offersAvatars else { throw AvatarsUnsupported() }
            throw LobbyError.notFound(message: message)
        }
    }

    /// Whether the server keeps subtitle preferences: not one from before them.
    var offersSubtitlePreferences: Bool { profiles.contains { $0.subtitles != nil } }

    /// How a viewer wants subtitles. Not only for managers: whoever watches as the viewer. Nothing
    /// is kept to be sent later: out of reach it fails.
    func setSubtitlePreferences(_ preferences: SubtitlePreferences, profileID: String) async throws {
        let changed = try await atServer { try await $0.setSubtitlePreferences(preferences, profileID: profileID) }
        try await applyProfiles(profiles.map { $0.id == changed.id ? changed.keepingUnsaid(of: $0) : $0 })
    }

    /// Whether the server keeps what happens at the end per viewer: not one from before that.
    var offersPlaybackPreferences: Bool { profiles.contains { $0.playback != nil } }

    /// What happens at the end, for a viewer. For an ordinary viewer whoever watches as them; for a
    /// kids viewer only a manager (the server says no otherwise). Nothing is kept to be sent
    /// later: out of reach it fails. The player goes by it from the next end on.
    func setPlaybackPreferences(_ preferences: PlaybackPreferences, profileID: String) async throws {
        let changed = try await atServer { try await $0.setPlaybackPreferences(preferences, profileID: profileID) }
        try await applyProfiles(profiles.map { $0.id == changed.id ? changed.keepingUnsaid(of: $0) : $0 })
    }

    /// A server admin has a season's intros and credits looked for again. Returns how many
    /// episodes the server will look at.
    func findMarkers(itemID: String) async throws -> Int {
        try await atServer { try await $0.findMarkers(itemID: itemID) }
    }

    /// Whether the server keeps what viewers want at intros and credits: not one from before.
    var offersSkipPreferences: Bool { profiles.contains { $0.skipping != nil } }

    /// What a viewer wants at intros and credits. A child's device cannot change it: a grown-up
    /// chooses it for a kids viewer, from their own device.
    func setSkipPreferences(_ preferences: SkipPreferences, profileID: String) async throws {
        let changed = try await atServer { try await $0.setSkipPreferences(preferences, profileID: profileID) }
        try await applyProfiles(profiles.map { $0.id == changed.id ? changed.keepingUnsaid(of: $0) : $0 })
    }

    /// `DELETE /v1/profiles/{id}`: removes a viewer and their progress. Only a manager may.
    func removeProfile(_ profile: Profile) async throws {
        guard let client else { return }
        try await client.deleteProfile(id: profile.id)
        try await environment.progressStore.removeProfile(profile.id)
        profiles.removeAll { $0.id == profile.id }
        environment.settings.profiles = profiles
        if activeProfile?.id == profile.id {
            activeProfile = nil
            progress = [:]
            environment.preferences.activeProfileID = nil
            rememberKidsMode()
            showCatalogue()
            phase = .chooseProfile
        }
    }

    private func syncProgress() async {
        guard let client, let profile = activeProfile else { return }
        do {
            try await environment.progressStore.synchronise(profileID: profile.id, using: client)
            connectivity = .online
        } catch {
            await handle(error)
        }
        await reloadProgress()
    }

    // MARK: Library

    /// A film, show, season or episode. One that is not on screen any more (the server went
    /// out of reach while its page was open) is still found: the page stays.
    func item(_ id: String) -> Item? {
        catalogue.item(id) ?? viewerCatalogue.item(id)
    }

    func movieDetail(for item: Item) -> MovieDetail {
        MovieDetail(item: item, progress: progress[item.id], context: playbackContext)
    }

    /// The trailers and other extras of a film that play here.
    struct Extra: Hashable, Identifiable {
        var request: PlayRequest
        var title: String
        var artwork: Artwork?
        var id: String { request.id }
    }

    func extras(of item: Item) -> [Extra] {
        catalogue.children(of: item.id).filter { $0.kind == .extra }
            .sorted { ($0.sortTitle, $0.id) < ($1.sortTitle, $1.id) }
            .compactMap { extra in
                PlayActionBuilder.action(for: extra, progress: nil, context: playbackContext).request.map {
                    Extra(request: $0, title: extra.title, artwork: extra.artwork.still ?? extra.artwork.backdrop ?? item.artwork.backdrop)
                }
            }
    }

    func showDetail(for show: Item) -> ShowDetail {
        ShowDetail(show: show, catalogue: catalogue, progress: progress, context: playbackContext)
    }

    func search(_ query: String) -> [Item] {
        Shelves.search(query, in: catalogue)
    }

    /// How the household wants a category shown: its logo, its symbol, its colour.
    func look(ofCategory id: String) -> CategoryLook {
        CategoryLook(category: id, in: categoryGroups)
    }

    /// How a shelf of the library is shown. A genre is nobody's setting.
    func look(of shelf: CategoryShelf) -> CategoryLook {
        shelf.source == .genre ? .plain : look(ofCategory: shelf.categoryID)
    }

    /// How the household wants a part of the library shown.
    func look(ofGroup id: String) -> CategoryLook {
        CategoryLook(group: id, in: categoryGroups)
    }

    /// A category's logo. nil when it cannot be fetched: the caller shows the symbol.
    func logo(_ logo: CategoryLogo) async -> CGImage? {
        guard let client else { return nil }
        return try? await environment.artwork.logo(logo, using: client, serverIsOutOfReach: serverIsOutOfReach || !hasFoundServer)
    }

    /// A small picture a manager chooses from. nil when it cannot be fetched.
    func preview(atPath path: String) async -> CGImage? {
        guard let data = try? await asManager({ try await $0.picture(atServerPath: path) }) else { return nil }
        return PictureEncoder.image(from: data, maxPixels: 800)
    }

    /// A poster, backdrop or still. nil when it cannot be fetched: the caller keeps its title tile.
    func artwork(_ artwork: Artwork, pixelWidth: Int) async -> CGImage? {
        guard let client else { return nil }
        return try? await environment.artwork.image(
            for: artwork, pixelWidth: pixelWidth, using: client, serverIsOutOfReach: serverIsOutOfReach)
    }

    /// The connection search asks over; nil while there is none. Search has no offline copy
    /// beyond the titles: without the server it falls back to `search(_:)`.
    var searchConnection: LobbyClient? {
        serverIsOutOfReach ? nil : client
    }

    /// A poster or a person's picture from TMDB, through the server. nil when there is none.
    func searchPicture(_ path: String, maxPixels: Int) async -> CGImage? {
        guard let client = searchConnection, let data = try? await client.searchPicture(path: path) else { return nil }
        return PictureEncoder.image(from: data, maxPixels: maxPixels)
    }

    /// The leading colours of some pictures together. nil when there are none to be had.
    func palette(of artworks: [Artwork]) async -> ArtworkPalette? {
        guard let client else { return nil }
        var palettes: [ArtworkPalette] = []
        for artwork in artworks {
            if let palette = await environment.artwork.palette(
                of: artwork, using: client, serverIsOutOfReach: serverIsOutOfReach) {
                palettes.append(palette)
            }
        }
        return palettes.isEmpty ? nil : ArtworkPalette(merging: palettes)
    }

    /// Builds the shelves from what is on screen now. Returns when the shelves are those of
    /// the newest state: a rebuild that a newer one overtook waits for that one.
    private func rebuildShelves() async {
        shelfGeneration += 1
        let generation = shelfGeneration
        let catalogue = catalogue, groups = categoryGroups, progress = progress, context = playbackContext
        let isKids = isKidsMode
        let popular = popular, kidsSettings = activeProfile?.kids
        // Whose watching counts: on a kids page only that of kids.
        let viewers = profiles.filter { !isKids || $0.kids != nil }.map(\.id)
        let progressStore = environment.progressStore
        let task = Task {
            var others: [[String: PlaybackProgress]] = []
            if popular.titles.isEmpty {
                for id in viewers { others.append(await progressStore.progress(profileID: id)) }
            }
            let (built, builder, home) = await Self.buildShelves(
                catalogue: catalogue, groups: groups, progress: progress, context: context, popular: popular, viewers: others)
            let kids = isKids
                ? await Self.buildKids(
                    catalogue: catalogue, groups: groups, limits: kidsSettings, progress: progress, context: context, popular: popular, viewers: others)
                : .empty
            // A newer rebuild started while this one ran: its result is the one to show.
            if generation == self.shelfGeneration {
                self.builder = builder
                self.pages = [PageKey(scope: .home): home]
                self.relatedRows = [:]
                self.shelves = built
                self.homePage = home
                self.kidsLibrary = kids
            }
        }
        newestRebuild = task
        await task.value
        var seen = generation
        while seen != shelfGeneration {
            seen = shelfGeneration
            await newestRebuild?.value
        }
    }

    /// Sorting a few thousand items is not work for the main thread.
    @concurrent
    private nonisolated static func buildShelves(
        catalogue: Catalogue, groups: CategoryGroups, progress: [String: PlaybackProgress], context: PlaybackContext,
        popular: Popular, viewers: [[String: PlaybackProgress]]
    ) async -> (LibraryShelves, BrowseBuilder, BrowsePage) {
        let shelves = LibraryShelves(catalogue: catalogue, groups: groups, progress: progress, context: context)
        let builder = BrowseBuilder(
            catalogue: catalogue, shelves: shelves, progress: progress, context: context, popular: popular, viewers: viewers)
        return (shelves, builder, builder.page(.home))
    }

    @concurrent
    private nonisolated static func buildKids(
        catalogue: Catalogue, groups: CategoryGroups, limits: KidsSettings?, progress: [String: PlaybackProgress],
        context: PlaybackContext, popular: Popular, viewers: [[String: PlaybackProgress]]
    ) async -> KidsLibrary {
        KidsLibrary(
            catalogue: catalogue, groups: groups, limits: limits, progress: progress, context: context, popular: popular, viewers: viewers)
    }

    /// Related on a kids page: from what this child may watch and what plays.
    func kidsRelated(to item: Item) -> [Item] {
        let kids = kidsLibrary.catalogue
        let titles = kids.items.filter { Shelves.topLevelKinds.contains($0.kind) }
        let progress = progress
        // Everything there plays: a kids catalogue holds nothing else.
        return RelatedTitles.rank(item, among: titles, isPlayable: { _ in true }, isWatched: { title in
            title.kind == .show
                ? EpisodeOrder.episodes(ofShow: title.id, in: kids).allSatisfy { progress[$0.id]?.completed == true }
                : progress[title.id]?.completed == true
        })
    }

    /// What the end screen suggests after a film, or after a series' last episode: what goes
    /// with it (the same as its page's Related), and what the viewer was watching. Only what this
    /// viewer may see and what plays here.
    func upNextSuggestions(after request: PlayRequest) -> [UpNextSuggestion] {
        let source = request.show ?? request.item
        let kids = showsKidsScreens
        let catalogue = kids ? kidsLibrary.catalogue : self.catalogue
        let related: [Item] =
            kids
            ? kidsRelated(to: source)
            : self.related(to: source).flatMap { row -> [Item] in
                if case .items(let items) = row.content { return items }
                return []
            }
        let cards = kids ? kidsLibrary.continueWatching : shelves.continueWatching
        let continuing = cards.compactMap { UpNextSuggestions.suggestion(from: $0, catalogue: catalogue) }
        let progress = progress, context = playbackContext
        return UpNextSuggestions.make(after: source, related: related, continuing: continuing) { item in
            UpNextSuggestions.request(for: item, catalogue: catalogue, progress: progress, context: context)
        }
    }

    /// Rows that go with a film or series.
    func related(to item: Item) -> [BrowseRow] {
        _ = homePage
        if let made = relatedRows[item.id] { return made }
        let rows = builder?.related(to: item) ?? []
        relatedRows[item.id] = rows
        return rows
    }

    /// A page of the library: its banner and rows. Made once for each state of the library.
    ///
    /// - Parameter section: Of a category with others inside it, the one of those to show
    ///   under its banner; nil for all of it.
    func page(_ scope: BrowseScope, section: String? = nil) -> BrowsePage {
        let home = homePage
        if scope == .home { return home }
        let key = PageKey(scope: scope, section: section)
        if let made = pages[key] { return made }
        guard let builder else { return .empty }
        let page = builder.page(scope, avoiding: Set(home.banner.map(\.id)), section: section)
        pages[key] = page
        return page
    }

    /// The household's categories with a name like this, also those inside another.
    func searchCategories(_ query: String) -> [CategoryShelf] {
        shelves.categories(matching: query)
    }

    // MARK: Downloads

    func downloadStatus(for itemID: String) -> DownloadStatus {
        DownloadStatus(record: downloads[itemID])
    }

    /// Whether anything of this film or episode could be kept on this device.
    func canDownload(_ item: Item) -> Bool {
        PlayActionBuilder.fileToDownload(for: item, capabilities: environment.capabilities) != nil
    }

    /// Keeps a film or episode on this device. Also what Update does for a copy that is out
    /// of date.
    func download(_ item: Item) async {
        guard let file = PlayActionBuilder.fileToDownload(for: item, capabilities: environment.capabilities) else { return }
        await environment.downloads.enqueue(
            item, file: file, show: item.kind == .episode ? wholeCatalogue.show(of: item) : nil,
            allowsCellular: downloadsUseMobileData)
    }

    func pauseDownload(itemID: String) async {
        await environment.downloads.pause(itemID: itemID)
    }

    func resumeDownload(itemID: String) async {
        await environment.downloads.resume(itemID: itemID)
    }

    /// Removes the copy on this device. The file on Lobby Server is not touched.
    func removeDownload(itemID: String) async {
        await environment.downloads.remove(itemID: itemID)
    }

    func perform(_ action: DownloadAction, on item: Item) async {
        switch action {
        case .download, .update: await download(item)
        case .pause: await pauseDownload(itemID: item.id)
        case .resume: await resumeDownload(itemID: item.id)
        case .remove: await removeDownload(itemID: item.id)
        }
    }

    /// What Download Season would fetch and whether it fits, to show before it starts.
    func seasonDownloadPlan(seasonID: String) async -> SeasonDownloadPlan {
        let episodes = EpisodeOrder.episodes(ofSeason: seasonID, in: wholeCatalogue)
        var toFetch: [Item] = []
        var skipped = 0
        var alreadyHere = 0
        var bytes: Int64 = 0
        for episode in episodes {
            if let record = downloads[episode.id], record.state.isActive || record.isVerifiedAndCurrent {
                alreadyHere += 1
            } else if let file = PlayActionBuilder.fileToDownload(for: episode, capabilities: environment.capabilities) {
                toFetch.append(episode)
                bytes += file.sizeBytes
            } else {
                skipped += 1
            }
        }
        return SeasonDownloadPlan(
            episodes: toFetch, skipped: skipped, alreadyHere: alreadyHere, neededBytes: bytes,
            availableBytes: await environment.downloads.spaceForDownloads())
    }

    func download(_ plan: SeasonDownloadPlan) async {
        for episode in plan.episodes {
            await download(episode)
        }
    }

    func setDownloadsUseMobileData(_ allowed: Bool) async {
        downloadsUseMobileData = allowed
        environment.settings.downloadsUseMobileData = allowed
        await environment.downloads.setAllowsCellular(allowed)
        music.setDownloadsUseMobileData(allowed)
    }

    /// The system relaunched the app for a finished background download.
    func handleBackgroundDownloadEvents(completion: @escaping @Sendable () -> Void) async {
        await environment.downloads.handleBackgroundEvents(completion: completion)
    }

    // MARK: Playing on another device

    /// The connection for the live channel: only to an address that was found to be the server.
    var liveClient: LobbyClient? {
        hasFoundServer && !serverIsOutOfReach && !isSuspended ? client : nil
    }

    /// Others see this device and can play on it. Televisions and Macs are, unless somebody
    /// says otherwise; phones and iPads only when somebody says so on them.
    var isTarget: Bool {
        device?.isTarget ?? (device?.platform == .tvos || device?.platform == .macos)
    }

    /// `PATCH /v1/me`. Out of reach, it stays as it was and says so.
    func setIsTarget(_ on: Bool) async {
        do {
            let changed = try await atServer { try await $0.setIsTarget(on) }
            await applyDevice(changed)
        } catch {
            problem = await managerProblem(error)
        }
    }

    /// Trailers for a kids viewer on this device (Settings).
    var kidsTrailers: Bool {
        get {
            access(keyPath: \.kidsTrailers)
            return environment.settings.kidsTrailers
        }
        set {
            withMutation(keyPath: \.kidsTrailers) { environment.settings.kidsTrailers = newValue }
        }
    }

    /// The trailers of a film or series that can play now: YouTube's while the server is in
    /// reach (it is fetched from YouTube, not from the server, but offline nothing is), and the
    /// household's own trailer files. None for a kids viewer when a grown-up turned them off.
    func trailers(of item: Item) -> [Trailer] {
        if isKidsMode, !kidsTrailers { return [] }
        if isKidsMode, viewerCatalogue.item(item.id) == nil { return [] }
        var found: [Trailer] = []
        if let online = item.trailer, online.provider == .youtube, Trailer.isKey(online.key), !serverIsOutOfReach,
            connectivity != .offline
        {
            found.append(.youtube(key: online.key))
        }
        for extra in extras(of: item) where catalogue.item(extra.id)?.extraKind == .trailer {
            found.append(.file(extra.request, title: extra.title))
        }
        return found
    }

    /// Whether a viewer may watch a title: everything, except for a kids viewer.
    func mayWatch(_ itemID: String, as profile: Profile) -> Bool {
        guard let kids = profile.kids else { return wholeCatalogue.item(itemID) != nil }
        return wholeCatalogue.limited(to: kids, groups: categoryGroups).item(itemID) != nil
    }

    /// The live channel said whether a play waits for this device (it was woken for one), or the
    /// play came. While one waits, who is watching is not asked; at most `for` long.
    func heardOfRemotePlay(waiting: Bool, for wait: Duration = .seconds(20)) {
        awaitsRemotePlayEnd?.cancel()
        awaitsRemotePlay = waiting
        guard waiting else { return }
        awaitsRemotePlayEnd = Task { [weak self] in
            do { try await Task.sleep(for: wait) } catch { return }
            self?.awaitsRemotePlay = false
        }
    }

    /// Another device asked this one to play a title, as a viewer (`play`). Returns why not, as
    /// one of the fixed reasons, or nil once the film is certain to start. It replaces whatever is
    /// shown: the player of another title is closed, and the new title's page is what is behind it.
    func playFromRemote(_ command: PlayCommand) async -> String? {
        guard client != nil, phase == .library || phase == .chooseProfile else { return RemoteFailure.cannotPlay }
        // A bound device plays only as its child, and the kids screens only as the child on them.
        if let bound = device?.kidsProfileId, bound != command.profileId { return RemoteFailure.notAllowed }
        if isKidsMode, activeProfile?.id != command.profileId { return RemoteFailure.notAllowed }
        let known = profiles.first { $0.id == command.profileId } ?? (activeProfile?.id == command.profileId ? activeProfile : nil)
        guard let profile = known else { return RemoteFailure.notFound }
        // Just opened after a while asleep: what was added meanwhile is fetched first.
        if wholeCatalogue.item(command.itemId) == nil { await refresh() }
        guard let item = wholeCatalogue.item(command.itemId) else { return RemoteFailure.notFound }
        guard mayWatch(item.id, as: profile) else { return RemoteFailure.notAllowed }

        await player?.close()
        if activeProfile?.id != profile.id || phase == .chooseProfile {
            if isBoundToKids {
                phase = .library
            } else {
                await selectProfile(profile)
            }
        }
        guard activeProfile?.id == profile.id else { return RemoteFailure.cannotPlay }
        let show = item.kind == .episode ? wholeCatalogue.show(of: item) : nil
        guard var request = PlayActionBuilder.action(
            for: item, show: show, progress: progress[item.id], context: playbackContext
        ).request else { return RemoteFailure.cannotPlay }
        if let start = command.startMs {
            request.startPositionMs = max(0, min(start, (request.durationMs ?? Int.max) - 1_000))
        }
        remoteOpened = RemoteOpened(itemID: show?.id ?? item.id)
        play(request)
        guard let player else { return RemoteFailure.cannotPlay }
        player.takeRemoteChoices(audioTrackID: command.audioTrackId, subtitleTrackID: command.subtitleTrackId, paused: command.paused)
        // Taken on once the picture is on its way: loading lasts a moment, preparing longer.
        for _ in 0..<60 {
            switch player.stage {
            case .playing, .preparing, .ended: return nil
            case .failed: return RemoteFailure.cannotPlay
            case .loading: try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return nil
    }

    // MARK: Playback

    func play(_ request: PlayRequest) {
        guard player == nil, !isSuspended, let client, let profile = activeProfile else { return }
        guard !isKidsMode || viewerCatalogue.item(request.item.id) != nil else { return }
        let player = PlayerModel(
            request: request, client: client, profileID: profile.id,
            catalogue: showsKidsScreens ? kidsLibrary.catalogue : catalogue, isForKids: showsKidsScreens, app: self)
        // The search field lets go of the keyboard.
        isSearching = false
        // The music makes room for the film.
        music.player.pauseForFilm()
        self.player = player
        player.start()
    }

    /// The player wrote a position down: Continue Watching and the Resume labels follow.
    func reloadProgress() async {
        guard let profile = activeProfile else { return }
        progress = await environment.progressStore.progress(profileID: profile.id)
        await rebuildShelves()
    }

    /// The player went away (the viewer closed it, or the film ended).
    func playerClosed() async {
        player = nil
        await reloadProgress()
    }

    /// A grown-up opened the picker from the kids screens and left it without choosing.
    func closeOpenPicker() {
        if phase == .chooseProfile, showsKidsScreens { phase = .library }
    }

    // MARK: Several servers

    /// Another server is to be used: what plays stops with its place written down, the live
    /// channel and the direct connection end, and nothing new starts. The screens' own loops
    /// end with the screens. Downloads at home or over Tailscale go on in the background with
    /// their own server; those the app carried over the direct road wait for it.
    func suspend() async {
        guard !isSuspended else { return }
        isSuspended = true
        finding?.cancel()
        artworkKeeping?.cancel()
        if let player {
            await player.close()
            self.player = nil
        }
        music.player.stop()
        if environment.asksWhoIsWatching { environment.settings.lastUsedAt = environment.now() }
        if client?.isCarriedByRoad == true { await environment.downloads.setClient(nil) }
        await environment.road?.close()
        road = nil
        hasFoundServer = false
        places.stop()
        // The pages' models hold this one: without them it goes once the screens let go.
        storedManager = nil
        storedServerSettings = nil
        storedUploads = nil
    }

    /// Who is watching, after "Which library?": the viewers of this server. Not out of kids mode,
    /// which keeps its viewer.
    func askForViewer() {
        guard !isKidsMode else { return }
        switch phase {
        case .launching: asksForViewer = true
        case .library: phase = .chooseProfile
        case .connect, .chooseProfile: break
        }
    }

    /// Plays a download of this server once a viewer is chosen, as its Downloads would.
    func playWhenReady(_ itemID: String) {
        pendingPlay = itemID
        playPendingIfReady()
    }

    private func playPendingIfReady() {
        guard let itemID = pendingPlay, phase == .library, player == nil, activeProfile != nil,
            let record = downloads[itemID]
        else { return }
        pendingPlay = nil
        let item = self.item(itemID) ?? record.item
        let show = item.kind == .episode ? catalogue.show(of: item) : nil
        if let request = PlayActionBuilder.action(for: item, show: show, progress: progress[item.id], context: playbackContext).request {
            play(request)
        }
    }

    /// The app went to the background: write the position down before the system suspends it.
    func enteredBackground() async {
        closeOpenPicker()
        if environment.asksWhoIsWatching { environment.settings.lastUsedAt = environment.now() }
        await player?.checkpoint()
        await environment.road?.enteredBackground()
    }
}

/// What the app's list of servers wants to know of the server in use, and says of the others.
/// Empty for an app model on its own, as in most tests.
struct AccountHooks {
    /// The paired server changed: its name, its id, or it is gone.
    var connectionChanged: @MainActor (SavedConnection?) -> Void = { _ in }
    /// The name of another account of this app that is paired with this server, if any.
    var otherAccountName: @MainActor (String) -> String? = { _ in nil }
}

/// The server just paired with is in the app already, as another account.
struct ServerAlreadyAdded: LocalizedError, Hashable {
    var name: String
    var errorDescription: String? {
        "This server is in Lobby already, as “\(name)”. Switch to it from the viewer menu."
    }
}
