// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Synchronization
import Testing

@testable import Lobby

@MainActor
@Suite struct StreamResolverTests {
    let household = Household()

    private static func answer(
        _ state: String, mode: String? = "prepared", progress: Double = 0, preparedMs: Int = 0, stream: Bool = false,
        message: String? = nil
    ) -> StubResponse {
        let streamURL = stream ? (mode == "direct" ? #""/v1/assets/a1/content""# : #""/v1/assets/a1/prepared/r1/master.m3u8""#) : "null"
        return .json(
            state == "ready" || state == "unsupported" ? 200 : 202,
            #"{"state":"\#(state)","mode":\#(mode.map { "\"\($0)\"" } ?? "null"),"revision":"r1","progress":\#(progress),"preparedMs":\#(preparedMs),"durationMs":6000000,"streamUrl":\#(streamURL),"downloadUrl":null,"downloadBytes":null,"audio":[],"message":\#(message.map { "\"\($0)\"" } ?? "null")}"#)
    }

    /// Resolves with a sleep that does not wait, and collects what the viewer was told.
    private func resolve(startMs: Int = 0) async -> (Result<ResolvedStream, StreamFailure>, [StreamResolver.Waiting], Int) {
        let polls = Mutex(0)
        let resolver = StreamResolver(
            client: try! household.stub.client(token: "device-token"),
            sleep: { _ in
                polls.withLock { $0 += 1 }
                try Task.checkCancellation()
            })
        var told: [StreamResolver.Waiting] = []
        do {
            let stream = try await resolver.resolve(assetID: "a1", startMs: startMs) { told.append($0) }
            return (.success(stream), told, polls.withLock { $0 })
        } catch {
            return (.failure(error), told, polls.withLock { $0 })
        }
    }

    private var asked: Int { household.stub.requests("POST", "/v1/assets/a1/playback").count }

    @Test func aFileThatPlaysAsItIsStartsAfterOneQuestion() async throws {
        household.change { $0.playback = [Self.answer("ready", mode: "direct", progress: 1, preparedMs: 6_000_000, stream: true)] }
        let (result, told, polls) = await resolve(startMs: 3_000_000)
        let stream = try result.get()
        #expect(stream.url.path == "/v1/assets/a1/content")
        #expect(stream.mode == .direct)
        #expect(!stream.isStillBeingWritten)
        #expect(told.isEmpty)
        #expect(polls == 0)
        #expect(asked == 1)
    }

    @Test func aBusyServerIsWaitedForAsInAQueue() async throws {
        household.change {
            $0.playback = [
                StubResponse(status: 429, headers: ["Retry-After": "3"]), StubResponse(status: 429),
                Self.answer("ready", mode: "direct", progress: 1, preparedMs: 6_000_000, stream: true),
            ]
        }
        let (result, told, polls) = await resolve()
        #expect(try result.get().mode == .direct)
        #expect(told == [.queued, .queued])
        #expect(polls == 2)
        #expect(asked == 3)
    }

    @Test func anMKVIsAskedForUntilItsFirstSecondsExist() async throws {
        household.change {
            $0.playback = [
                Self.answer("queued"),
                Self.answer("preparing"),
                Self.answer("preparing", progress: 0.01, preparedMs: 12_000, stream: true),
            ]
        }
        let (result, told, polls) = await resolve()
        let stream = try result.get()
        #expect(stream.url.path == "/v1/assets/a1/prepared/r1/master.m3u8")
        #expect(stream.mode == .prepared)
        #expect(stream.isStillBeingWritten)
        #expect(told == [.queued, .preparing(progress: 0)])
        #expect(polls == 2)
        #expect(asked == 3)
    }

    @Test func resumingPartWayWaitsUntilTheCopyReachesThatPosition() async throws {
        household.change {
            $0.playback = [
                Self.answer("preparing", progress: 0.1, preparedMs: 600_000, stream: true),
                Self.answer("preparing", progress: 0.4, preparedMs: 2_400_000, stream: true),
                Self.answer("preparing", progress: 0.6, preparedMs: 3_600_000, stream: true),
            ]
        }
        let (result, told, _) = await resolve(startMs: 3_000_000)
        #expect(try result.get().isStillBeingWritten)
        #expect(told == [.preparing(progress: 0.1), .preparing(progress: 0.4)])
        #expect(asked == 3)
    }

    @Test func aFinishedCopyPlaysFromAnywhere() async throws {
        household.change { $0.playback = [Self.answer("ready", progress: 1, preparedMs: 6_000_000, stream: true)] }
        let (result, _, _) = await resolve(startMs: 5_000_000)
        let stream = try result.get()
        #expect(stream.mode == .prepared)
        #expect(!stream.isStillBeingWritten)
    }

    @Test func whatCannotBePlayedShowsTheServersSentence() async {
        household.change {
            $0.playback = [Self.answer("unsupported", mode: nil, message: "The video is MPEG4, which Apple devices do not play.")]
        }
        let (result, _, _) = await resolve()
        #expect(result == .failure(StreamFailure(message: "The video is MPEG4, which Apple devices do not play.", requiresPairing: nil)))
    }

    @Test func aCopyThatFailedShowsWhy() async {
        household.change { $0.playback = [Self.answer("preparing"), Self.answer("failed", message: "The cache has no room for this file.")] }
        let (result, _, _) = await resolve()
        #expect(result == .failure(StreamFailure(message: "The cache has no room for this file.", requiresPairing: nil)))
    }

    @Test func anUnreachableServerIsNamedAsSuch() async {
        household.change { $0.offline = true }
        let (result, _, _) = await resolve()
        guard case .failure(let failure) = result else {
            Issue.record("Expected a failure.")
            return
        }
        #expect(failure.message.contains("cannot be reached"))
        #expect(failure.requiresPairing == nil)
    }

    @Test func aRemovedDeviceIsSentBackToPair() async {
        household.change { $0.revoked = true }
        let (result, _, _) = await resolve()
        guard case .failure(let failure) = result, case .deviceRevoked? = failure.requiresPairing else {
            Issue.record("Expected the removal to be reported, got \(result)")
            return
        }
    }

    @Test func aFileThatIsGoneSaysSo() async {
        let (result, _, _) = await resolve()
        #expect(result == .failure(StreamFailure(message: "This is no longer on Lobby Server.", requiresPairing: nil)))
    }
}
