// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import Foundation
import LobbyKit
import Observation
import os

/// One session of the player: the film or episode on screen, its `AVPlayer`, and the next
/// episode when there is one.
///
/// Platform-neutral. Each platform shows `player` in its own native player view (on iPhone and
/// iPad: `AVPlayerViewController`, in `iOS/PlayerPresenter.swift`) and draws `PlayerOverlay`
/// on top for the states below.
@MainActor
@Observable
final class PlayerModel: Identifiable {
    enum Stage: Hashable, Sendable {
        case loading
        /// The server is repackaging the file. 0…1 when it says how far it is, nil while the
        /// file waits its turn.
        case preparing(progress: Double?)
        case playing
        /// Played to the end.
        case ended
        case failed(String)
    }

    let player = AVPlayer()

    /// Why a film stopped or was asked for again. Error domains and codes only: never a title,
    /// a file name or an address.
    private nonisolated static let log = Logger(subsystem: "mt.sil.lobby", category: "player")

    private(set) var request: PlayRequest
    private(set) var stage: Stage = .loading
    /// The episode after this one, when it can be played.
    private(set) var upNext: PlayRequest?
    /// True in the credits and at the end, when there is a next episode.
    private(set) var offersPlayNext = false
    /// What the film's markers offer now: Skip Intro in the intro, Next Episode in the credits.
    private(set) var skipMoment: SkipMoment = .none
    /// What this viewer wants at intros and credits.
    private(set) var skipPreferences: SkipPreferences = .defaults
    private var introAutoSkip = IntroAutoSkip()
    /// Shows Skip Intro: in the intro, unless it is about to be skipped by itself.
    var offersSkipIntro: Bool { introAutoSkip.showsButton(for: skipMoment) }
    /// Where this episode's credits start, in its own time, when known and the viewer wants
    /// Next Episode there: the countdown to the next episode starts here.
    var creditsStartMs: Int? {
        SkipMoment.creditsStartMs(markers: request.file.markers, preferences: skipPreferences).map { max(0, $0 - fileOffsetMs) }
    }
    /// True once there is nothing left to show: the platform's player view closes itself.
    private(set) var isFinished = false
    /// What the player shows at the end (docs/playback.md, "When something ends"). nil: nothing.
    private(set) var ending: UpNextScreen?
    /// Up Next counts down: what comes next starts by itself when it is over. nil: it waits.
    private(set) var countdown: UpNextCountdown?
    /// After a film, or a series' last episode: what goes with it, to pick from.
    private(set) var suggestions: [UpNextSuggestion] = []
    /// Titles that played on by themselves since the viewer last touched anything.
    private var streak: WatchStreak
    private var countdownTask: Task<Void, Never>?
    /// Up Next came at the credits of this episode: once, also after a Cancel.
    private var cameAtCredits = false
    /// The viewer cancelled Up Next in the credits: at the end it does not count down again.
    private var cancelledAtCredits = false
    /// The player itself starts or stops until then: a change of its rate is not the viewer's.
    private var quietUntil = Date.distantPast
    /// Whether the film is running, for a Play/Pause menu item.
    private(set) var isPlaying = false
    /// It should run, and waits for more to arrive.
    private(set) var isWaiting = false
    /// Set while the server is still writing the copy that plays. The platform then shows the
    /// app's own transport (`PreparingTransport`) instead of the system's, which would present
    /// the growing stream as a live broadcast. nil again once the player knows the film's end.
    private(set) var preparing: PreparingTimeline?
    /// Subtitles the system player's own menu does not have, which the app draws itself.
    private(set) var subtitleOptions: [SubtitleOption] = []
    private(set) var selectedSubtitleID: String?
    /// The line on screen now, from the chosen subtitle.
    private(set) var subtitleText: String?
    /// Why the chosen subtitle is not showing.
    private(set) var subtitleProblem: String?
    /// Sound tracks and subtitles the stream itself offers, for the app's own transport. The
    /// system player lists the same in its menu.
    private(set) var audioChoices: [AVMediaSelectionOption] = []
    private(set) var streamSubtitleChoices: [AVMediaSelectionOption] = []
    private(set) var selectedAudio: AVMediaSelectionOption?
    private(set) var selectedStreamSubtitle: AVMediaSelectionOption?
    /// How this viewer wants subtitles: which are chosen when the film starts, and how they look.
    private(set) var subtitleStyle: SubtitlePreferences = .defaults
    /// How far the subtitles are moved against the picture this time (positive: later), as the
    /// viewer left it for this title.
    private(set) var subtitleOffsetMs = 0
    /// One step of `moveSubtitles`.
    static let subtitleStepMs = 500
    /// What the viewer picked themselves this time: it then goes before their preferences, also
    /// when the film is opened again (the copy was completed, AirPlay began).
    private var viewerPick: SubtitlePick?
    /// The subtitles of the item that plays were chosen; a change after that is the viewer's.
    private var subtitlesChosen = false
    private var offsetLoadedFor: String?
    private var offsetSave: Task<Void, Never>?
    private var selectionObserver: (any NSObjectProtocol)?

    /// A subtitle the viewer picked, by what it is rather than by an option of one item.
    private enum SubtitlePick: Equatable {
        case off
        case native(language: String?, isForced: Bool)
        case drawn(id: String)
    }

    /// The subtitles a viewer can choose from in the menus: none in the kids screens, where
    /// the viewer's preferences choose.
    var menuSubtitleOptions: [SubtitleOption] { isForKids ? [] : subtitleOptions }
    /// A subtitle is on screen now, or on its way: its timing can be moved.
    var showsSubtitles: Bool { selectedSubtitleID != nil || selectedStreamSubtitle != nil }

    private var client: LobbyClient
    private let profileID: String
    private let catalogue: Catalogue
    /// Started from the kids screens: nothing to choose, and plain words.
    let isForKids: Bool
    private weak var app: AppModel?

    private var recorder: PlaybackRecorder?
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: (any NSObjectProtocol)?
    private var statusObservation: NSKeyValueObservation?
    private var pauseObservation: NSKeyValueObservation?
    private var isClosed = false
    private var subtitleCues: SubtitleCues?
    private var subtitlePictures: PictureSubtitles?
    /// The picture of a subtitle stored as pictures that is on screen now, and the screen it is
    /// placed on.
    private(set) var subtitlePicture: (cue: PictureSubtitles.Cue, width: Int, height: Int)?
    private var subtitleObserver: Any?
    private var subtitleLoad: Task<Void, Never>?
    private var preparationWatch: Task<Void, Never>?
    private var stream: ResolvedStream?
    /// A prepared copy can be evicted from the server's cache while it plays, and a stream that
    /// is still being written can run dry. The item then fails: ask for playback again and go
    /// on where it stopped, a few times per film at most.
    private var timesAskedAgain = 0
    private static let mostTimesAskedAgain = 3
    /// Where playback starts once the item is ready, when that is not the beginning.
    private var pendingStartMs: Int?
    /// The player sends the film to an AirPlay receiver now.
    private(set) var isOnAirPlay = false
    /// What lets the receiver fetch the file itself (`POST /v1/assets/{id}/airplay`).
    private var airPlayPass: AirPlayPass?
    private var externalObservation: NSKeyValueObservation?
    private var jumpObserver: (any NSObjectProtocol)?
    /// False until playback began at its start position. Nothing is written down before that:
    /// the player's clock still reads 0:00 then, which is not where the viewer is.
    private(set) var hasStarted = false
    /// Seconds the item has played, until its picture was checked (`checkPicture`).
    private var secondsBeforePictureCheck: Int? = PlayerModel.pictureCheckAfterSeconds
    private nonisolated static let pictureCheckAfterSeconds = 4
    nonisolated static let pictureProblem = "This film can't be shown on this device yet."

    init(request: PlayRequest, client: LobbyClient, profileID: String, catalogue: Catalogue, isForKids: Bool = false, app: AppModel) {
        self.request = request
        self.client = client
        self.profileID = profileID
        self.catalogue = catalogue
        self.isForKids = isForKids
        self.app = app
        streak = WatchStreak(now: app.environment.now())
        player.isMuted = AppLaunch.isMuted
    }

    func start() {
        let request = request
        externalObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            Task { @MainActor in self?.externalPlaybackChanged(active) }
        }
        loadTask = Task {
            // Already on AirPlay (chosen before the film): the receiver gets a pass from the start.
            if Self.routeIsAirPlay, self.mayUseAirPlayPass { await self.fetchAirPlayPass(for: request.file.assetId) }
            await self.load(request)
        }
    }

    /// The person is on AirPlay already. Only an iPhone or iPad can tell before playing.
    private static var routeIsAirPlay: Bool {
        #if os(iOS)
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
        #else
        false
        #endif
    }

    /// The app talks to the server at home: the receiver, on the same network, can reach it too.
    private var mayUseAirPlayPass: Bool {
        app?.road == .home && !client.isCarriedByRoad && request.source != .local
    }

    // MARK: Loading

    private func load(_ request: PlayRequest) async {
        guard let app else { return }
        if request.item.id != self.request.item.id {
            // Another episode: the viewer's pick and timing were for the one before.
            viewerPick = nil
            subtitleOffsetMs = 0
            offsetLoadedFor = nil
        }
        self.request = request
        subtitleStyle = app.profiles.first { $0.id == profileID }?.subtitlePreferences ?? .defaults
        skipPreferences = app.profiles.first { $0.id == profileID }?.skipPreferences ?? .defaults
        skipMoment = .none
        introAutoSkip = IntroAutoSkip()
        subtitlesChosen = false
        stage = .loading
        offersPlayNext = false
        endUpNext()
        cameAtCredits = false
        cancelledAtCredits = false
        suggestions = []
        hasStarted = false
        pendingStartMs = nil
        secondsBeforePictureCheck = Self.pictureCheckAfterSeconds
        upNext = nextRequest(after: request, app: app)
        resetExtras()

        let start = fileOffsetMs + request.startPositionMs
        let asset: AVURLAsset
        let playing: SubtitleChoices.Playing
        if request.source == .local, let file = await app.environment.downloads.localFile(itemID: request.item.id) {
            // The copy on this device: no server, no network.
            stream = nil
            asset = AVURLAsset(url: file)
            playing = .local(stored: app.downloads[request.item.id]?.local?.subtitles ?? [])
        } else {
            // Always ask the server first, for a file that plays as it is too, and play the URL
            // it gives (docs/playback.md).
            let resolved: ResolvedStream
            do {
                resolved = try await StreamResolver(client: client, sleep: app.environment.sleep)
                    .resolve(assetID: request.file.assetId, startMs: start) { [weak self] waiting in
                        switch waiting {
                        case .queued: self?.stage = .preparing(progress: nil)
                        case .preparing(let progress): self?.stage = .preparing(progress: progress)
                        }
                    }
            } catch {
                guard !isClosed, !Task.isCancelled else { return }
                stage = .failed(app.roadProblem ?? error.message)
                if let lost = error.requiresPairing {
                    await app.credentialLost(lost)
                } else if isForKids {
                    await app.kidsPlaybackFailed()
                }
                return
            }
            stream = resolved
            playing = resolved.mode == .prepared ? .stream(stillBeingWritten: resolved.isStillBeingWritten) : .direct
            // The device credential travels as a cookie: AVPlayer cannot set a header, and the
            // token must never be in a URL. Over the direct road the app's own local server puts
            // it on, and the player gets none.
            let cookie = client.deviceCookie()
            guard cookie != nil || client.isCarriedByRoad else { return }
            if let pass = airPlayPass, pass.assetId == request.file.assetId, let passed = client.url(resolved.url, under: pass) {
                // On AirPlay: the receiver gets neither header nor cookie, and fetches under the pass.
                asset = AVURLAsset(url: passed)
            } else {
                asset = AVURLAsset(url: resolved.url, options: cookie.map { [AVURLAssetHTTPCookiesKey: [$0]] })
            }
        }
        // An AirPlay receiver fetches the film itself, and cannot reach a server inside this app.
        player.allowsExternalPlayback = stream == nil || !client.isCarriedByRoad
        guard !isClosed, !Task.isCancelled else { return }

        let item = AVPlayerItem(asset: asset)
        #if !os(macOS)
        item.externalMetadata = Self.metadata(for: request)
        #endif
        // How the player's own subtitles look, as this viewer wants them.
        item.textStyleRules = Self.textStyleRules(for: subtitleStyle)
        loadSubtitleOffset(itemID: request.item.id)

        let existing = app.progress[request.item.id]
        recorder = PlaybackRecorder(
            profileID: profileID, itemID: request.item.id, durationMs: request.durationMs,
            hasProgress: existing != nil, store: app.environment.progressStore, client: client)

        if stream?.isStillBeingWritten == false { item.preferredForwardBufferDuration = Self.forwardBuffer(atHome: app.road == .home) }

        observe(item)
        player.replaceCurrentItem(with: item)
        // Also in the kids screens: there the viewer's preferences choose (forced subtitles), and
        // the menus offer nothing (`menuSubtitleOptions`).
        subtitleOptions = SubtitleChoices.options(for: request.file, itemID: request.item.id, playing: playing)
        watchPreparation(of: item, startMs: start)
        loadMediaChoices(of: item)
        stage = .playing
        if start > 0 {
            // Resume starts exactly where the viewer stopped. A seek asked for before the item
            // is ready lands on the keyframe before it, seconds early, so it waits for the item
            // (`itemChanged`) and playback starts after it.
            pendingStartMs = start
        } else {
            hasStarted = true
            playByItself()
        }
    }

    private func startAtPendingPosition() {
        guard let start = pendingStartMs, let item = player.currentItem, let app else { return }
        pendingStartMs = nil
        let player = player
        let target = CMTime(value: CMTimeValue(start), timescale: 1000)
        let waitsForSeekable = stream?.isStillBeingWritten == true
        let sleep = app.environment.sleep
        loadTask = Task {
            // While a copy is being written the player's seekable range trails what the server
            // has prepared. Seeking past it would jump to the end, so wait for it to get there.
            while waitsForSeekable, !Self.canSeek(item, to: target) {
                do {
                    try await sleep(StreamResolver.pollEvery)
                } catch {
                    return
                }
            }
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            guard !self.isClosed, !Task.isCancelled else { return }
            self.hasStarted = true
            self.playByItself()
        }
    }

    private static func canSeek(_ item: AVPlayerItem, to time: CMTime) -> Bool {
        item.seekableTimeRanges.contains { $0.timeRangeValue.containsTime(time) }
    }

    private func nextRequest(after request: PlayRequest, app: AppModel) -> PlayRequest? {
        guard request.item.kind == .episode,
            let next = EpisodeOrder.nextEpisode(after: request.item, in: catalogue)
        else { return nil }
        var upNext = PlayActionBuilder.action(
            for: next, show: request.show, progress: app.progress[next.id], context: app.playbackContext
        ).request
        // Play Next starts the next episode at its beginning unless the viewer left it part-way.
        if app.progress[next.id]?.isInProgress != true {
            upNext?.startPositionMs = 0
        }
        return upNext
    }

    #if !os(macOS)
    /// What the native player and the lock screen show as title.
    private static func metadata(for request: PlayRequest) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item
        }
        var items = [item(.commonIdentifierTitle, request.title)]
        if let subtitle = request.subtitle {
            items.append(item(.iTunesMetadataTrackSubTitle, subtitle))
        }
        return items
    }
    #endif

    // MARK: Position

    /// Where the film or episode starts in its file. Not zero when one file holds several
    /// episodes.
    private var fileOffsetMs: Int { request.file.startMs ?? 0 }

    /// The position within the film or episode, or nil before the player knows it.
    private var positionMs: Int? {
        let time = player.currentTime()
        guard time.isNumeric else { return nil }
        return max(0, Int((time.seconds * 1000).rounded()) - fileOffsetMs)
    }

    private func observe(_ item: AVPlayerItem) {
        stopObserving()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 1), queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, as asked for above.
            MainActor.assumeIsolated { self?.tick() }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        }

        statusObservation = item.observe(\.status) { [weak self] item, _ in
            let status = item.status
            if let error = item.error as NSError? {
                let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
                Self.log.error(
                    "The player item failed: \(error.domain, privacy: .public) \(error.code, privacy: .public), underlying \(underlying?.domain ?? "none", privacy: .public) \(underlying?.code ?? 0, privacy: .public)")
            }
            let failure = item.error?.localizedDescription
            let seconds = item.duration.isNumeric ? item.duration.seconds : nil
            Task { @MainActor in self?.itemChanged(status: status, failure: failure, durationSeconds: seconds) }
        }

        pauseObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let paused = player.timeControlStatus == .paused
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor in
                guard let self else { return }
                // Paused or started with the system's own controls: the viewer is there.
                if !waiting, paused == self.isPlaying { self.touchedBySystemControls() }
                self.isWaiting = waiting
                self.isPlaying = !paused
                if paused { self.paused() }
                self.app?.remote.changed()
            }
        }

        // A jump made with this device's own controls: the others follow at once.
        jumpObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.touchedBySystemControls()
                self?.app?.remote.changed()
            }
        }

        // A subtitle chosen in the system player's own menu.
        selectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated { self?.selectionChanged(in: item) }
        }
    }

    private func stopObserving() {
        resetExtras()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
        jumpObserver = nil
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil
        statusObservation?.invalidate()
        pauseObservation?.invalidate()
        timeObserver = nil
        endObserver = nil
        statusObservation = nil
        pauseObservation = nil
    }

    private func itemChanged(status: AVPlayerItem.Status, failure: String?, durationSeconds: Double?) {
        switch status {
        case .readyToPlay:
            if let durationSeconds, request.file.endMs == nil {
                recorder?.setDuration(ms: Int((durationSeconds * 1000).rounded()))
            }
            startAtPendingPosition()
        case .failed:
            if stream?.mode == .prepared || (stream != nil && client.isCarriedByRoad), timesAskedAgain < Self.mostTimesAskedAgain, !isClosed {
                timesAskedAgain += 1
                var again = request
                again.startPositionMs = positionMs ?? request.startPositionMs
                stopObserving()
                loadTask = Task { await self.load(again) }
            } else {
                stage = .failed(app?.roadProblem ?? failure ?? "This file could not be played.")
                if isForKids, let app { Task { await app.kidsPlaybackFailed() } }
            }
        default:
            break
        }
    }

    private func tick() {
        if let positionMs, hasStarted { preparing?.positionMs = positionMs + fileOffsetMs }
        if preparing != nil, let item = player.currentItem { preparing?.bufferedMs = Self.bufferedMs(of: item.loadedTimeRanges) }
        checkPicture()
        guard hasStarted, stage == .playing, let positionMs, let recorder else { return }
        if let end = request.file.endMs, positionMs + fileOffsetMs >= end {
            // The episode's part of a shared file is over.
            pauseByItself()
            reachedEnd()
            return
        }
        updateSkipMoment(fileMs: positionMs + fileOffsetMs)
        offersPlayNext = upNext != nil
            && (skipMoment.isCredits || PlaybackPolicy.isCompleted(positionMs: positionMs, durationMs: recorder.durationMs))
        showUpNextAtCredits(positionMs: positionMs)
        Task { await self.apply(recorder.tick(positionMs: positionMs)) }
    }

    /// A picture the device cannot decode (HEVC labelled `hev1`, say) does not fail the item:
    /// AVPlayer plays the sound over black. After a few seconds of playing with no picture size,
    /// stop and say so instead. Not on AirPlay, where the receiver draws the picture.
    private func checkPicture() {
        guard let remaining = secondsBeforePictureCheck, hasStarted, stage == .playing,
              player.timeControlStatus == .playing, !isOnAirPlay, let item = player.currentItem
        else { return }
        guard remaining <= 0 else {
            secondsBeforePictureCheck = remaining - 1
            return
        }
        secondsBeforePictureCheck = nil
        let tracks = item.tracks.compactMap { $0.assetTrack?.mediaType }
        guard Self.pictureIsMissing(presentationSize: item.presentationSize, mediaTypes: tracks) else { return }
        Self.log.error(
            "The sound plays without a picture: \(tracks.filter { $0 == .video }.count, privacy: .public) video tracks, mode \(String(describing: self.stream?.mode), privacy: .public)")
        pauseByItself()
        stage = .failed(Self.pictureProblem)
    }

    /// What the player holds, in milliseconds of the file.
    nonisolated static func bufferedMs(of ranges: [NSValue]) -> [Range<Int>] {
        ranges.compactMap { value in
            let range = value.timeRangeValue
            guard range.start.isNumeric, range.duration.isNumeric else { return nil }
            let start = Int((range.start.seconds * 1000).rounded())
            let end = Int((range.end.seconds * 1000).rounded())
            return end > start ? start..<end : nil
        }
    }

    /// Sound is playing and there is no picture to show.
    nonisolated static func pictureIsMissing(presentationSize: CGSize, mediaTypes: [AVMediaType]) -> Bool {
        presentationSize == .zero && mediaTypes.contains(.audio)
    }

    private func paused() {
        guard hasStarted, !isClosed, stage == .playing, let positionMs, let recorder else { return }
        Task { await self.apply(recorder.checkpoint(positionMs: positionMs)) }
    }

    private func reachedEnd() {
        guard hasStarted, stage == .playing, let recorder else { return }
        stage = .ended
        offersPlayNext = upNext != nil
        streak.itemEnded()
        Task {
            await self.apply(recorder.finish(sends: false))
            self.showEnding()
            await self.apply(recorder.send())
        }
    }

    // MARK: When something ends

    /// What this viewer wants at the end, from their own preferences: on a TV that plays as a
    /// viewer, that viewer's. Kids viewers have their own defaults (asked sooner).
    var playbackPreferences: PlaybackPreferences {
        app?.profiles.first { $0.id == profileID }?.playbackPreferences ?? (isForKids ? .kidsDefaults : .defaults)
    }

    /// Whether kids control lets this play now. Kids modes win over Up Next and autoplay: what
    /// the child may not watch now is neither offered nor started by itself.
    private func kidsAllow(_ next: PlayRequest) -> Bool {
        guard let app, isForKids || app.isKidsMode else { return true }
        let ids = [next.item.id] + [next.item.parentId, next.show?.id].compactMap { $0 }
        return app.kidsControl.allowsVideo(of: ids)
    }

    /// Up Next at the credits of an episode, where the server knows where they start and the
    /// viewer wants it there (`startAtCredits`, and Next Episode in their skip choices). The
    /// episode plays on under it; when the countdown is over the next one starts, and this one
    /// is finished there. "Still watching?" waits for the end.
    private func showUpNextAtCredits(positionMs: Int) {
        guard !cameAtCredits, !isClosed, stage == .playing, ending == nil, let next = upNext,
              let credits = creditsStartMs, positionMs >= credits, let app
        else { return }
        cameAtCredits = true
        guard kidsAllow(next) else {
            upNext = nil
            offersPlayNext = false
            return
        }
        guard case .show(let screen, let seconds) = UpNextPlanner.atCredits(
            positionMs: positionMs, creditsStartMs: credits, preferences: playbackPreferences, streak: streak,
            now: app.environment.now())
        else { return }
        ending = screen
        if let seconds { startCountdown(seconds) }
        app.remote.changed()
    }

    /// The end of a film or episode: Up Next, the suggestions, "Still watching?", or closing.
    /// Up Next comes at the credits instead where they are known (`showUpNextAtCredits`); what
    /// it started there goes on.
    private func showEnding() {
        guard !isClosed, stage == .ended, let app else { return }
        if let next = upNext, !kidsAllow(next) {
            upNext = nil
            offersPlayNext = false
        }
        // Up Next already counts down from the credits, or was cancelled there.
        if upNext != nil, ending == .nextEpisode || cancelledAtCredits {
            app.remote.changed()
            return
        }
        if upNext == nil { suggestions = app.upNextSuggestions(after: request).filter { kidsAllow($0.request) } }
        let plan = UpNextPlanner.plan(
            hasNextEpisode: upNext != nil, hasSuggestions: !suggestions.isEmpty, preferences: playbackPreferences,
            streak: streak, now: app.environment.now())
        switch plan {
        case .close:
            isFinished = true
        case .show(let screen, let seconds):
            ending = screen
            if let seconds { startCountdown(seconds) }
        }
        app.remote.changed()
    }

    private func startCountdown(_ seconds: Int) {
        countdownTask?.cancel()
        countdown = UpNextCountdown(seconds: seconds)
        guard let sleep = app?.environment.sleep else { return }
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(.seconds(1)) } catch { return }
                guard let self, !Task.isCancelled, var countdown = self.countdown else { return }
                let over = countdown.tick()
                self.countdown = countdown
                if over {
                    self.countdownTask = nil
                    self.playOnByItself()
                    return
                }
            }
        }
    }

    /// The countdown is over: what comes next starts, and it counts as not touched. Unless kids
    /// control no longer allows it: then the card stays without a countdown.
    private func playOnByItself() {
        switch ending {
        case .nextEpisode:
            guard let next = upNext, kidsAllow(next) else { return endUpNext() }
            playNext(byViewer: false)
        case .suggestions:
            guard let first = suggestions.first(where: { kidsAllow($0.request) }) else { return }
            play(first, byViewer: false)
        case .stillWatching, nil: break
        }
    }

    private func endUpNext() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        ending = nil
    }

    /// Play Now, on the Up Next card or from a remote.
    func playUpNextNow() {
        switch ending {
        case .nextEpisode: playNext()
        case .suggestions: if let first = suggestions.first { play(first) }
        case .stillWatching: continueWatching()
        case nil: if upNext != nil { playNext() }
        }
    }

    /// Cancel: the countdown stops. The next episode stays offered with Play Next; the
    /// suggestions stay, to pick from or close.
    func cancelUpNext() {
        touched()
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        if stage == .playing, ending == .nextEpisode { cancelledAtCredits = true }
        if ending == .nextEpisode { ending = nil }
        app?.remote.changed()
    }

    /// "Continue Watching": the viewer is there. What would have started by itself starts.
    func continueWatching() {
        guard ending == .stillWatching else { return }
        touched()
        if upNext != nil {
            playNext()
        } else if let first = suggestions.first {
            play(first)
        }
    }

    /// Picks a suggestion: it plays in this player, as the next episode would.
    func play(_ suggestion: UpNextSuggestion, byViewer: Bool = true) {
        if byViewer { touched() }
        let finishing = stage == .playing
        let recorder = recorder
        endUpNext()
        pauseByItself()
        stopObserving()
        loadTask = Task {
            if finishing, let recorder { await self.apply(recorder.finish(positionMs: self.positionMs, sends: false)) }
            if let recorder { Task { await self.apply(recorder.send()) } }
            await self.load(suggestion.request)
        }
    }

    /// The viewer did something: the count of titles that played on by themselves starts again.
    func touched() {
        guard let app else { return }
        streak.touched(at: app.environment.now())
    }

    /// The system's own controls changed what plays: a pause, a start, a jump. Not a change the
    /// player made by itself (starting, stopping at the end of an episode's part).
    private func touchedBySystemControls() {
        guard hasStarted, stage == .playing, !isClosed, let app, app.environment.now() >= quietUntil else { return }
        // At the very end the player stops by itself.
        if let position = positionMs, let duration = request.durationMs ?? recorder?.durationMs, duration - position < 1_500 { return }
        touched()
    }

    private func playByItself() {
        quietUntil = (app?.environment.now() ?? Date()).addingTimeInterval(1.5)
        player.play()
    }

    private func pauseByItself() {
        quietUntil = (app?.environment.now() ?? Date()).addingTimeInterval(1.5)
        player.pause()
    }

    private func apply(_ outcome: PlaybackRecorder.Outcome) async {
        switch outcome {
        case .unchanged:
            break
        case .recorded:
            await app?.reloadProgress()
        case .requiresPairing(let error):
            await app?.credentialLost(error)
        }
    }

    // MARK: Actions

    /// Writes the position down now. For when the app goes to the background.
    func checkpoint() async {
        guard hasStarted, stage == .playing, let positionMs, let recorder else { return }
        await apply(recorder.checkpoint(positionMs: positionMs))
    }

    /// Play or pause, for a menu item or a key.
    func togglePlayback() {
        guard hasStarted, stage == .playing else { return }
        touched()
        if player.timeControlStatus == .paused {
            player.play()
        } else {
            player.pause()
        }
    }

    /// Marks this episode watched and starts the next one.
    ///
    /// - Parameter byViewer: False when the countdown started it: that is not a touch.
    func playNext(byViewer: Bool = true) {
        guard let next = upNext, let recorder else { return }
        if byViewer { touched() }
        let finishing = stage == .playing
        // Started by the countdown in the credits: this episode ended there.
        if finishing, !byViewer { streak.itemEnded() }
        endUpNext()
        pauseByItself()
        stopObserving()
        loadTask = Task {
            if finishing { await self.apply(recorder.finish(positionMs: self.positionMs, sends: false)) }
            // The next episode does not wait for the server to hear about this one.
            Task { await self.apply(recorder.send()) }
            await self.load(next)
        }
    }

    /// The viewer closed the player, or it closed itself at the end.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        loadTask?.cancel()
        endUpNext()
        pauseByItself()
        let recorder = recorder
        if hasStarted, stage == .playing, let positionMs, let recorder {
            await apply(recorder.checkpoint(positionMs: positionMs, sends: false))
        }
        stopObserving()
        externalObservation?.invalidate()
        externalObservation = nil
        player.replaceCurrentItem(with: nil)
        app?.remote.changed()
        // The library is back before the server has heard where the viewer stopped.
        await app?.playerClosed()
        if let recorder { await apply(recorder.send()) }
    }

    /// The server is reached over another road now. What the app's own local server carries goes on
    /// by itself; a film that came from an address that is gone is opened again where it is.
    func move(to client: LobbyClient) {
        let before = self.client
        self.client = client
        guard !isClosed, stream != nil, stage == .playing || stage == .loading, before.baseURL != client.baseURL else { return }
        // The local server sends it to the new address from here on.
        if before.isCarriedByRoad, !client.isCarriedByRoad { return }
        var again = request
        if hasStarted, let positionMs { again.startPositionMs = positionMs }
        let wasPlaying = !hasStarted || player.timeControlStatus != .paused
        loadTask?.cancel()
        stopObserving()
        loadTask = Task {
            await self.load(again)
            if !wasPlaying, !self.isClosed { self.pauseByItself() }
        }
    }

    /// What the viewer reads while a new connection is made. Only when the picture waits for it.
    var showsReconnecting: Bool {
        app?.isReconnecting == true && stream != nil && (isWaiting || stage == .loading)
    }

    /// Plays on from where it stopped, after a failure or when nothing arrived any more.
    func tryAgain() {
        guard !isClosed else { return }
        touched()
        timesAskedAgain = 0
        var again = request
        if hasStarted, let positionMs { again.startPositionMs = positionMs }
        loadTask?.cancel()
        player.pause()
        stopObserving()
        loadTask = Task { await self.load(again) }
    }

    // MARK: A copy that is still being written

    private func resetExtras() {
        preparationWatch?.cancel()
        preparationWatch = nil
        preparing = nil
        subtitleLoad?.cancel()
        if let subtitleObserver { player.removeTimeObserver(subtitleObserver) }
        subtitleObserver = nil
        subtitleCues = nil
        subtitlePictures = nil
        subtitlePicture = nil
        subtitleOptions = []
        selectedSubtitleID = nil
        subtitleText = nil
        subtitleProblem = nil
        audioChoices = []
        streamSubtitleChoices = []
        selectedAudio = nil
        selectedStreamSubtitle = nil
    }

    /// While the server writes the copy, the stream has no end and the player does not know
    /// the film's length. Keep the app's own bar up to date from the server's answers, until
    /// the player reports a length: then the copy is complete and the system's bar is right.
    private func watchPreparation(of item: AVPlayerItem, startMs: Int) {
        guard let stream, stream.isStillBeingWritten, let app,
            let durationMs = request.file.durationMs ?? stream.playback.durationMs ?? request.durationMs
        else { return }
        preparing = PreparingTimeline(
            durationMs: durationMs, preparedMs: stream.playback.preparedMs, positionMs: startMs,
            progress: stream.playback.progress, speed: stream.playback.speed,
            videoConverted: stream.playback.videoConverted)

        let client = client
        let assetID = request.file.assetId
        let sleep = app.environment.sleep
        preparationWatch = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(.seconds(2))
                } catch {
                    return
                }
                // Out of reach for a moment: the bar keeps what it knew.
                guard let playback = try? await client.playback(assetID: assetID), let self, !Task.isCancelled else { continue }
                if var timeline = self.preparing {
                    timeline.preparedMs = max(timeline.preparedMs, playback.preparedMs)
                    timeline.progress = playback.progress
                    timeline.speed = playback.speed
                    self.preparing = timeline
                }
                if playback.state == .ready {
                    self.copyIsComplete()
                    return
                }
                if playback.state != .preparing && playback.state != .queued {
                    // The server gave up on the copy, or no longer has the file: the stream
                    // ends where it is, and the player says why through its own failure.
                    // The bar of a film "being prepared" would be a lie from here on.
                    self.preparing = nil
                    return
                }
            }
        }
    }

    /// The server finished the copy. The item the player holds learns that at its next look at
    /// the playlist (once a segment's length, a few seconds), and turns into ordinary video on
    /// demand with the film's length: then the system's transport takes over from the app's own
    /// bar, on the same item, without a pause. Opening the film again instead, as before, cost a
    /// blink at best, and on a busy server a stall while the new item filled its buffer from
    /// nothing. The subtitles the app draws for the growing stream stay as they are.
    private func copyIsComplete() {
        preparationWatch = nil
        guard !isClosed, stage == .playing, hasStarted, let item = player.currentItem, let app else { return }
        let sleep = app.environment.sleep
        preparationWatch = Task { [weak self] in
            for _ in 0..<Self.secondsToLearnTheEnd where !item.duration.isNumeric {
                do { try await sleep(.seconds(1)) } catch { return }
            }
            guard let self, !self.isClosed, !Task.isCancelled, self.player.currentItem === item else { return }
            if item.duration.isNumeric {
                self.handOverToTheSystem(item)
            } else {
                self.openTheCompleteCopy()
            }
        }
    }

    /// How long the item may take to see the end of the playlist: AVPlayer looks again once per
    /// target duration, which follows the film's keyframes (up to some 13 s, longer for a few).
    nonisolated static let secondsToLearnTheEnd = 30

    private func handOverToTheSystem(_ item: AVPlayerItem) {
        preparing = nil
        if request.file.endMs == nil { recorder?.setDuration(ms: Int((item.duration.seconds * 1000).rounded())) }
        item.preferredForwardBufferDuration = Self.forwardBuffer(atHome: app?.road == .home)
    }

    /// How many seconds of film the player fetches ahead, over the network. Left to itself it
    /// fetches as much as it can, minutes ahead: over a mobile network that is film nobody may
    /// watch, and what a jump throws away.
    /// - At home, a minute: enough to ride out a Pi whose disk is busy writing a copy, or a
    ///   moment of bad Wi-Fi, and little to throw away on a jump.
    /// - Away, a minute on a phone, tablet or Mac too: the direct road mends a broken path within
    ///   seconds (docs/decisions.md, "A direct path that breaks"), and a minute is what a mobile network's data is spent on ahead.
    /// - Away on an Apple TV, three minutes: a TV abroad is on a hotel's slow line, where pausing
    ///   for a while to let more arrive is the way to watch (the buffer notice says so).
    nonisolated static func forwardBuffer(atHome: Bool) -> TimeInterval {
        #if os(tvOS)
        atHome ? 60 : 180
        #else
        60
        #endif
    }

    /// The item never saw the end: the film is opened once more, on the complete copy, where it is.
    private func openTheCompleteCopy() {
        var again = request
        again.startPositionMs = positionMs ?? request.startPositionMs
        let wasPlaying = player.timeControlStatus != .paused
        // A subtitle the viewer chose stays chosen, also one that was still on its way, and one
        // drawn because its timing was moved. One chosen for them is chosen again.
        let chosen = selectedSubtitleID
        let keepsDrawn: Bool
        if case .drawn = viewerPick { keepsDrawn = true } else { keepsDrawn = subtitleOffsetMs != 0 }
        let options = subtitleOptions
        stopObserving()
        loadTask = Task {
            await self.load(again)
            guard !self.isClosed else { return }
            if !wasPlaying { self.pauseByItself() }
            if keepsDrawn, let chosen, let option = options.first(where: { $0.id == chosen }) {
                if !self.subtitleOptions.contains(option) { self.subtitleOptions.append(option) }
                self.showDrawnSubtitle(chosen)
            }
        }
    }

    // MARK: Intros and credits

    private func updateSkipMoment(fileMs: Int) {
        let moment = SkipMoment.at(fileMs: fileMs, markers: request.file.markers, preferences: skipPreferences)
        if moment != skipMoment { skipMoment = moment }
        if let target = introAutoSkip.target(for: moment) {
            seek(toMs: target)
            skipMoment = .none
        }
    }

    /// Jumps to the end of the intro.
    func skipIntro() {
        guard case .intro(let end, _) = skipMoment else { return }
        seek(toMs: end)
        skipMoment = .none
    }

    /// Moves to a place on the app's own bar, as far as the copy reaches.
    func seek(toFraction fraction: Double) {
        guard let preparing else { return }
        touched()
        seek(toMs: preparing.seekTarget(fraction: fraction))
    }

    /// Ten seconds back or forward on the app's own bar.
    func skip(bySeconds seconds: Int) {
        guard let preparing else { return }
        touched()
        seek(toMs: preparing.skipTarget(bySeconds: seconds))
    }

    private func seek(toMs target: Int) {
        guard hasStarted, let item = player.currentItem else { return }
        var time = CMTime(value: CMTimeValue(target), timescale: 1000)
        // The player's own idea of what it can reach trails the server's by some seconds, and
        // it must not be put at the very end of that either.
        if let reachable = item.seekableTimeRanges.map(\.timeRangeValue.end).max(), reachable.isNumeric {
            time = min(time, max(.zero, reachable - CMTime(value: 20, timescale: 1)))
        }
        preparing?.positionMs = Int((time.seconds * 1000).rounded())
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
    }

    // MARK: Sound tracks and subtitles

    private func loadMediaChoices(of item: AVPlayerItem) {
        let asset = item.asset
        Task { [weak self] in
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, self.player.currentItem === item else { return }
            self.audioChoices = (audible?.options.count ?? 0) > 1 ? audible?.options ?? [] : []
            self.streamSubtitleChoices = legible?.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) } ?? []
            if let audible { self.selectedAudio = item.currentMediaSelection.selectedMediaOption(in: audible) }
            self.chooseSubtitles(legible: legible, item: item)
        }
    }

    /// Chooses the subtitles of the item that starts: what the viewer picked this time, else
    /// what their preferences ask for (`SubtitleChooser`), else none.
    private func chooseSubtitles(legible: AVMediaSelectionGroup?, item: AVPlayerItem) {
        let native = legible?.options ?? []
        var candidates = native.enumerated().map { index, option in
            SubtitleCandidate(
                id: "n\(index)", language: Self.language(of: option),
                isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles), isNative: true)
        }
        candidates += subtitleOptions.map { option in
            SubtitleCandidate(id: "d\(option.id)", language: option.language, isForced: option.isForced, isNative: false)
        }
        let chosen: SubtitleCandidate?
        switch viewerPick {
        case .off:
            chosen = nil
        case .drawn(let id):
            // Shown again by whoever opened the film again; when it is not there, nothing.
            chosen = candidates.first { $0.id == "d\(id)" }
            if selectedSubtitleID == id {
                if let legible { item.select(nil, in: legible) }
                selectedStreamSubtitle = nil
                subtitlesChosen = true
                return
            }
        case .native(let language, let isForced):
            let same = candidates.filter { $0.isForced == isForced && SubtitleLanguage.base($0.language) == SubtitleLanguage.base(language) }
            chosen = same.first(where: \.isNative) ?? same.first
        case nil:
            chosen = SubtitleChooser.choose(
                from: candidates, preferences: subtitleStyle, soundLanguage: soundLanguage,
                deviceLanguages: Locale.preferredLanguages)
        }
        subtitlesChosen = true
        if let chosen, chosen.isNative, let index = Int(chosen.id.dropFirst()), let legible {
            item.select(native[index], in: legible)
            selectedStreamSubtitle = native[index]
            if selectedSubtitleID != nil { showDrawnSubtitle(nil) }
            // Moved against the picture: only the app can do that.
            if subtitleOffsetMs != 0 { drawInsteadOfNative() }
        } else {
            // Explicitly none: the player would otherwise pick forced ones by itself.
            if let legible { item.select(nil, in: legible) }
            selectedStreamSubtitle = nil
            if let chosen { showDrawnSubtitle(String(chosen.id.dropFirst())) }
        }
    }

    /// The language of what is heard: the sound track that plays, else the file's first.
    private var soundLanguage: String? {
        if let selectedAudio, let language = Self.language(of: selectedAudio) { return language }
        return (request.file.audio.first(where: \.isDefault) ?? request.file.audio.first)?.language
    }

    nonisolated static func language(of option: AVMediaSelectionOption) -> String? {
        option.extendedLanguageTag ?? option.locale?.identifier
    }

    /// The system player's own menu changed the subtitle.
    private func selectionChanged(in item: AVPlayerItem?) {
        guard let item, player.currentItem === item else { return }
        Task {
            guard self.subtitlesChosen, self.player.currentItem === item,
                let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            else { return }
            let current = item.currentMediaSelection.selectedMediaOption(in: group)
            // What this app chose itself.
            guard current != self.selectedStreamSubtitle else { return }
            self.selectedStreamSubtitle = current
            if let current {
                self.viewerPick = .native(
                    language: Self.language(of: current), isForced: current.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
                if self.selectedSubtitleID != nil { self.showDrawnSubtitle(nil) }
                if self.subtitleOffsetMs != 0 { self.drawInsteadOfNative() }
            } else if self.selectedSubtitleID == nil {
                self.viewerPick = .off
            }
        }
    }

    /// The player's own subtitles cannot be moved in time. The same subtitle from the server,
    /// drawn by the app, can.
    private func drawInsteadOfNative() {
        guard let native = selectedStreamSubtitle else { return }
        let language = Self.language(of: native)
        let isForced = native.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
        let tracks = request.file.subtitles.filter(\.isText)
        guard let track = tracks.first(where: { track in
            track.isForced == isForced && SubtitleLanguage.base(track.language) == SubtitleLanguage.base(language)
        }) else { return }
        if !subtitleOptions.contains(where: { $0.id == track.id }) {
            let position = (tracks.firstIndex(of: track) ?? 0) + 1
            subtitleOptions.append(SubtitleOption(
                id: track.id,
                label: SubtitleOption.label(language: track.language, title: track.title, isForced: track.isForced, position: position),
                source: .server(assetID: request.file.assetId, track: track), language: track.language, isForced: track.isForced))
        }
        showDrawnSubtitle(track.id)
    }

    /// How the player draws its own subtitles: the size, and a dark box or a shadow.
    nonisolated static func textStyleRules(for style: SubtitlePreferences) -> [AVTextStyleRule] {
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_RelativeFontSize as String: style.size == .small ? 80 : style.size == .large ? 130 : 100
        ]
        if style.background {
            attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] = [0.7, 0, 0, 0]
        } else {
            attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] = [0.0, 0.0, 0.0, 0.0]
            attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] = kCMTextMarkupCharacterEdgeStyle_DropShadow as String
        }
        return AVTextStyleRule(textMarkupAttributes: attributes).map { [$0] } ?? []
    }

    // MARK: Subtitle timing

    /// Moves the subtitles against the picture: positive is later. Kept for this title and viewer.
    func moveSubtitles(byMs delta: Int) {
        touched()
        setSubtitleOffset(subtitleOffsetMs + delta)
    }

    func resetSubtitleTiming() {
        setSubtitleOffset(0)
    }

    private func setSubtitleOffset(_ value: Int) {
        let value = max(-Self.mostSubtitleOffsetMs, min(Self.mostSubtitleOffsetMs, value))
        guard value != subtitleOffsetMs else { return }
        subtitleOffsetMs = value
        if value != 0 { drawInsteadOfNative() }
        showCue()
        // Sent once the viewer stops pressing. Out of reach it is kept for this time only.
        offsetSave?.cancel()
        let client = client
        let profileID = profileID
        let itemID = request.item.id
        offsetSave = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            try? await client.setSubtitleOffset(value, profileID: profileID, itemID: itemID)
        }
    }

    private static let mostSubtitleOffsetMs = 600_000

    /// What the viewer left the timing of this title at, the first time it plays this session.
    private func loadSubtitleOffset(itemID: String) {
        guard offsetLoadedFor != itemID else { return }
        offsetLoadedFor = itemID
        let client = client
        let profileID = profileID
        Task { [weak self] in
            // Out of reach (a download, on a plane): in time, as it comes.
            guard let offset = try? await client.subtitleOffset(profileID: profileID, itemID: itemID),
                let self, self.request.item.id == itemID, offset != self.subtitleOffsetMs
            else { return }
            self.subtitleOffsetMs = max(-Self.mostSubtitleOffsetMs, min(Self.mostSubtitleOffsetMs, offset))
            if offset != 0 { self.drawInsteadOfNative() }
            self.showCue()
        }
    }

    /// Chooses a sound track of the stream, from the app's own transport.
    func selectAudio(_ option: AVMediaSelectionOption) {
        touched()
        guard let item = player.currentItem else { return }
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
            item.select(option, in: group)
            self.selectedAudio = option
        }
    }

    /// The viewer chooses a subtitle the stream itself carries, or none.
    func selectStreamSubtitle(_ option: AVMediaSelectionOption?) {
        touched()
        if let option {
            viewerPick = .native(language: Self.language(of: option), isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
        } else {
            viewerPick = selectedSubtitleID.map { .drawn(id: $0) } ?? .off
        }
        showStreamSubtitle(option)
    }

    /// The viewer chooses one of the subtitles the app draws itself, or none.
    func selectSubtitle(_ id: String?) {
        touched()
        if let id {
            viewerPick = .drawn(id: id)
        } else if let native = selectedStreamSubtitle {
            viewerPick = .native(language: Self.language(of: native), isForced: native.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
        } else {
            viewerPick = .off
        }
        showDrawnSubtitle(id)
    }

    private func showStreamSubtitle(_ option: AVMediaSelectionOption?) {
        guard let item = player.currentItem else { return }
        if option != nil { showDrawnSubtitle(nil) }
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            item.select(option, in: group)
            self.selectedStreamSubtitle = option
            if option != nil, self.subtitleOffsetMs != 0 { self.drawInsteadOfNative() }
        }
    }

    private func showDrawnSubtitle(_ id: String?) {
        subtitleLoad?.cancel()
        selectedSubtitleID = id
        subtitleCues = nil
        subtitlePictures = nil
        subtitlePicture = nil
        subtitleText = nil
        subtitleProblem = nil
        if let subtitleObserver { player.removeTimeObserver(subtitleObserver) }
        subtitleObserver = nil
        guard let id, let option = subtitleOptions.first(where: { $0.id == id }), let app else { return }

        // Not two subtitles at once: the stream's own goes off.
        if selectedStreamSubtitle != nil { showStreamSubtitle(nil) }

        let loader = SubtitleLoader(client: client, downloads: app.environment.downloads, sleep: app.environment.sleep)
        subtitleLoad = Task { [weak self] in
            let outcome = await loader.load(option) {
                self?.preparing != nil
            } waiting: {
                guard self?.selectedSubtitleID == id else { return }
                if case .server(_, let track) = option.source, track.isPicture {
                    self?.subtitleProblem = "Lobby Server is reading these subtitles. They will appear in a moment."
                } else {
                    self?.subtitleProblem = "These subtitles will appear when Lobby Server has finished preparing this film."
                }
            }
            guard let self, !Task.isCancelled, self.selectedSubtitleID == id else { return }
            switch outcome {
            case .cues(let cues): self.subtitleCues = cues
            case .pictures(let pictures): self.subtitlePictures = pictures
            case .failed:
                self.subtitleProblem = "These subtitles could not be loaded."
                return
            }
            self.subtitleProblem = nil
            self.showCue()
            // Often enough for a line to appear when it is spoken.
            self.subtitleObserver = self.player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 10), queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.showCue() }
            }
        }
    }

    private func showCue() {
        guard let positionMs else { return }
        // Moved later, a line comes when the film is further on.
        let at = positionMs + fileOffsetMs - subtitleOffsetMs
        if let subtitleCues {
            let text = subtitleCues.text(atMs: at)
            if text != subtitleText { subtitleText = text }
        }
        if let subtitlePictures {
            let cue = subtitlePictures.cue(atMs: at)
            if cue != subtitlePicture?.cue {
                subtitlePicture = cue.map { ($0, subtitlePictures.width, subtitlePictures.height) }
            }
        }
    }
}

// MARK: Playing on another device

extension PlayerModel {
    /// The app model, for the views the platform's player draws on top.
    var appModel: AppModel? { app }

    /// Where it is in the film or episode now. nil before the player knows.
    var currentPositionMs: Int? { positionMs }

    /// What this player does, as the live channel says it to the others.
    func remoteReport(profileID: String?) -> PlayerReport {
        let status: RemotePlayerStatus
        switch stage {
        case .loading, .preparing: status = .loading
        case .ended: status = .ended
        case .failed: status = .error
        case .playing:
            if !hasStarted {
                status = .loading
            } else if isWaiting {
                status = .buffering
            } else {
                status = player.timeControlStatus == .paused ? .paused : .playing
            }
        }
        let file = request.file
        let audio = file.audio.enumerated().map { position, track in
            RemoteTrack(
                id: String(track.index),
                label: String(Self.audioLabel(track, position: position + 1).prefix(80)),
                language: track.language)
        }
        var audioID: String?
        if let selectedAudio, let position = audioChoices.firstIndex(of: selectedAudio), position < file.audio.count {
            audioID = String(file.audio[position].index)
        } else {
            audioID = (file.audio.first(where: \.isDefault) ?? file.audio.first).map { String($0.index) }
        }
        let texts = isForKids ? [] : file.subtitles.filter(\.isText)
        let subtitles = texts.enumerated().map { position, track in
            RemoteTrack(
                id: track.id,
                label: String(SubtitleOption.label(language: track.language, title: track.title, isForced: track.isForced, position: position + 1).prefix(80)),
                language: track.language)
        }
        var subtitleID = selectedSubtitleID
        if subtitleID == nil, let chosen = selectedStreamSubtitle {
            let language = chosen.extendedLanguageTag ?? chosen.locale?.identifier
            subtitleID = texts.first { track in
                guard let language, let own = track.language else { return false }
                return Self.sameLanguage(own, language)
            }?.id
        }
        let position = hasStarted ? (positionMs ?? request.startPositionMs) : (pendingStartMs.map { $0 - fileOffsetMs } ?? request.startPositionMs)
        return PlayerReport(
            itemId: request.item.id, assetId: file.assetId, profileId: profileID, status: status,
            positionMs: max(0, position), ageMs: 0, durationMs: request.durationMs ?? recorder?.durationMs, rate: 1,
            audioTracks: Array(audio.prefix(32)), audioTrackId: audioID, subtitleTracks: Array(subtitles.prefix(32)),
            subtitleTrackId: subtitleID, volume: nil, nextItemId: upNext?.item.id, queue: [], upNext: remoteUpNext)
    }

    /// What the end screen shows, for the device that controls this one.
    private var remoteUpNext: RemoteUpNext? {
        guard let ending else { return nil }
        let countdownMs = countdown.map { $0.remaining * 1000 }
        switch ending {
        case .nextEpisode:
            return RemoteUpNext(kind: .episode, itemId: upNext?.item.id, countdownMs: countdownMs)
        case .suggestions:
            let ids = suggestions.prefix(20).map(\.request.item.id)
            return RemoteUpNext(kind: .suggestions, itemId: countdown == nil ? nil : ids.first, countdownMs: countdownMs, suggestions: Array(ids))
        case .stillWatching:
            return RemoteUpNext(kind: .stillWatching, itemId: upNext?.item.id ?? suggestions.first?.request.item.id, countdownMs: nil)
        }
    }

    static func audioLabel(_ track: AudioTrack, position: Int) -> String {
        let name: String
        if let title = track.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            name = title
        } else if let language = track.language, let display = Locale.current.localizedString(forLanguageCode: language) {
            name = display.prefix(1).uppercased() + display.dropFirst()
        } else {
            name = "Sound \(position)"
        }
        guard let channels = track.channels, channels > 2 else { return name }
        return channels == 6 ? "\(name) 5.1" : channels == 8 ? "\(name) 7.1" : name
    }

    /// "nld" and "nl-NL", "eng" and "en": the same language.
    static func sameLanguage(_ a: String, _ b: String) -> Bool {
        func code(_ text: String) -> String {
            let base = text.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? text.lowercased()
            return Locale.LanguageCode(base).identifier(.alpha2) ?? base
        }
        return code(a) == code(b)
    }

    func remotePause() {
        touched()
        pauseByItself()
    }

    func remoteResume() {
        guard stage == .playing else { return }
        touched()
        if hasStarted { playByItself() }
    }

    /// Moves to a place in the film or episode.
    func remoteSeek(toMs target: Int) {
        touched()
        let target = max(0, target)
        guard hasStarted else {
            pendingStartMs = target + fileOffsetMs
            return
        }
        if preparing != nil {
            seek(toMs: target + fileOffsetMs)
            return
        }
        var limit = Int.max
        if let duration = request.durationMs ?? recorder?.durationMs { limit = max(0, duration - 500) }
        let time = CMTime(value: CMTimeValue(min(target, limit) + fileOffsetMs), timescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
    }

    func remoteSkip(byMs delta: Int) {
        remoteSeek(toMs: (positionMs ?? request.startPositionMs) + delta)
    }

    /// A sound track by its id on every device (`AudioTrack.index`). False when there is none.
    func selectRemoteAudio(_ id: String) -> Bool {
        guard let position = request.file.audio.firstIndex(where: { String($0.index) == id }) else { return false }
        if position < audioChoices.count {
            selectAudio(audioChoices[position])
        }
        return true
    }

    /// A subtitle by its id on every device, or none. False when this player has no such one.
    func selectRemoteSubtitle(_ id: String?) -> Bool {
        guard let id, id != PlayCommand.subtitlesOff else {
            selectSubtitle(nil)
            selectStreamSubtitle(nil)
            return true
        }
        if subtitleOptions.contains(where: { $0.id == id }) {
            selectSubtitle(id)
            return true
        }
        guard let track = request.file.subtitles.first(where: { $0.id == id }), let language = track.language,
            let option = streamSubtitleChoices.first(where: { option in
                (option.extendedLanguageTag ?? option.locale?.identifier).map { Self.sameLanguage($0, language) } ?? false
            })
        else { return false }
        selectStreamSubtitle(option)
        return true
    }

    /// What another device chose with `play`: applied once the film has started.
    func takeRemoteChoices(audioTrackID: String?, subtitleTrackID: String?, paused: Bool) {
        guard audioTrackID != nil || subtitleTrackID != nil || paused else { return }
        Task { [weak self] in
            for _ in 0..<300 {
                guard let self, !Task.isCancelled else { return }
                if self.hasStarted, !self.audioChoices.isEmpty || self.request.file.audio.count < 2 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self else { return }
            if let audioTrackID { _ = self.selectRemoteAudio(audioTrackID) }
            if let subtitleTrackID { _ = self.selectRemoteSubtitle(subtitleTrackID) }
            if paused { self.pauseByItself() }
        }
    }

    // MARK: AirPlay

    /// AirPlay began or ended. A film from the server is opened again under a pass where it is,
    /// because the receiver fetches it itself and gets neither the header nor the cookie.
    fileprivate func externalPlaybackChanged(_ active: Bool) {
        isOnAirPlay = active
        app?.remote.changed()
        guard active, stream != nil, mayUseAirPlayPass, airPlayPass?.assetId != request.file.assetId, !isClosed else { return }
        var again = request
        if hasStarted, let positionMs { again.startPositionMs = positionMs }
        let wasPlaying = !hasStarted || player.timeControlStatus != .paused
        loadTask?.cancel()
        loadTask = Task {
            await self.fetchAirPlayPass(for: again.file.assetId)
            guard self.airPlayPass != nil, !self.isClosed else { return }
            self.stopObserving()
            await self.load(again)
            if !wasPlaying, !self.isClosed { self.pauseByItself() }
        }
    }

    fileprivate func fetchAirPlayPass(for assetID: String) async {
        do {
            airPlayPass = try await client.airPlayPass(assetID: assetID)
        } catch {
            // An older server has none: AirPlay then gets what it gets.
            airPlayPass = nil
        }
    }
}
