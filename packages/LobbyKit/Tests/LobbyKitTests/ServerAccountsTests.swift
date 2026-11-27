// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyDirect
import Testing

@testable import LobbyKit

/// Several servers in one app: where each one's things are, and how a device from
/// the one-server time becomes the first of them without losing anything.
@Suite struct ServerAccountsTests {
    let directory: TemporaryDirectory
    let caches: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
        caches = try TemporaryDirectory()
    }

    private func store(legacySuite: String? = nil) -> ServerAccountsStore {
        ServerAccountsStore(root: directory.url, caches: caches.url, base: "mt.sil.lobby.tests", legacySuite: legacySuite)
    }

    private static let film = Item(
        id: "film", kind: .movie, title: "Up", year: 2009, addedAt: Make.epoch,
        files: [MediaFile(
            assetId: "a1", sizeBytes: 1_048_576, durationMs: 60_000, container: "mp4", revision: "r1",
            playability: .direct, video: VideoTrack(codec: "h264", width: 1920, height: 1080, bitDepth: 8))])

    /// The layout a one-server device has on disk, written by the real stores.
    private func writeOneServerLayout() async throws {
        let root = directory.url
        let progress = ProgressStore(fileURL: LobbyStorage.progressFile(in: root))
        try await progress.record(profileID: "alex", itemID: "film", positionMs: 42_000, durationMs: 60_000, completed: false)
        try Data(#"{"version":1}"#.utf8).write(to: LobbyStorage.catalogueFile(in: root))
        try Data("categories".utf8).write(to: LobbyStorage.categoriesFile(in: root))
        try Data("popular".utf8).write(to: LobbyStorage.popularFile(in: root))

        let downloads = DownloadManager(
            directory: LobbyStorage.downloadsDirectory(in: root), sessionConfiguration: .ephemeral,
            sleep: { _ in try Task.checkCancellation() })
        await downloads.start(using: nil)
        await downloads.enqueue(Self.film, file: Self.film.files[0], allowsCellular: false)
        let kept = root.appending(path: "DownloadArtwork/poster.jpg")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("poster".utf8).write(to: kept)
        let music = root.appending(path: "Music/music-library.json")
        try FileManager.default.createDirectory(at: music.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("music".utf8).write(to: music)
        let cached = caches.url.appending(path: "Artwork/a.jpg")
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cached".utf8).write(to: cached)
    }

    @Test func theOneServerLayoutBecomesTheFirstAccountWithNothingLost() async throws {
        try await writeOneServerLayout()

        let accounts = try store(legacySuite: "mt.sil.lobby.tests").load(legacyServerName: "Family Pi", legacyServerID: "server-1")

        #expect(accounts.accounts.count == 1)
        let first = try #require(accounts.active)
        #expect(first.id == ServerAccountsStore.firstID)
        #expect(first.serverName == "Family Pi")
        #expect(first.serverID == "server-1")
        // Its preferences, Keychain items and background session stay where they were.
        #expect(first.storage.defaultsSuite == "mt.sil.lobby.tests")
        #expect(first.storage.keychainService == "mt.sil.lobby.tests")
        #expect(first.storage.downloadsSession == "mt.sil.lobby.tests.downloads")
        #expect(!first.storage.movesLegacyFiles)

        // Every file moved, and the real stores read them at the new place.
        let folder = try store().directory(of: first)
        for name in ServerAccountsStore.legacyFiles {
            #expect(!FileManager.default.fileExists(atPath: directory.url.appending(path: name).path), "\(name) stayed behind")
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: name).path), "\(name) did not arrive")
        }
        let progress = ProgressStore(fileURL: LobbyStorage.progressFile(in: folder))
        #expect(await progress.progress(profileID: "alex", itemID: "film")?.positionMs == 42_000)
        #expect(await progress.pendingOperations().count == 1)
        let downloads = DownloadManager(
            directory: LobbyStorage.downloadsDirectory(in: folder), sessionConfiguration: .ephemeral,
            sleep: { _ in try Task.checkCancellation() })
        #expect(await downloads.all().map(\.itemID) == ["film"])
        #expect(try Data(contentsOf: folder.appending(path: "DownloadArtwork/poster.jpg")) == Data("poster".utf8))
        #expect(try Data(contentsOf: folder.appending(path: "Music/music-library.json")) == Data("music".utf8))
        let cache = try #require(store().cachesDirectory(of: first))
        #expect(try Data(contentsOf: cache.appending(path: "Artwork/a.jpg")) == Data("cached".utf8))
        #expect(!FileManager.default.fileExists(atPath: caches.url.appending(path: "Artwork").path))
    }

    @Test func aMigrationThatStoppedHalfwayGoesOnWhereItWas() async throws {
        try await writeOneServerLayout()
        // The list was written, the catalogue moved, and then the app stopped.
        let store = store()
        var first = ServerAccount(
            id: ServerAccountsStore.firstID, addedAt: Make.epoch,
            storage: .init(folder: "Servers/first", defaultsSuite: nil, keychainService: "mt.sil.lobby.tests",
                           downloadsSession: "mt.sil.lobby.tests.downloads", movesLegacyFiles: true))
        first.serverName = "Family Pi"
        try store.save(ServerAccounts(accounts: [first], activeID: first.id))
        let folder = try store.directory(of: first)
        try FileManager.default.moveItem(at: LobbyStorage.catalogueFile(in: directory.url), to: LobbyStorage.catalogueFile(in: folder))

        let accounts = try store.load()

        #expect(accounts.accounts.map(\.id) == [ServerAccountsStore.firstID])
        #expect(accounts.active?.storage.movesLegacyFiles == false)
        for name in ServerAccountsStore.legacyFiles {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: name).path), "\(name) did not arrive")
        }
        // Read again, the list is as it was left.
        #expect(try store.load() == accounts)
    }

    @Test func aFreshDeviceStartsWithOneEmptyAccount() throws {
        let accounts = try store().load()
        #expect(accounts.accounts.count == 1)
        #expect(accounts.active?.isPaired == false)
        #expect(accounts.active?.displayName == "New Server")
    }

    @Test func everyAddedAccountHasPlacesOfItsOwn() throws {
        let store = store()
        var accounts = try store.load()
        let second = store.newAccount(besides: accounts.accounts)
        accounts.accounts.append(second)
        try store.save(accounts)

        let first = accounts.accounts[0]
        #expect(second.id != first.id)
        #expect(second.storage.folder != first.storage.folder)
        #expect(second.storage.defaultsSuite != first.storage.defaultsSuite)
        #expect(second.storage.keychainService != first.storage.keychainService)
        #expect(second.storage.downloadsSession != first.storage.downloadsSession)
        // Told apart in the switcher at a glance.
        #expect(second.color != first.color)
        #expect(second.symbol != first.symbol)
        #expect(try store.load().accounts.map(\.id) == [first.id, second.id])
    }

    @Test func removingAnAccountDeletesItsFilesAndNoOthers() throws {
        let store = store()
        var accounts = try store.load()
        let second = store.newAccount(besides: accounts.accounts)
        accounts.accounts.append(second)
        let firstFolder = try store.directory(of: accounts.accounts[0])
        let secondFolder = try store.directory(of: second)
        try Data("one".utf8).write(to: LobbyStorage.catalogueFile(in: firstFolder))
        try Data("two".utf8).write(to: LobbyStorage.catalogueFile(in: secondFolder))
        let secondCache = try #require(store.cachesDirectory(of: second))
        try FileManager.default.createDirectory(at: secondCache, withIntermediateDirectories: true)

        try store.removeFiles(of: second)

        #expect(!FileManager.default.fileExists(atPath: secondFolder.path))
        #expect(!FileManager.default.fileExists(atPath: secondCache.path))
        #expect(try Data(contentsOf: LobbyStorage.catalogueFile(in: firstFolder)) == Data("one".utf8))
    }

    @Test func removingAnAccountForgetsItsPreferencesOnly() throws {
        let store = store(legacySuite: "mt.sil.lobby.tests.legacy.\(UUID().uuidString)")
        var accounts = try store.load()
        let second = store.newAccount(besides: accounts.accounts)
        accounts.accounts.append(second)
        let firstPreferences = ConnectionPreferences(suiteName: accounts.accounts[0].storage.defaultsSuite)
        let secondPreferences = ConnectionPreferences(suiteName: second.storage.defaultsSuite)
        firstPreferences.activeProfileID = "alex"
        secondPreferences.activeProfileID = "anna"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: accounts.accounts[0].storage.defaultsSuite!)
            UserDefaults.standard.removePersistentDomain(forName: second.storage.defaultsSuite!)
        }

        store.removeDefaults(of: second)
        // The first account's suite is the one of the one-server time: never removed whole.
        store.removeDefaults(of: accounts.accounts[0])

        #expect(ConnectionPreferences(suiteName: second.storage.defaultsSuite).activeProfileID == nil)
        #expect(firstPreferences.activeProfileID == "alex")
    }

    @Test func anUnreadableListIsRebuiltFromTheFolders() throws {
        let store = store()
        var accounts = try store.load()
        let second = store.newAccount(besides: accounts.accounts)
        accounts.accounts.append(second)
        try store.save(accounts)
        _ = try store.directory(of: accounts.accounts[0])
        _ = try store.directory(of: second)
        try Data("{ not json".utf8).write(to: store.fileURL)

        let rebuilt = try store.load()

        #expect(Set(rebuilt.accounts.map(\.id)) == [ServerAccountsStore.firstID, second.id])
        #expect(rebuilt.account(second.id)?.storage == second.storage)
        #expect(rebuilt.account(ServerAccountsStore.firstID)?.storage.keychainService == "mt.sil.lobby.tests")
    }

    @Test func aRenamedAccountSaysItsOwnName() {
        var account = ServerAccount(
            id: "x", serverName: "Family Pi", addedAt: Make.epoch,
            storage: .init(folder: "Servers/x", defaultsSuite: nil, keychainService: "s", downloadsSession: "d"))
        #expect(account.displayName == "Family Pi")
        account.localName = "Grandma's"
        #expect(account.displayName == "Grandma's")
        account.localName = "  "
        #expect(account.displayName == "Family Pi")
    }

    @Test func theLibraryUsedLastComesFirstAndTheChoiceIsRemembered() throws {
        let store = store()
        var accounts = try store.load()
        accounts.accounts[0].serverID = "server-1"
        var second = store.newAccount(besides: accounts.accounts)
        second.serverID = "server-2"
        var unpaired = store.newAccount(besides: accounts.accounts + [second])
        unpaired.lastUsedAt = Make.epoch.addingTimeInterval(500)
        accounts.accounts += [second, unpaired]
        // Never used: in the person's order.
        #expect(accounts.byLastUse.map(\.id) == [ServerAccountsStore.firstID, second.id])
        accounts.accounts[1].lastUsedAt = Make.epoch.addingTimeInterval(60)
        accounts.accounts[0].lastUsedAt = Make.epoch
        #expect(accounts.byLastUse.map(\.id) == [second.id, ServerAccountsStore.firstID])

        accounts.remembersLibrary = true
        try store.save(accounts)
        let read = try store.load()
        #expect(read.remembersLibrary == true)
        #expect(read.account(second.id)?.lastUsedAt == Make.epoch.addingTimeInterval(60))
        // A list from before the question has none of it.
        try Data(#"{"version":1,"accounts":[],"activeID":"x"}"#.utf8).write(to: store.fileURL)
        #expect(try store.load().remembersLibrary == nil)
    }

    // MARK: Invitations

    @Test func aHouseholdInvitationFillsInPairingFromOutside() throws {
        let full = try #require(HouseholdInvitation(link: "lobby://join?c=abcd-efgh-jkmn-pqrs&i=introducer.example.com"))
        #expect(full.code == "ABCDEFGHJKMNPQRS")
        #expect(full.pairing?.introducer.display == "introducer.example.com")
        #expect(full.pairing?.code == "ABCDEFGHJKMNPQRS")

        let codeOnly = try #require(HouseholdInvitation(link: "lobby://join?code=ABCDEFGHJKMNPQRS"))
        #expect(codeOnly.introducer == nil)
        #expect(codeOnly.pairing == nil)

        #expect(HouseholdInvitation(link: "lobby://join") == nil)
        #expect(HouseholdInvitation(link: "https://join?c=ABCD") == nil)
        #expect(HouseholdInvitation(link: "lobby://pair?c=ABCDEFGHJKMNPQRS&i=introducer.example.com") == nil)
        #expect(HouseholdInvitation.isPairingLink("lobby://pair?c=ABCDEFGHJKMNPQRS&i=introducer.example.com"))
        #expect(HouseholdInvitation.isPairingLink("lobby://join?c=ABCD"))
        #expect(!HouseholdInvitation.isPairingLink("lobby://elsewhere"))
    }

    // MARK: The Keychain

    #if os(macOS)
    /// Each account's credential is under a service of its own: removing one leaves the other.
    @Test func eachAccountsKeychainItemsAreItsOwn() async throws {
        let one = KeychainCredentialStore(service: "mt.sil.lobby.tests.\(UUID().uuidString)", usesDataProtectionKeychain: false)
        let two = KeychainCredentialStore(service: "mt.sil.lobby.tests.\(UUID().uuidString)", usesDataProtectionKeychain: false)
        try await one.setToken("token-one", forServer: "server-1")
        try await one.setToken("identity-one", forServer: "direct:server-1")
        try await two.setToken("token-two", forServer: "server-2")

        try one.removeAll()

        #expect(try await one.token(forServer: "server-1") == nil)
        #expect(try await one.token(forServer: "direct:server-1") == nil)
        #expect(try await two.token(forServer: "server-2") == "token-two")
        try two.removeAll()
        try one.removeAll()
    }
    #endif
}
