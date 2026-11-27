// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit

/// Fetches the cues of a subtitle the app draws itself.
struct SubtitleLoader: Sendable {
    enum Outcome: Hashable, Sendable {
        case cues(SubtitleCues)
        /// Subtitles stored as pictures, to be drawn where they belong.
        case pictures(PictureSubtitles)
        /// It cannot be had, and waiting will not change that.
        case failed
    }

    var client: LobbyClient
    var downloads: DownloadManager
    var sleep: @Sendable (Duration) async throws -> Void
    static let retryEvery = Duration.seconds(3)
    /// Requests for picture subtitles before giving up: some minutes of reading a large film.
    static let pictureAttempts = 20

    /// - Parameters:
    ///   - mayStillCome: Asked after a failure. True while the server is still writing the
    ///     film's copy: a subtitle inside the film is written in the same pass and exists only
    ///     when that is done, so the request is tried again until then.
    ///   - waiting: Called when it is being waited for, so the viewer can be told.
    func load(
        _ option: SubtitleOption, mayStillCome: @MainActor () -> Bool, waiting: @MainActor () -> Void
    ) async -> Outcome {
        switch option.source {
        case .stored(let itemID, let subtitleID):
            guard let file = await downloads.localSubtitleFile(itemID: itemID, subtitleID: subtitleID),
                let text = try? String(contentsOf: file, encoding: .utf8)
            else { return .failed }
            return Self.outcome(text)

        case .server(let assetID, let track) where track.isPicture:
            // The server reads the whole film for them the first time, which can outlast a
            // request: it goes on reading, and a request after that has them.
            for _ in 0..<Self.pictureAttempts where !Task.isCancelled {
                do {
                    let pictures = try await LobbyError.waitingItsTurn(sleep: sleep) {
                        try await client.pictureSubtitles(assetID: assetID, subtitle: track)
                    }
                    return pictures.cues.isEmpty ? .failed : .pictures(pictures)
                } catch let error as LobbyError where error.isTransient {
                    await waiting()
                    do { try await sleep(Self.retryEvery) } catch { return .failed }
                } catch {
                    return .failed
                }
            }
            return .failed

        case .server(let assetID, let track):
            // The server answers such a request only when the copy is done, which can be
            // minutes: say so before asking, not after the first request ran out of time.
            if await mayStillCome() { await waiting() }
            while !Task.isCancelled {
                if let text = try? await ask(assetID: assetID, track: track) {
                    return Self.outcome(text)
                }
                guard await mayStillCome() else {
                    // The copy may have been completed while the request was out: once more.
                    if let text = try? await ask(assetID: assetID, track: track) {
                        return Self.outcome(text)
                    }
                    return .failed
                }
                await waiting()
                do {
                    try await sleep(Self.retryEvery)
                } catch {
                    return .failed
                }
            }
            return .failed
        }
    }

    private func ask(assetID: String, track: SubtitleTrack) async throws -> String {
        try await LobbyError.waitingItsTurn(sleep: sleep) { try await client.subtitle(assetID: assetID, subtitle: track) }
    }

    private static func outcome(_ text: String) -> Outcome {
        let cues = SubtitleCues(webVTT: text)
        return cues.isEmpty ? .failed : .cues(cues)
    }
}
