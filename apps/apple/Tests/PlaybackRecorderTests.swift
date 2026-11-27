// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Testing

@testable import Lobby

@MainActor
@Suite struct PlaybackRecorderTests {
    let household = Household()
    let directory: TemporaryDirectory
    let store: ProgressStore

    init() throws {
        directory = try TemporaryDirectory()
        store = ProgressStore(fileURL: LobbyStorage.progressFile(in: directory.url))
    }

    private func recorder(durationMs: Int? = 6_000_000, hasProgress: Bool = false) throws -> PlaybackRecorder {
        PlaybackRecorder(
            profileID: "alex", itemID: "up", durationMs: durationMs, hasProgress: hasProgress, store: store,
            client: try household.stub.client(token: "device-token"))
    }

    private var puts: [RecordedRequest] { household.stub.requests("PUT", "/v1/profiles/alex/progress/up") }

    @Test func theFirstSecondsAreNotWrittenDown() async throws {
        let recorder = try recorder()
        #expect(await recorder.tick(positionMs: 2_000) == .unchanged)
        #expect(await recorder.checkpoint(positionMs: 3_000) == .unchanged)
        #expect(await store.progress(profileID: "alex", itemID: "up") == nil)
    }

    @Test func whilePlayingThePositionIsKeptOnTheDeviceEveryTenSeconds() async throws {
        let recorder = try recorder()
        #expect(await recorder.tick(positionMs: 6_000) == .recorded)
        #expect(await recorder.tick(positionMs: 9_000) == .unchanged)
        #expect(await recorder.tick(positionMs: 16_000) == .recorded)

        #expect(await store.progress(profileID: "alex", itemID: "up")?.positionMs == 16_000)
        // Not sent yet: one queued change, which the next one replaces.
        #expect(await store.pendingOperations().count == 1)
        #expect(puts.isEmpty)
    }

    @Test func aMinuteOfPlayingSendsThePosition() async throws {
        let recorder = try recorder()
        await recorder.tick(positionMs: 6_000)
        await recorder.tick(positionMs: 36_000)
        #expect(puts.isEmpty)
        await recorder.tick(positionMs: 66_000)
        #expect(puts.count == 1)
        #expect(puts[0].json()["positionMs"] as? Int == 66_000)
    }

    @Test func pausingSendsThePositionAtOnce() async throws {
        let recorder = try recorder()
        #expect(await recorder.checkpoint(positionMs: 2_057_000) == .recorded)

        #expect(puts.count == 1)
        #expect(puts[0].json()["positionMs"] as? Int == 2_057_000)
        #expect(puts[0].json()["completed"] as? Bool == false)
        #expect(await store.pendingOperations().isEmpty)
        #expect(household.current.progress["alex"]?["up"]?.positionMs == 2_057_000)
    }

    @Test func stoppingInTheCreditsMarksItWatched() async throws {
        let recorder = try recorder()
        await recorder.checkpoint(positionMs: 5_800_000)
        #expect(household.current.progress["alex"]?["up"]?.completed == true)
    }

    @Test func playingToTheEndMarksItWatchedEvenWithoutADuration() async throws {
        let recorder = try recorder(durationMs: nil)
        await recorder.tick(positionMs: 30_000)
        recorder.setDuration(ms: 90_000)
        await recorder.finish()
        let stored = try #require(household.current.progress["alex"]?["up"])
        #expect(stored.completed)
        #expect(stored.positionMs == 90_000)
        #expect(stored.durationMs == 90_000)
    }

    @Test func withThePiOutOfReachThePositionWaitsOnTheDevice() async throws {
        household.change { $0.offline = true }
        let recorder = try recorder()
        #expect(await recorder.checkpoint(positionMs: 600_000) == .recorded)
        #expect(await store.progress(profileID: "alex", itemID: "up")?.positionMs == 600_000)
        #expect(await store.pendingOperations().count == 1)

        // Back in reach: the next checkpoint delivers.
        household.change { $0.offline = false }
        await recorder.checkpoint(positionMs: 660_000)
        #expect(await store.pendingOperations().isEmpty)
        #expect(household.current.progress["alex"]?["up"]?.positionMs == 660_000)
    }

    @Test func aRemovedDeviceIsReportedAndThePositionKept() async throws {
        household.change { $0.revoked = true }
        let recorder = try recorder()
        guard case .requiresPairing(.deviceRevoked) = await recorder.checkpoint(positionMs: 600_000) else {
            Issue.record("Expected the removal to be reported.")
            return
        }
        #expect(await store.pendingOperations().count == 1)
    }

    @Test func scrubbingBackToTheStartIsWrittenDownWhenThereWasProgress() async throws {
        let recorder = try recorder(hasProgress: true)
        #expect(await recorder.checkpoint(positionMs: 0) == .recorded)
        #expect(household.current.progress["alex"]?["up"]?.positionMs == 0)
    }
}
