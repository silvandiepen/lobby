// SPDX-License-Identifier: MPL-2.0
import Foundation
import Synchronization
import Testing

@testable import LobbyKit

@Suite struct ProgressStoreTests {
    let directory: TemporaryDirectory
    let clock = TestClock()
    let ids = OperationIDs()

    init() throws {
        directory = try TemporaryDirectory()
    }

    /// A store over this test's file. Calling it again is a relaunch of the app.
    func makeStore() -> ProgressStore {
        let clock = clock
        let ids = ids
        return ProgressStore(fileURL: directory.file("progress.json"), now: { clock.now }, makeOperationID: { ids.next() })
    }

    /// Accepts every update with the next revision, echoing what was sent.
    static func acceptingServer(firstRevision: Int = 100) -> StubServer {
        let revision = Mutex(firstRevision - 1)
        return StubServer { request in
            guard request.method == "PUT" else { return .json(200, #"{ "progress": [], "revision": 0 }"#) }
            let body = try request.json()
            let itemID = request.path.split(separator: "/").last.map(String.init) ?? ""
            let next = revision.withLock { $0 += 1; return $0 }
            let duration = (body["durationMs"] as? Int).map(String.init) ?? "null"
            return .json(200, #"{ "progress": { "itemId": "\#(itemID)", "positionMs": \#(body["positionMs"] as? Int ?? -1), "durationMs": \#(duration), "completed": \#(body["completed"] as? Bool ?? false), "revision": \#(next), "updatedAt": \#(body["updatedAt"] as? Int ?? -1) } }"#)
        }
    }

    @Test func aChangeMadeOfflineIsVisibleAtOnceAndSurvivesARelaunch() async throws {
        let store = makeStore()
        let recorded = try await store.record(profileID: "yeva", itemID: "up", positionMs: 90_000, durationMs: 5_000_000, completed: false)

        #expect(recorded == PlaybackProgress(itemId: "up", positionMs: 90_000, durationMs: 5_000_000, completed: false, revision: 0, updatedAt: clock.now))
        #expect(await store.progress(profileID: "yeva") == ["up": recorded])
        #expect(await store.progress(profileID: "alex").isEmpty)

        let relaunched = makeStore()
        #expect(await relaunched.progress(profileID: "yeva", itemID: "up") == recorded)
        let pending = await relaunched.pendingOperations()
        #expect(pending.count == 1)
        #expect(pending[0].opId == "op-1")
        #expect(pending[0].baseRevision == nil)
        #expect(!pending[0].attempted)
    }

    @Test func unsentChangesToTheSameItemCollapseIntoTheLatestWithAFreshOperationId() async throws {
        let store = makeStore()
        for position in [10_000, 20_000, 30_000] {
            clock.advance(by: 10)
            try await store.record(profileID: "yeva", itemID: "up", positionMs: position, durationMs: nil, completed: false)
        }
        try await store.record(profileID: "yeva", itemID: "jungle", positionMs: 5_000, durationMs: nil, completed: false)
        try await store.record(profileID: "alex", itemID: "up", positionMs: 7_000, durationMs: nil, completed: false)

        let pending = await store.pendingOperations()
        #expect(pending.map(\.opId) == ["op-3", "op-4", "op-5"])
        #expect(pending[0].positionMs == 30_000)
        #expect(pending[0].updatedAt == clock.now)
        #expect(await store.progress(profileID: "alex", itemID: "up")?.positionMs == 7_000)
    }

    @Test func flushingSendsEachChangeAndTakesTheServersAnswer() async throws {
        let stub = Self.acceptingServer(firstRevision: 100)
        let store = makeStore()
        try await store.record(profileID: "yeva", itemID: "up", positionMs: 90_000, durationMs: 5_000_000, completed: false)
        try await store.record(profileID: "yeva", itemID: "jungle", positionMs: 0, durationMs: nil, completed: true)

        let result = try await store.flush(using: stub.client())

        #expect(result.accepted == 2)
        #expect(result.remaining == 0)
        #expect(result.stoppedBy == nil)
        #expect(await store.pendingOperations().isEmpty)

        let first = try #require(stub.recorded.first)
        #expect(first.method == "PUT")
        #expect(first.path == "/v1/profiles/yeva/progress/up")
        let body = try first.json()
        #expect(body["opId"] as? String == "op-1")
        #expect(body["baseRevision"] is NSNull)
        #expect(body["positionMs"] as? Int == 90_000)
        #expect(body["updatedAt"] as? Int64 == clock.now.millisecondsSince1970)

        #expect(await store.progress(profileID: "yeva", itemID: "up")?.revision == 100)
        #expect(await store.progress(profileID: "yeva", itemID: "jungle")?.completed == true)
        // Known to the next launch too, with nothing left to send.
        let relaunched = makeStore()
        #expect(await relaunched.progress(profileID: "yeva", itemID: "jungle")?.revision == 101)
        #expect(await relaunched.pendingOperations().isEmpty)

        // The next change to the item is based on the revision the server gave.
        try await store.record(profileID: "yeva", itemID: "up", positionMs: 120_000, durationMs: 5_000_000, completed: false)
        #expect(await store.pendingOperations().first?.baseRevision == 100)
    }

    @Test func anUnreachableServerKeepsTheQueueAndTheRetryReusesTheOperationId() async throws {
        let stub = Self.acceptingServer()
        stub.goOffline()
        let store = makeStore()
        try await store.record(profileID: "yeva", itemID: "up", positionMs: 90_000, durationMs: nil, completed: false)

        let offline = try await store.flush(using: stub.client())
        #expect(offline.accepted == 0)
        #expect(offline.remaining == 1)
        #expect(offline.stoppedBy == .unreachable(.cannotConnectToHost))
        let firstAttempt = try #require(stub.recorded.last)

        // Still watching while offline: the change that may have reached the server stays as it
        // is, and the newer position queues behind it.
        clock.advance(by: 60)
        try await store.record(profileID: "yeva", itemID: "up", positionMs: 150_000, durationMs: nil, completed: false)
        clock.advance(by: 60)
        try await store.record(profileID: "yeva", itemID: "up", positionMs: 210_000, durationMs: nil, completed: false)
        #expect(await store.pendingOperations().map(\.opId) == ["op-1", "op-3"])
        #expect(await store.pendingOperations().map(\.attempted) == [true, false])
        #expect(await store.progress(profileID: "yeva", itemID: "up")?.positionMs == 210_000)

        // The app is quit and opened again before the Pi is back.
        let relaunched = makeStore()
        let stillOffline = try await relaunched.flush(using: stub.client())
        #expect(stillOffline.stoppedBy?.isUnreachable == true)
        #expect(stub.recorded.last?.body == firstAttempt.body)

        let online = Self.acceptingServer(firstRevision: 7)
        let result = try await relaunched.flush(using: online.client())
        #expect(result.accepted == 2)
        #expect(result.remaining == 0)
        #expect(online.recorded[0].body == firstAttempt.body)
        #expect(try online.recorded[1].json()["opId"] as? String == "op-3")
        #expect(await relaunched.progress(profileID: "yeva", itemID: "up")?.positionMs == 210_000)
        #expect(await relaunched.progress(profileID: "yeva", itemID: "up")?.revision == 8)
    }

    @Test func aConflictTakesTheServersProgress() async throws {
        // Yesterday on the Mac: marked unwatched. The iPad comes back with a position from last week.
        let server = Fixtures.progress(itemId: "up", positionMs: 0, revision: 4900, updatedAt: clock.now.millisecondsSince1970 + 86_400_000)
        let stub = StubServer { _ in .error(409, "conflict", "A newer change exists.", extra: #", "progress": \#(server)"#) }
        let store = makeStore()
        try await store.record(profileID: "yeva", itemID: "up", positionMs: 3_000_000, durationMs: 3_480_000, completed: false)

        let result = try await store.flush(using: stub.client())

        #expect(result.conflicts == 1)
        #expect(result.accepted == 0)
        #expect(result.remaining == 0)
        #expect(result.stoppedBy == nil)
        let progress = try #require(await makeStore().progress(profileID: "yeva", itemID: "up"))
        #expect(progress.positionMs == 0)
        #expect(progress.revision == 4900)
        #expect(!progress.completed)
    }

    @Test func aRevokedDeviceStopsTheFlushAndKeepsTheChangesForAfterPairingAgain() async throws {
        let stub = StubServer { _ in .error(401, "device_revoked", "This device was removed.") }
        let store = makeStore()
        try await store.record(profileID: "yeva", itemID: "up", positionMs: 1, durationMs: nil, completed: false)
        try await store.record(profileID: "yeva", itemID: "jungle", positionMs: 2, durationMs: nil, completed: false)

        let result = try await store.flush(using: stub.client())

        #expect(result.stoppedBy == .deviceRevoked(message: "This device was removed."))
        #expect(result.remaining == 2)
        #expect(stub.recorded.count == 1)

        let paired = Self.acceptingServer()
        #expect(try await store.flush(using: paired.client()).accepted == 2)
        #expect(try paired.recorded[0].json()["opId"] as? String == "op-1")
    }

    @Test func aChangeTheServerWillNeverTakeIsDroppedAndTheRestGoesOn() async throws {
        let stub = StubServer { request in
            request.path.hasSuffix("/deleted-film")
                ? .error(404, "not_found", "No such item.")
                : .json(200, #"{ "progress": \#(Fixtures.progress(itemId: "up", positionMs: 2, revision: 9, updatedAt: 1795530000000)) }"#)
        }
        let store = makeStore()
        try await store.record(profileID: "yeva", itemID: "deleted-film", positionMs: 1, durationMs: nil, completed: false)
        try await store.record(profileID: "yeva", itemID: "up", positionMs: 2, durationMs: nil, completed: false)

        let result = try await store.flush(using: stub.client())

        #expect(result.rejected.map(\.operation.itemID) == ["deleted-film"])
        #expect(result.rejected.first?.error == .notFound(message: "No such item."))
        #expect(result.accepted == 1)
        #expect(result.remaining == 0)
        #expect(await store.progress(profileID: "yeva", itemID: "deleted-film") == nil)
    }

    @Test func refreshingFetchesOnlyWhatChangedSince() async throws {
        let stub = StubServer { request in
            request.query["since"] == nil
                ? .json(200, #"{ "progress": [\#(Fixtures.progress(itemId: "up", positionMs: 1000, revision: 40, updatedAt: 1795530000000)), \#(Fixtures.progress(itemId: "jungle", positionMs: 0, completed: true, revision: 41, updatedAt: 1795530000000))], "revision": 41 }"#)
                : .json(200, #"{ "progress": [\#(Fixtures.progress(itemId: "up", positionMs: 0, revision: 55, updatedAt: 1795530900000))], "revision": 55 }"#)
        }
        let store = makeStore()

        try await store.refresh(profileID: "yeva", using: stub.client())
        #expect(stub.recorded[0].path == "/v1/profiles/yeva/progress")
        #expect(stub.recorded[0].query.isEmpty)
        #expect(await store.progress(profileID: "yeva").count == 2)
        #expect(await store.progress(profileID: "yeva", itemID: "jungle")?.completed == true)

        // After a relaunch the revision is still known. A cleared position replaces the old one.
        let relaunched = makeStore()
        try await relaunched.refresh(profileID: "yeva", using: stub.client())
        #expect(stub.recorded[1].query == ["since": "41"])
        #expect(await relaunched.progress(profileID: "yeva", itemID: "up")?.positionMs == 0)
        #expect(await relaunched.progress(profileID: "yeva", itemID: "up")?.revision == 55)

        // A change made now is based on what was last seen.
        try await relaunched.record(profileID: "yeva", itemID: "up", positionMs: 5, durationMs: nil, completed: false)
        #expect(await relaunched.pendingOperations().first?.baseRevision == 55)
    }

    @Test func aNewerChangeFromAnotherDeviceShowsOverAnOlderUnsentOne() async throws {
        let store = makeStore()
        try await store.record(profileID: "yeva", itemID: "up", positionMs: 3_000_000, durationMs: nil, completed: false)

        let later = clock.now.millisecondsSince1970 + 60_000
        let stub = StubServer { _ in
            .json(200, #"{ "progress": [\#(Fixtures.progress(itemId: "up", positionMs: 0, revision: 60, updatedAt: later))], "revision": 60 }"#)
        }
        try await store.refresh(profileID: "yeva", using: stub.client())

        // The server will decide when the change is sent. Until then, show what will win.
        #expect(await store.progress(profileID: "yeva", itemID: "up")?.positionMs == 0)
        #expect(await store.pendingOperations().count == 1)
        // The unsent change keeps the revision the viewer had seen when making it, so the server
        // can tell it is the stale one.
        #expect(await store.pendingOperations().first?.baseRevision == nil)

        clock.advance(by: 120)
        try await store.record(profileID: "alex", itemID: "up", positionMs: 9, durationMs: nil, completed: false)
        try await store.record(profileID: "yeva", itemID: "up", positionMs: 42_000, durationMs: nil, completed: false)
        #expect(await store.progress(profileID: "yeva", itemID: "up")?.positionMs == 42_000)
    }

    @Test func synchroniseSendsFirstThenFetchesAndFailsWhenTheServerIsAway() async throws {
        let stub = Self.acceptingServer()
        let store = makeStore()
        try await store.record(profileID: "yeva", itemID: "up", positionMs: 1, durationMs: nil, completed: false)

        let result = try await store.synchronise(profileID: "yeva", using: stub.client())
        #expect(result.accepted == 1)
        #expect(stub.recorded.map(\.method) == ["PUT", "GET"])

        try await store.record(profileID: "yeva", itemID: "up", positionMs: 2, durationMs: nil, completed: false)
        stub.goOffline()
        await #expect(throws: LobbyError.unreachable(.cannotConnectToHost)) {
            try await store.synchronise(profileID: "yeva", using: stub.client())
        }
        #expect(await store.pendingOperations().count == 1)
    }

    @Test func marksWatchedAndUnwatched() async throws {
        let store = makeStore()
        try await store.record(profileID: "yeva", itemID: "up", positionMs: 4_000_000, durationMs: 5_000_000, completed: false)

        let watched = try await store.markWatched(profileID: "yeva", itemID: "up")
        #expect(watched.completed)
        #expect(watched.durationMs == 5_000_000)

        let unwatched = try await store.markUnwatched(profileID: "yeva", itemID: "up")
        #expect(unwatched.positionMs == 0)
        #expect(!unwatched.completed)
        #expect(!unwatched.isInProgress)
        #expect(await store.pendingOperations().count == 1)
    }

    @Test func removingAProfileDropsItsProgressAndQueue() async throws {
        let store = makeStore()
        try await store.record(profileID: "yeva", itemID: "up", positionMs: 1, durationMs: nil, completed: false)
        try await store.record(profileID: "alex", itemID: "up", positionMs: 2, durationMs: nil, completed: false)

        try await store.removeProfile("yeva")

        #expect(await store.progress(profileID: "yeva").isEmpty)
        #expect(await store.pendingOperations().map(\.profileID) == ["alex"])
        try await store.clear()
        #expect(await makeStore().pendingOperations().isEmpty)
    }

    @Test func aFileThisBuildCannotReadIsSetAsideNotOverwritten() async throws {
        let future = #"{ "version": 99, "queue": [ { "opId": "from-a-newer-build" } ] }"#
        try Data(future.utf8).write(to: directory.file("progress.json"))

        let store = makeStore()
        #expect(await store.pendingOperations().isEmpty)
        try await store.record(profileID: "yeva", itemID: "up", positionMs: 1, durationMs: nil, completed: false)

        let aside = try String(contentsOf: directory.file("progress.json.unreadable"), encoding: .utf8)
        #expect(aside == future)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.file("progress.json"))) as? [String: Any]
        #expect(object?["version"] as? Int == 1)
    }
}
