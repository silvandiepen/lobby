// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyDirect
import LobbyKit
import Synchronization
import Testing

@testable import Lobby

/// Several servers in one app, with the real stores on files and two stub servers: each one's
/// accounts, credentials, catalogue, progress queue, downloads and notices stay its own.
@MainActor
final class TwoServers {
    let home: Household
    let grandma: Household
    let directory: TemporaryDirectory
    let caches: TemporaryDirectory
    let store: ServerAccountsStore
    /// Each account's Keychain, by account id: one service each, as in the app.
    private(set) var keychains: [String: InMemoryCredentialStore] = [:]
    /// What the grown-up says when kids mode is to be left, read each time it is asked.
    private final class Answer: Sendable {
        let value = Mutex(GrownUpCheck.confirmed)
    }
    private let answer = Answer()
    var grownUp: GrownUpCheck {
        get { answer.value.withLock { $0 } }
        set { answer.value.withLock { $0 = newValue } }
    }
    var hasKidsScreens = true
    private let base = "mt.sil.lobby.tests.\(UUID().uuidString)"
    private let configuration: URLSessionConfiguration

    static let homeFilm = Data(repeating: 3, count: 200_000)

    init(home: Household? = nil) throws {
        self.home = home ?? Household(.init(
            items: [Make.movie("up", title: "Up", files: [Make.file(assetID: "up-file", sizeBytes: 200_000)])],
            token: "home-token",
            files: ["up-file": Self.homeFilm]))
        grandma = Household(.init(
            server: ServerInfo(id: "server-2", name: "Grandma's", version: "0.1.0", apiVersion: 1, claimed: true),
            device: Device(id: "dev-g", name: "Test iPhone", platform: .ios, role: .viewer, createdAt: Make.epoch),
            profiles: [Profile(id: "anna", name: "Anna", color: "pink")],
            items: [Make.movie("heidi", title: "Heidi", files: [Make.file(assetID: "heidi-file", sizeBytes: 100_000)])],
            token: "grandma-token",
            files: ["heidi-file": Data(repeating: 9, count: 100_000)]))
        directory = try TemporaryDirectory()
        caches = try TemporaryDirectory()
        store = ServerAccountsStore(root: directory.url, caches: caches.url, base: base, legacySuite: base)
        configuration = self.home.stub.configuration
    }

    deinit {
        // The suites of every account this test made.
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: directory.url.appending(path: "Servers").path)) ?? []
        for name in [base] + folders.map({ "\(base).server.\($0)" }) {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
    }

    func keychain(_ account: ServerAccount) -> InMemoryCredentialStore {
        if let known = keychains[account.id] { return known }
        let made = InMemoryCredentialStore()
        keychains[account.id] = made
        return made
    }

    var making: ServersModel.Making {
        let configuration = configuration
        return ServersModel.Making(
            store: store,
            downloads: { [store] account in
                DownloadManager(
                    directory: LobbyStorage.downloadsDirectory(in: try store.directory(of: account)),
                    sessionConfiguration: configuration,
                    sleep: { _ in
                        try Task.checkCancellation()
                        await Task.yield()
                    },
                    availableSpace: { _ in 64_000_000_000 }, spaceReserveBytes: 0)
            },
            environment: { [unowned self] account, downloads in try self.environment(account, downloads) },
            removeCredentials: { [unowned self] account in
                let keychain = await self.keychain(account)
                await keychain.removeAll()
            },
            isReachable: { [home, grandma] account in
                account.serverID == "server-2" ? !grandma.current.offline : !home.current.offline
            })
    }

    private func environment(_ account: ServerAccount, _ downloads: DownloadManager) throws -> AppEnvironment {
        let folder = try store.directory(of: account)
        let session = URLSession(configuration: configuration)
        let suite = account.storage.defaultsSuite
        var environment = AppEnvironment(
            catalogueStore: CatalogueStore(fileURL: LobbyStorage.catalogueFile(in: folder)),
            categoryGroupsStore: CategoryGroupsStore(fileURL: LobbyStorage.categoriesFile(in: folder)),
            popularStore: PopularStore(fileURL: LobbyStorage.popularFile(in: folder)),
            progressStore: ProgressStore(fileURL: LobbyStorage.progressFile(in: folder)),
            credentials: keychain(account),
            preferences: ConnectionPreferences(suiteName: suite),
            settings: LocalSettings(suiteName: suite),
            artwork: ArtworkLoader(
                directory: (store.cachesDirectory(of: account) ?? folder).appending(path: "Artwork", directoryHint: .isDirectory),
                keptDirectory: folder.appending(path: "DownloadArtwork", directoryHint: .isDirectory),
                session: session),
            downloads: downloads,
            session: session,
            device: DeviceIdentity(name: "Test iPhone", platform: .ios),
            capabilities: DeviceCapabilities(hardwareAV1Decode: false),
            locateGrace: { try? await Task.sleep(for: .seconds(3600)) },
            sleep: { _ in
                try Task.checkCancellation()
                await Task.yield()
            })
        environment.music = MusicStorage(directory: folder.appending(path: "Music", directoryHint: .isDirectory))
        environment.updates.memory = UpdateMemoryStore(suiteName: suite)
        environment.hasKidsScreens = hasKidsScreens
        environment.confirmGrownUp = { [answer] in answer.value.withLock { $0 } }
        return environment
    }

    /// The app of a device that was paired with the home server before there were several.
    func launchPairedAtHome(as profileID: String? = "alex") async throws -> ServersModel {
        let state = home.current
        let first = try store.load()
        let account = try #require(first.active)
        await keychain(account).setToken("home-token", forServer: state.server.id)
        let preferences = ConnectionPreferences(suiteName: account.storage.defaultsSuite)
        preferences.connection = SavedConnection(
            serverAddress: home.stub.baseURL, serverID: state.server.id, serverName: state.server.name, deviceID: state.device.id)
        preferences.activeProfileID = profileID
        LocalSettings(suiteName: account.storage.defaultsSuite).profiles = state.profiles
        let servers = try ServersModel(making: making)
        await servers.active.start()
        await servers.start()
        return servers
    }

    /// Adds Grandma's server and pairs with it, as the Connect screen does once a manager approved.
    func addGrandma(to servers: ServersModel, as profileID: String = "anna") async throws {
        await servers.addServer()
        #expect(servers.active.phase == .launching)
        await servers.active.start()
        #expect(servers.active.phase == .connect)
        let state = grandma.current
        try await servers.active.completePairing(
            address: grandma.stub.baseURL, server: state.server, grant: DeviceGrant(device: state.device, token: "grandma-token"))
        let anna = try #require(servers.active.profiles.first { $0.id == profileID })
        await servers.active.selectProfile(anna)
    }

    /// Starts the model the switch made, as its screen does.
    func started(_ servers: ServersModel) async -> AppModel {
        await servers.active.start()
        return servers.active
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ServersTests {
    @Test func aDeviceFromBeforeKeepsItsServerAsTheFirstAccount() async throws {
        let test = try TwoServers()
        let servers = try await test.launchPairedAtHome()

        #expect(servers.accounts.map(\.id) == [ServerAccountsStore.firstID])
        #expect(servers.activeAccount?.displayName == "Family Pi")
        #expect(servers.activeAccount?.serverID == "server-1")
        #expect(servers.active.phase == .library)
        #expect(servers.active.catalogue.items.map(\.title) == ["Up"])
        #expect(!servers.hasSeveral)
    }

    @Test func twoServersArePairedOnOneDeviceEachWithItsOwnThings() async throws {
        let test = try TwoServers()
        let servers = try await test.launchPairedAtHome()
        let home = try #require(servers.activeAccount)
        await servers.active.markWatched(itemID: "up")

        try await test.addGrandma(to: servers)
        let grandma = try #require(servers.activeAccount)

        #expect(servers.accounts.map(\.displayName) == ["Family Pi", "Grandma's"])
        #expect(servers.hasSeveral)
        #expect(servers.addingFrom == nil)
        #expect(grandma.serverID == "server-2")
        // The library, the viewers and what was watched are Grandma's.
        #expect(servers.active.catalogue.items.map(\.title) == ["Heidi"])
        #expect(servers.active.profiles.map(\.name) == ["Anna"])
        #expect(servers.active.progress.isEmpty)
        // Each credential is in its own account's Keychain, and only there.
        #expect(await test.keychain(home).keys == ["server-1"])
        #expect(await test.keychain(grandma).keys == ["server-2"])
        // Nothing of one server was sent to the other.
        #expect(test.grandma.stub.recorded.allSatisfy { $0.headers["Authorization"] != "Bearer home-token" })
        #expect(test.home.stub.recorded.allSatisfy { $0.headers["Authorization"] != "Bearer grandma-token" })

        // Back home: home's library and viewer, as they were left.
        await servers.switchTo(home.id)
        let back = await test.started(servers)
        #expect(back.phase == .library)
        #expect(back.activeProfile?.id == "alex")
        #expect(back.catalogue.items.map(\.title) == ["Up"])
        #expect(back.progress["up"]?.completed == true)
        // A relaunch opens the server that was in use.
        let relaunched = try ServersModel(making: test.making)
        #expect(relaunched.activeID == home.id)
        #expect(relaunched.accounts.map(\.id) == [home.id, grandma.id])
    }

    @Test func theProgressQueueOfOneServerIsNeverSentToAnother() async throws {
        let test = try TwoServers()
        let servers = try await test.launchPairedAtHome()
        let home = try #require(servers.activeAccount)
        // Watched with the home server out of reach: queued on the device.
        test.home.change { $0.offline = true }
        await servers.active.markWatched(itemID: "up")
        #expect(await servers.active.environment.progressStore.pendingOperations().count == 1)

        try await test.addGrandma(to: servers)
        await servers.active.markWatched(itemID: "heidi")

        #expect(test.grandma.current.progress["anna"]?["heidi"]?.completed == true)
        #expect(test.grandma.current.progress["alex"] == nil)
        #expect(await servers.active.environment.progressStore.pendingOperations().isEmpty)

        // Home is back: its own queue goes to it, and only there.
        test.home.change { $0.offline = false }
        await servers.switchTo(home.id)
        let back = await test.started(servers)
        #expect(test.home.current.progress["alex"]?["up"]?.completed == true)
        #expect(test.home.current.progress["anna"] == nil)
        #expect(await back.environment.progressStore.pendingOperations().isEmpty)
    }

    @Test func switchingTakesTheServerInUseDownAndKeepsItsDownloadGoing() async throws {
        let test = try TwoServers()
        let servers = try await test.launchPairedAtHome()
        let home = try #require(servers.activeAccount)
        let leaving = servers.active
        await leaving.download(try #require(leaving.item("up")))

        try await test.addGrandma(to: servers)

        #expect(leaving.isSuspended)
        #expect(leaving.liveClient == nil)
        #expect(leaving.player == nil)
        // Home's download finishes in home's folder, though Grandma's server is in use.
        for _ in 0..<500 where servers.otherDownloads[home.id]?.first?.state != .verified {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(servers.otherDownloads[home.id]?.map(\.itemID) == ["up"])
        #expect(servers.otherDownloads[home.id]?.first?.state == .verified)
        #expect(servers.active.downloads.isEmpty)
        #expect(test.grandma.stub.recorded.allSatisfy { !$0.path.contains("up-file") })

        // On This Device shows it under home's name, and playing it goes home.
        #expect(servers.otherServersDownloads.map(\.account.displayName) == ["Family Pi"])
        #expect(servers.otherServersDownloads.first?.overview.films.map(\.title) == ["Up"])
        await servers.playDownload(itemID: "up", of: home.id)
        let back = await test.started(servers)
        #expect(servers.activeID == home.id)
        #expect(back.player?.request.item.id == "up")
        #expect(back.player?.request.source == .local)
        await back.player?.close()
    }

    @Test func removingAServerRemovesItsCredentialAndDownloadsAndNothingElse() async throws {
        let test = try TwoServers()
        let servers = try await test.launchPairedAtHome()
        let home = try #require(servers.activeAccount)
        await servers.active.download(try #require(servers.active.item("up")))
        try await test.addGrandma(to: servers)
        let grandma = try #require(servers.activeAccount)
        await servers.active.download(try #require(servers.active.item("heidi")))
        for _ in 0..<500 where await servers.active.environment.downloads.record(itemID: "heidi")?.state != .verified {
            try await Task.sleep(for: .milliseconds(10))
        }
        let homeFolder = try test.store.directory(of: home)
        let grandmaFolder = try test.store.directory(of: grandma)

        await servers.remove(home.id)

        #expect(servers.problem == nil)
        #if os(iOS) || os(macOS)
        // Home stops pushing to this device; Grandma's still does.
        #expect(test.home.stub.requests("DELETE", "/v1/me/push").count == 1)
        #expect(test.grandma.stub.requests("DELETE", "/v1/me/push").isEmpty)
        #endif
        #expect(servers.accounts.map(\.id) == [grandma.id])
        #expect(servers.activeID == grandma.id)
        #expect(await test.keychain(home).keys.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: homeFolder.path))
        #expect(ConnectionPreferences(suiteName: home.storage.defaultsSuite).connection == nil)
        // Grandma's is as it was: its credential, its library, its download.
        #expect(await test.keychain(grandma).keys == ["server-2"])
        #expect(FileManager.default.fileExists(atPath: LobbyStorage.catalogueFile(in: grandmaFolder).path))
        #expect(await servers.active.environment.downloads.record(itemID: "heidi")?.state == .verified)
        #expect(ConnectionPreferences(suiteName: grandma.storage.defaultsSuite).connection?.serverID == "server-2")
        #expect(servers.active.catalogue.items.map(\.title) == ["Heidi"])
    }

    /// The manager's, settings' and uploads' models hold the app model of their server: once
    /// another server is in use, the old one and all it holds go.
    @Test func switchingServersLetsTheOldAppModelGo() async throws {
        let test = try TwoServers()
        let servers = try await test.launchPairedAtHome()
        weak var leaving = servers.active
        _ = servers.active.manager()
        _ = servers.active.serverSettings()
        _ = servers.active.uploads()

        try await test.addGrandma(to: servers)

        #expect(servers.active.catalogue.items.map(\.title) == ["Heidi"])
        #expect(leaving == nil)
    }

    @Test func removingTheLastServerLeavesAnEmptyOne() async throws {
        let test = try TwoServers()
        let servers = try await test.launchPairedAtHome()
        let home = try #require(servers.activeAccount)

        await servers.remove(home.id)

        #expect(servers.accounts.count == 1)
        #expect(servers.activeAccount?.isPaired == false)
        #expect(await test.started(servers).phase == .connect)
        #expect(await test.keychain(home).keys.isEmpty)
    }

    @Test func eachServerKeepsItsOwnNotices() async throws {
        let test = try TwoServers()
        let servers = try await test.launchPairedAtHome()
        let home = try #require(servers.activeAccount)
        servers.active.updates.told(.appBehind(app: "0.1.0", needs: "9.0.0"))
        servers.active.environment.settings.downloadsUseMobileData = true

        try await test.addGrandma(to: servers)
        let grandma = try #require(servers.activeAccount)

        #expect(UpdateMemoryStore(suiteName: home.storage.defaultsSuite).read().toldMismatch != nil)
        #expect(UpdateMemoryStore(suiteName: grandma.storage.defaultsSuite).read().toldMismatch == nil)
        #expect(!servers.active.downloadsUseMobileData)
    }

    // MARK: Adding

    @Test func addingCanBeCancelledAndLeavesNothing() async throws {
        let test = try TwoServers()
        let servers = try await test.launchPairedAtHome()
        let home = try #require(servers.activeAccount)

        await servers.addServer()
        let added = try #require(servers.activeAccount)
        #expect(servers.isAdding)
        #expect(added.id != home.id)
        await servers.cancelAdding()

        #expect(servers.accounts.map(\.id) == [home.id])
        #expect(servers.activeID == home.id)
        #expect(!FileManager.default.fileExists(atPath: test.directory.url.appending(path: added.storage.folder).path))
        #expect(await test.started(servers).catalogue.items.map(\.title) == ["Up"])
    }

    @Test func theSameServerCannotBeAddedTwice() async throws {
        let test = try TwoServers()
        let servers = try await test.launchPairedAtHome()
        await servers.addServer()
        await servers.active.start()
        let state = test.home.current

        await #expect(throws: ServerAlreadyAdded.self) {
            try await servers.active.completePairing(
                address: test.home.stub.baseURL, server: state.server, grant: DeviceGrant(device: state.device, token: "again"))
        }
        #expect(servers.activeAccount?.isPaired == false)
        #expect(servers.active.account.otherAccountName("server-1") == "Family Pi")
    }

    @Test func anInvitationLinkAddsAServerWithItsCodeFilledIn() async throws {
        let test = try TwoServers()
        let servers = try await test.launchPairedAtHome()
        let link = try #require(URL(string: "lobby://join?c=ABCD-EFGH-JKMN-PQRS&i=introducer.example.com"))

        await servers.addServer(invitation: link)

        #expect(servers.isAdding)
        #expect(servers.active.invitation == link.absoluteString)
        await servers.active.start()
        let connect = ConnectModel(app: servers.active)
        await connect.resumeOutside()
        #expect(connect.step == .outside)
        #expect(connect.outsideCode == "ABCDEFGHJKMNPQRS")
        #expect(connect.introducerText == "introducer.example.com")
    }

    @Test func aDeviceThatIsNotPairedTakesAnInvitationItself() async throws {
        let test = try TwoServers()
        let servers = try ServersModel(making: test.making)
        await servers.active.start()
        servers.open(try #require(URL(string: "lobby://join?c=ABCDEFGHJKMNPQRS")))
        #expect(servers.accounts.count == 1)
        #expect(servers.active.invitation == "lobby://join?c=ABCDEFGHJKMNPQRS")
    }

    // MARK: Kids

    private static func kidsHome(bound: Bool) -> Household {
        Household(.init(
            device: Device(
                id: "dev-1", name: "Phone", platform: .ios, role: .viewer, createdAt: Make.epoch,
                kidsProfileId: bound ? "kid" : nil, saysKidsProfile: true),
            profiles: [
                Profile(id: "alex", name: "Alex", color: "blue", saysKids: true),
                Profile(id: "kid", name: "Kid", color: "green", kids: KidsSettings(allowedGroupIds: ["main"]), saysKids: true),
            ],
            knowsKids: true,
            items: [Make.movie("up", title: "Up")],
            token: "home-token"))
    }

    @Test func inKidsModeOnlyAGrownUpSwitchesServers() async throws {
        let test = try TwoServers(home: Self.kidsHome(bound: false))
        let servers = try await test.launchPairedAtHome(as: "alex")
        let home = try #require(servers.activeAccount)
        try await test.addGrandma(to: servers)
        let grandma = try #require(servers.activeAccount)
        await servers.switchTo(home.id)
        await test.started(servers).selectProfile(try #require(servers.active.profiles.first { $0.id == "kid" }))
        #expect(servers.active.isKidsMode)

        test.grownUp = .refused
        await servers.switchTo(grandma.id)
        #expect(servers.activeID == home.id)
        #expect(servers.problem == nil)

        test.grownUp = .unavailable
        await servers.switchTo(grandma.id)
        #expect(servers.activeID == home.id)
        #expect(servers.problem?.contains("passcode") == true)

        test.grownUp = .confirmed
        await servers.switchTo(grandma.id)
        #expect(servers.activeID == grandma.id)
    }

    @Test func aGrownUpWhoLeftTheKidsScreensIsNotAskedAgain() async throws {
        let test = try TwoServers(home: Self.kidsHome(bound: false))
        let servers = try await test.launchPairedAtHome(as: "kid")
        let home = try #require(servers.activeAccount)
        try await test.addGrandma(to: servers)
        let grandma = try #require(servers.activeAccount)
        await servers.switchTo(home.id)
        let kids = await test.started(servers)
        #expect(kids.showsKidsScreens)

        await kids.askToLeaveKidsMode()
        #expect(kids.phase == .chooseProfile)
        test.grownUp = .refused
        await servers.switchTo(grandma.id)
        #expect(servers.activeID == grandma.id)
    }

    @Test func aDeviceBoundToAKidsViewerStaysOnItsServer() async throws {
        let test = try TwoServers(home: Self.kidsHome(bound: true))
        let servers = try await test.launchPairedAtHome(as: "kid")
        let home = try #require(servers.activeAccount)
        #expect(servers.active.isBoundToKids)
        #expect(!servers.canChangeServers)

        await servers.addServer()
        #expect(servers.accounts.map(\.id) == [home.id])
        #expect(servers.problem?.contains("kids viewer") == true)
        servers.problem = nil

        await servers.remove(home.id)
        #expect(servers.accounts.map(\.id) == [home.id])
        #expect(await test.keychain(home).keys == ["server-1"])
        #expect(servers.problem?.contains("kids viewer") == true)
    }

    // MARK: Which library?

    @Test func withTwoServersTheStartAsksWhichLibraryTheLastUsedFirst() async throws {
        let test = try TwoServers()
        let servers = try await test.launchPairedAtHome()
        let home = try #require(servers.activeAccount)
        // One server: the start is as before.
        #expect(!servers.showsLibraryChoice)
        try await test.addGrandma(to: servers)
        let grandma = try #require(servers.activeAccount)
        await servers.active.download(try #require(servers.active.item("heidi")))
        for _ in 0..<500 where await servers.active.environment.downloads.record(itemID: "heidi")?.state != .verified {
            try await Task.sleep(for: .milliseconds(10))
        }
        test.grandma.change { $0.offline = true }

        let relaunched = try ServersModel(making: test.making)
        #expect(relaunched.showsLibraryChoice)
        #expect(relaunched.libraries.map(\.id) == [grandma.id, home.id])
        #expect(relaunched.preselectedLibrary == grandma.id)
        await relaunched.checkReachability()
        #expect(relaunched.reachability[home.id] == .reachable)
        #expect(relaunched.reachability[grandma.id] == .offline)
        #expect(relaunched.downloadCounts[grandma.id] == 1)
        #expect(relaunched.reachability[grandma.id].text(downloads: 1) == "Offline · 1 download on this device")

        // Then that library's viewers, and only its own.
        await relaunched.chooseLibrary(home.id)
        #expect(!relaunched.showsLibraryChoice)
        #expect(relaunched.activeID == home.id)
        let app = await test.started(relaunched)
        #expect(app.phase == .chooseProfile)
        #expect(app.profiles.map(\.name) == ["Alex", "Kids"])
        #expect(relaunched.libraries.first?.id == home.id)
    }

    @Test func aRememberedChoiceOpensTheLastLibraryWithoutAsking() async throws {
        let test = try TwoServers()
        let servers = try await test.launchPairedAtHome()
        let home = try #require(servers.activeAccount)
        try await test.addGrandma(to: servers)

        let first = try ServersModel(making: test.making)
        await first.chooseLibrary(home.id, remember: true)
        let second = try ServersModel(making: test.making)
        #expect(!second.showsLibraryChoice)
        #expect(second.activeID == home.id)
        // Its viewer as it was left: no step at all.
        #expect(await test.started(second).phase == .library)

        second.setRemembersLibrary(false)
        #expect(try ServersModel(making: test.making).showsLibraryChoice)
    }

    @Test func switchingFromTheViewerMenuGoesBackToWhichLibrary() async throws {
        let test = try TwoServers()
        let servers = try await test.launchPairedAtHome()
        let home = try #require(servers.activeAccount)
        try await test.addGrandma(to: servers)
        #expect(servers.active.phase == .library)

        await servers.showLibraryChoice()
        #expect(servers.showsLibraryChoice)
        servers.closeLibraryChoice()
        #expect(!servers.showsLibraryChoice)
        #expect(servers.active.phase == .library)

        await servers.showLibraryChoice()
        await servers.chooseLibrary(home.id)
        let app = await test.started(servers)
        #expect(app.phase == .chooseProfile)
        #expect(!app.profiles.contains { $0.id == "anna" })

        // The same library again: its viewers, nothing else changes.
        await app.selectProfile(try #require(app.profiles.first { $0.id == "alex" }))
        await servers.showLibraryChoice()
        await servers.chooseLibrary(home.id)
        #expect(servers.active === app)
        #expect(app.phase == .chooseProfile)
    }

    @Test func aChildAtTheStartDoesNotLeaveByAnotherLibrary() async throws {
        let test = try TwoServers(home: Self.kidsHome(bound: false))
        let servers = try await test.launchPairedAtHome(as: "alex")
        let home = try #require(servers.activeAccount)
        try await test.addGrandma(to: servers)
        let grandma = try #require(servers.activeAccount)
        await servers.switchTo(home.id)
        await test.started(servers).selectProfile(try #require(servers.active.profiles.first { $0.id == "kid" }))

        let relaunched = try ServersModel(making: test.making)
        #expect(relaunched.showsLibraryChoice)
        test.grownUp = .refused
        await relaunched.chooseLibrary(grandma.id)
        #expect(relaunched.activeID == home.id)
        #expect(relaunched.showsLibraryChoice)
        // Its own library is the child's: no grown-up needed, and kids mode stays.
        await relaunched.chooseLibrary(home.id)
        #expect(!relaunched.showsLibraryChoice)
        #expect(await test.started(relaunched).showsKidsScreens)
    }

    @Test func aDeviceBoundToAKidsViewerHasNoLibraryStep() async throws {
        let test = try TwoServers(home: Self.kidsHome(bound: false))
        let servers = try await test.launchPairedAtHome(as: "alex")
        let home = try #require(servers.activeAccount)
        try await test.addGrandma(to: servers)
        await servers.switchTo(home.id)
        let app = await test.started(servers)
        test.home.change { $0.device.kidsProfileId = "kid" }
        await app.refresh()
        #expect(app.isBoundToKids)

        await servers.showLibraryChoice()
        #expect(!servers.showsLibraryChoice)
        let relaunched = try ServersModel(making: test.making)
        #expect(!relaunched.showsLibraryChoice)
        #expect(relaunched.activeID == home.id)
    }

    // MARK: The list

    @Test func serversAreRenamedRestyledAndReorderedOnThisDeviceOnly() async throws {
        let test = try TwoServers()
        let servers = try await test.launchPairedAtHome()
        try await test.addGrandma(to: servers)
        let grandma = try #require(servers.activeAccount)

        servers.rename(grandma.id, to: "Oma")
        servers.setLook(grandma.id, symbol: "tree.fill", color: "green")
        servers.move(grandma.id, by: -1)

        #expect(servers.accounts.map(\.displayName) == ["Oma", "Family Pi"])
        // The server's own name stays, and comes back when the name is emptied.
        #expect(servers.account(grandma.id)?.serverName == "Grandma's")
        let relaunched = try ServersModel(making: test.making)
        #expect(relaunched.accounts.map(\.displayName) == ["Oma", "Family Pi"])
        #expect(relaunched.account(grandma.id)?.symbol == "tree.fill")
        servers.rename(grandma.id, to: "  ")
        #expect(servers.account(grandma.id)?.displayName == "Grandma's")
    }
}
