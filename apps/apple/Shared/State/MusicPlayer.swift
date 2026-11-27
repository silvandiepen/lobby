// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import CoreGraphics
import Foundation
import LobbyKit
import MediaPlayer
import Observation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Plays the queue: one `AVQueuePlayer` with what plays and what comes next, so that an album
/// runs on without a gap where the files allow it. It keeps on with the screen off or the app
/// behind another one (the `audio` background mode), and answers the lock screen, Control
/// Center, headphones and the Mac's media keys.
///
/// The queue's rules are `MusicQueue`'s; this follows them with sound.
@MainActor
@Observable
final class MusicPlayer {
    enum SleepTimer: Equatable {
        /// Stops at this moment.
        case at(Date)
        /// Stops when the song, or the book's chapter, ends.
        case endOfTrack
    }

    /// The speeds a book can be read at.
    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    private(set) var queue = MusicQueue()
    private(set) var isPlaying = false
    /// Waiting for the first sound of a file.
    private(set) var isLoading = false
    /// Seconds into the file that plays.
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    /// The book the queue is, when it is one.
    private(set) var book: MusicBook?
    private(set) var rate: Float = 1
    private(set) var sleepTimer: SleepTimer?
    /// What plays comes from a download on this device, not from the server.
    private(set) var isPlayingFromDevice = false
    /// A sentence for the listener: a file that could not be played.
    var problem: String?
    /// The full player is open.
    var showsNowPlaying = false

    @ObservationIgnored private unowned let music: MusicModel
    @ObservationIgnored private let player = AVQueuePlayer()
    /// Which queue entry each item in the player is.
    @ObservationIgnored private var entryOfItem: [ObjectIdentifier: String] = [:]
    /// Rises with every new start, so that a slow answer for an older one is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var notifications: [any NSObjectProtocol] = []
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artwork: (coverID: String, image: CGImage)?
    @ObservationIgnored private var lastSavedBookMs: Int?
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var commandsReady = false
    /// What has been heard of the entry that plays.
    @ObservationIgnored private var listen: (entryID: String, trackID: String, startedAt: Date, listenedMs: Double, lastElapsed: Double)?

    init(music: MusicModel) {
        self.music = music
        player.actionAtItemEnd = .advance
        player.isMuted = AppLaunch.isMuted
        // AirPlay to a speaker or a TV.
        player.allowsExternalPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        itemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.currentItemChanged() }
        }
        notifications.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as? AVPlayerItem
            let id = item.map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.itemEnded(id) }
        })
        notifications.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.object as? AVPlayerItem).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.itemFailed(id) }
        })
        #if os(iOS) || os(tvOS)
        notifications.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated { self?.interrupted(type, options: options ?? []) }
        })
        notifications.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated { self?.routeChanged(reason) }
        })
        #endif
    }

    // MARK: What is on

    /// There is something to show in the mini player.
    var isActive: Bool { queue.current != nil }

    var currentTrack: MusicTrack? { queue.current.flatMap { music.track($0.trackID) } }

    /// The cover of what plays.
    var currentCoverID: String? { currentTrack.flatMap { music.wholeCatalogue.coverID(of: $0) } }

    /// The album or book of what plays.
    var currentCollection: String? { currentTrack.flatMap { music.wholeCatalogue.collectionTitle(of: $0) } }

    /// Where in the book it is, on the book's line of time.
    var bookPositionMs: Int? {
        guard let book, let track = currentTrack else { return nil }
        return book.bookMs(trackID: track.id, trackMs: Int(elapsed * 1000))
    }

    var currentChapterIndex: Int? { bookPositionMs.flatMap { book?.chapterIndex(atBookMs: $0) } }

    var upNext: [(entry: MusicQueue.Entry, track: MusicTrack)] {
        queue.upNext.compactMap { entry in music.track(entry.trackID).map { (entry, $0) } }
    }

    // MARK: Starting

    /// Plays these tracks from `index`, in order or shuffled. Replaces the queue.
    func play(trackIDs: [String], startAt index: Int = 0, shuffled: Bool = false) {
        guard !trackIDs.isEmpty else { return }
        finishListen(reachedEnd: false)
        saveBookPosition()
        book = nil
        setRate(1)
        var queue = MusicQueue(trackIDs: trackIDs, startAt: index, shuffled: shuffled)
        queue.repeatMode = self.queue.repeatMode
        self.queue = queue
        startCurrent(at: 0, playing: true)
    }

    /// Plays a book from where this viewer was, or from the start of a chapter.
    func play(book: MusicBook, chapter: Int? = nil) {
        finishListen(reachedEnd: false)
        saveBookPosition()
        let startMs: Int
        if let chapter, book.chapters.indices.contains(chapter) {
            startMs = book.chapters[chapter].startMs
        } else if let progress = music.bookProgress[book.id], !progress.completed {
            startMs = progress.positionMs
        } else {
            startMs = 0
        }
        let place = book.place(atBookMs: startMs) ?? (0, 0)
        self.book = book
        queue = MusicQueue(trackIDs: book.parts.map(\.trackId), startAt: place.part)
        setRate(music.bookRate)
        startCurrent(at: Double(place.trackMs) / 1000, playing: true)
    }

    func playNext(_ trackIDs: [String]) {
        let wasEmpty = queue.isEmpty
        queue.playNext(trackIDs)
        if wasEmpty { startCurrent(at: 0, playing: true) } else { refreshPreload() }
    }

    func addToQueue(_ trackIDs: [String]) {
        let wasEmpty = queue.isEmpty
        queue.add(trackIDs)
        if wasEmpty { startCurrent(at: 0, playing: true) } else { refreshPreload() }
    }

    // MARK: Controls

    func togglePlay() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard isActive else { return }
        if player.currentItem == nil {
            startCurrent(at: elapsed, playing: true)
            return
        }
        activateSession()
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        saveBookPosition()
        music.flushSoon()
        updateNowPlaying()
    }

    /// The film's player starts: the music makes room.
    func pauseForFilm() {
        if isPlaying { pause() }
    }

    func next() {
        guard isActive else { return }
        if let book, let chapter = currentChapterIndex, chapter + 1 < book.chapters.count {
            return jump(toChapter: chapter + 1)
        }
        finishListen(reachedEnd: false)
        if queue.skipForward() != nil {
            startCurrent(at: 0, playing: true)
        } else {
            endOfQueue()
        }
    }

    /// Back to the start of the song, or to the one before when it just began.
    func previous() {
        guard isActive else { return }
        if let book, let chapter = currentChapterIndex, let position = bookPositionMs {
            let start = book.chapters[chapter].startMs
            return jump(toChapter: position - start > 3_000 || chapter == 0 ? chapter : chapter - 1)
        }
        if elapsed > 3 || queue.history.isEmpty && queue.repeatMode != .all {
            seek(to: 0)
            return
        }
        finishListen(reachedEnd: false)
        queue.skipBack()
        startCurrent(at: 0, playing: isPlaying)
    }

    func jump(to entryID: String) {
        finishListen(reachedEnd: false)
        queue.jump(to: entryID)
        startCurrent(at: 0, playing: true)
    }

    func jump(toChapter index: Int) {
        guard let book, book.chapters.indices.contains(index) else { return }
        let chapter = book.chapters[index]
        seek(trackID: chapter.trackId, seconds: Double(chapter.trackStartMs) / 1000)
    }

    /// Forward or back in a book: by seconds.
    func skip(by seconds: Double) {
        seek(to: max(0, min(duration > 0 ? duration - 0.5 : .infinity, elapsed + seconds)))
    }

    func seek(to seconds: Double) {
        elapsed = seconds
        listen?.lastElapsed = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
        updateNowPlaying()
    }

    /// A place in another file of the queue (a book's chapter).
    private func seek(trackID: String, seconds: Double) {
        if currentTrack?.id == trackID { return seek(to: seconds) }
        guard let entry = queue.entries.first(where: { $0.trackID == trackID }) else { return }
        finishListen(reachedEnd: false)
        queue.jump(to: entry.id)
        startCurrent(at: seconds, playing: true)
    }

    func setShuffled(_ on: Bool) {
        guard book == nil else { return }
        queue.setShuffled(on)
        refreshPreload()
        updateCommands()
    }

    func setRepeat(_ mode: MusicQueue.Repeat) {
        queue.repeatMode = mode
        refreshPreload()
        updateCommands()
    }

    /// The speed of a book. Music plays at its own.
    func setRate(_ rate: Float) {
        self.rate = rate
        player.defaultRate = rate
        if isPlaying { player.rate = rate }
        if book != nil { music.bookRate = rate }
        updateNowPlaying()
    }

    func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.moveUpNext(fromOffsets: source, toOffset: destination)
        refreshPreload()
    }

    func remove(entryID: String) {
        if entryID == queue.current?.id {
            finishListen(reachedEnd: false)
            queue.remove(entryID: entryID)
            queue.current == nil ? stop() : startCurrent(at: 0, playing: isPlaying)
        } else {
            queue.remove(entryID: entryID)
            refreshPreload()
        }
    }

    func clearUpNext() {
        queue.clearUpNext()
        refreshPreload()
    }

    /// Ends it all: the mini player goes.
    func stop() {
        finishListen(reachedEnd: false)
        saveBookPosition()
        generation += 1
        player.pause()
        player.removeAllItems()
        entryOfItem = [:]
        queue = MusicQueue()
        book = nil
        isPlaying = false
        isLoading = false
        elapsed = 0
        duration = 0
        setSleepTimer(nil)
        showsNowPlaying = false
        music.flushSoon()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        nowPlaying = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
        deactivateSession()
    }

    // MARK: Sleep timer

    /// nil: off.
    func setSleepTimer(_ timer: SleepTimer?) {
        sleepTask?.cancel()
        sleepTimer = timer
        if case .at(let moment) = timer {
            sleepTask = Task { [weak self] in
                let wait = moment.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled else { return }
                self?.sleepTimer = nil
                self?.pause()
            }
        }
        refreshPreload()
    }

    func sleep(inMinutes minutes: Int) {
        setSleepTimer(.at(Date().addingTimeInterval(TimeInterval(minutes * 60))))
    }

    // MARK: The player

    /// Loads the queue's current entry into the player, from `seconds`, and plays it if asked.
    private func startCurrent(at seconds: Double, playing: Bool) {
        generation += 1
        let generation = generation
        player.pause()
        player.removeAllItems()
        entryOfItem = [:]
        elapsed = seconds
        guard let entry = queue.current, let track = music.track(entry.trackID) else {
            isPlaying = false
            return
        }
        duration = Double(track.durationMs ?? 0) / 1000
        isLoading = true
        isPlaying = playing
        problem = nil
        if playing { activateSession() }
        updateNowPlaying()
        loadArtwork()
        setUpCommands()
        Task {
            do {
                let item = try await makeItem(for: track)
                guard generation == self.generation else { return }
                entryOfItem[ObjectIdentifier(item)] = entry.id
                isPlayingFromDevice = (item.asset as? AVURLAsset)?.url.isFileURL == true
                player.insert(item, after: nil)
                if seconds > 0 {
                    await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                guard generation == self.generation else { return }
                player.volume = volume(for: track)
                isLoading = false
                startListen(entry, at: seconds)
                if isPlaying {
                    player.defaultRate = rate
                    player.play()
                }
                updateNowPlaying()
                refreshPreload()
            } catch is CancellationError {
            } catch {
                guard generation == self.generation else { return }
                isLoading = false
                problem = "“\(track.title)” could not be played. \((error as? LobbyError)?.localizedDescription ?? error.localizedDescription)"
                // On to the next one, as a player does with a scratched disc.
                if queue.following(automatic: false) != nil, queue.upNext.count > 0 {
                    queue.skipForward()
                    startCurrent(at: 0, playing: isPlaying)
                } else {
                    isPlaying = false
                    updateNowPlaying()
                }
            }
        }
    }

    /// Puts what comes next into the player behind what plays, so it starts without a gap.
    /// Not with repeat one, a timer at the end of the song, or the round of a shuffled queue.
    private func refreshPreload() {
        let items = player.items()
        guard let current = items.first else { return }
        for item in items.dropFirst() {
            player.remove(item)
            entryOfItem[ObjectIdentifier(item)] = nil
        }
        guard queue.repeatMode != .one, sleepTimer != .endOfTrack,
            let next = queue.upNext.first ?? (queue.repeatMode == .all && !queue.isShuffled ? queue.entries.first : nil),
            next.id != queue.current?.id,
            let track = music.track(next.trackID)
        else { return }
        let generation = generation
        Task {
            guard let item = try? await makeItem(for: track) else { return }
            // Still what plays, still what comes next.
            guard generation == self.generation, player.items().count == 1, player.items().first === current,
                (queue.upNext.first ?? queue.entries.first)?.id == next.id
            else { return }
            entryOfItem[ObjectIdentifier(item)] = next.id
            player.insert(item, after: current)
        }
    }

    private func makeItem(for track: MusicTrack) async throws -> AVPlayerItem {
        let asset: AVURLAsset
        if let file = await music.localFile(trackID: track.id) {
            asset = AVURLAsset(url: file)
        } else {
            guard let client = music.client else { throw LobbyError.unreachable(.notConnectedToInternet) }
            let source = try await music.streamURL(for: track, using: client)
            let cookie = client.deviceCookie()
            asset = AVURLAsset(url: source, options: cookie.map { [AVURLAssetHTTPCookiesKey: [$0]] })
        }
        let item = AVPlayerItem(asset: asset)
        // A book keeps its words clear at another speed.
        item.audioTimePitchAlgorithm = .timeDomain
        item.preferredForwardBufferDuration = 30
        return item
    }

    private func volume(for track: MusicTrack) -> Float {
        guard music.matchesVolume else { return 1 }
        // A whole album in its order: its own loud and quiet parts stay.
        let inAlbumOrder = !queue.isShuffled && track.albumId != nil
            && queue.upNext.first.flatMap { music.track($0.trackID)?.albumId } == track.albumId
        return VolumeMatching.volume(for: track.replayGain, preferAlbum: inAlbumOrder)
    }

    private func tick(_ seconds: Double) {
        guard player.currentItem != nil, seconds.isFinite else { return }
        if let item = player.currentItem, item.duration.isNumeric {
            duration = item.duration.seconds
        }
        let wasElapsed = elapsed
        elapsed = seconds
        if var listen, isPlaying {
            let delta = seconds - listen.lastElapsed
            if delta > 0, delta < 3 { listen.listenedMs += delta * 1000 }
            listen.lastElapsed = seconds
            self.listen = listen
        }
        // A book's position is kept every quarter of a minute while it plays.
        if let position = bookPositionMs, abs(position - (lastSavedBookMs ?? -60_000)) >= 15_000 {
            saveBookPosition()
        }
        // The end of a chapter, for the sleep timer.
        if sleepTimer == .endOfTrack, let book, let chapter = currentChapterIndex, let position = bookPositionMs,
            book.chapters[chapter].endMs - position < 400, Int(wasElapsed * 1000) < Int(seconds * 1000) {
            sleepTimer = nil
            pause()
        }
        if Int(wasElapsed) != Int(seconds) { updateNowPlaying() }
    }

    /// The player went on to the item behind: the queue goes with it.
    private func currentItemChanged() {
        guard let item = player.currentItem, let entryID = entryOfItem[ObjectIdentifier(item)],
            entryID != queue.current?.id
        else { return }
        finishListen(reachedEnd: true)
        queue.advance()
        if queue.current?.id != entryID { queue.jump(to: entryID) }
        elapsed = 0
        if let track = currentTrack {
            duration = Double(track.durationMs ?? 0) / 1000
            player.volume = volume(for: track)
        }
        isPlayingFromDevice = (item.asset as? AVURLAsset)?.url.isFileURL == true
        startListen(queue.current, at: 0)
        loadArtwork()
        updateNowPlaying()
        refreshPreload()
    }

    private func itemEnded(_ id: ObjectIdentifier?) {
        guard let id, let entryID = entryOfItem[id], entryID == queue.current?.id else { return }
        if queue.repeatMode == .one, book == nil {
            // The player let go of the item at its end: the same one again, from the start.
            finishListen(reachedEnd: true)
            startCurrent(at: 0, playing: true)
            return
        }
        if sleepTimer == .endOfTrack {
            sleepTimer = nil
            finishListen(reachedEnd: true)
            if queue.advance() != nil {
                startCurrent(at: 0, playing: false)
            } else {
                endOfQueue()
            }
            return
        }
        // The item behind takes over by itself (`currentItemChanged`).
        if player.items().count > 1 { return }
        finishListen(reachedEnd: true)
        if queue.advance() != nil {
            startCurrent(at: 0, playing: true)
        } else {
            endOfQueue()
        }
    }

    private func itemFailed(_ id: ObjectIdentifier?) {
        guard let id, entryOfItem[id] == queue.current?.id, let track = currentTrack else { return }
        problem = "“\(track.title)” stopped playing. The connection to Lobby Server may have dropped."
        isPlaying = false
        updateNowPlaying()
    }

    /// The last one ended: it stays in the mini player, at its start, paused.
    private func endOfQueue() {
        if book != nil {
            saveBookPosition(completed: true)
        }
        if queue.current == nil { queue.skipBack() }
        isPlaying = false
        startCurrent(at: 0, playing: false)
        music.flushSoon()
    }

    // MARK: Listens and books

    private func startListen(_ entry: MusicQueue.Entry?, at seconds: Double) {
        guard let entry else {
            listen = nil
            return
        }
        listen = (entry.id, entry.trackID, Date(), 0, seconds)
    }

    /// A listen that ends counts as a play, as `MusicPlay.judge` says.
    private func finishListen(reachedEnd: Bool) {
        guard let current = listen else { return }
        listen = nil
        let track = music.track(current.trackID)
        guard let completed = MusicPlay.judge(
            listenedMs: Int(current.listenedMs), durationMs: track?.durationMs, reachedEnd: reachedEnd)
        else { return }
        music.recordPlay(MusicPlay(
            trackId: current.trackID, playedAt: current.startedAt, playedMs: Int(current.listenedMs), completed: completed))
        saveBookPosition()
    }

    private func saveBookPosition(completed: Bool = false) {
        guard let book, let position = bookPositionMs else { return }
        lastSavedBookMs = position
        let done = completed || book.durationMs - position < 5_000
        music.recordBookProgress(bookID: book.id, positionMs: done ? book.durationMs : position, durationMs: book.durationMs, completed: done)
    }

    // MARK: Lock screen, Control Center, headphones

    /// What the lock screen shows now. nil when nothing is on.
    private(set) var nowPlaying: NowPlayingDescription?

    private func updateNowPlaying() {
        guard let track = currentTrack else { return }
        let description = NowPlayingDescription(
            title: chapterTitle ?? track.title,
            artist: book.map { $0.authors.joined(separator: ", ") } ?? track.artistCredit,
            collection: currentCollection,
            durationSeconds: duration > 0 ? duration : nil,
            elapsedSeconds: elapsed,
            rate: isPlaying && !isLoading ? Double(rate) : 0,
            defaultRate: Double(rate),
            queueIndex: queue.index,
            queueCount: queue.entries.count,
            isBook: book != nil,
            chapter: currentChapterIndex.flatMap { index in book.map { (index, $0.chapters.count) } })
        nowPlaying = description
        var info = description.info
        if let artwork, artwork.coverID == currentCoverID {
            info[MPMediaItemPropertyArtwork] = Self.mediaArtwork(artwork.image)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }

    /// In a book, the chapter is what the lock screen names.
    private var chapterTitle: String? {
        guard let book, let index = currentChapterIndex else { return nil }
        return book.chapters[index].title.map { "\($0) · \(book.title)" }
    }

    private func loadArtwork() {
        guard let coverID = currentCoverID, artwork?.coverID != coverID else { return }
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let image = await self?.music.coverImage(coverID, pixelWidth: 600) else { return }
            guard !Task.isCancelled else { return }
            self?.artwork = (coverID, image)
            self?.updateNowPlaying()
        }
    }

    private nonisolated static func mediaArtwork(_ image: CGImage) -> MPMediaItemArtwork {
        let size = CGSize(width: image.width, height: image.height)
        return MPMediaItemArtwork(boundsSize: size) { _ in
            #if canImport(UIKit)
            UIImage(cgImage: image)
            #else
            NSImage(cgImage: image, size: size)
            #endif
        }
    }

    private func setUpCommands() {
        guard !commandsReady else { return updateCommands() }
        commandsReady = true
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.addTarget { event in
                MainActor.assumeIsolated { action(event) }
            }
        }
        on(center.playCommand) { [weak self] _ in self?.resume(); return .success }
        on(center.pauseCommand) { [weak self] _ in self?.pause(); return .success }
        on(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePlay(); return .success }
        on(center.stopCommand) { [weak self] _ in self?.pause(); return .success }
        on(center.nextTrackCommand) { [weak self] _ in self?.next(); return .success }
        on(center.previousTrackCommand) { [weak self] _ in self?.previous(); return .success }
        on(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.preferredIntervals = [15]
        on(center.skipForwardCommand) { [weak self] _ in self?.skip(by: 30); return .success }
        on(center.skipBackwardCommand) { [weak self] _ in self?.skip(by: -15); return .success }
        on(center.changeRepeatModeCommand) { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: MusicQueue.Repeat = switch event.repeatType {
            case .one: .one
            case .all: .all
            default: .off
            }
            self?.setRepeat(mode)
            return .success
        }
        on(center.changeShuffleModeCommand) { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            self?.setShuffled(event.shuffleType != .off)
            return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = Self.rates.map { NSNumber(value: $0) }
        on(center.changePlaybackRateCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            self?.setRate(event.playbackRate)
            return .success
        }
        updateCommands()
    }

    /// A book skips by seconds; music by songs.
    private func updateCommands() {
        let center = MPRemoteCommandCenter.shared()
        let isBook = book != nil
        center.skipForwardCommand.isEnabled = isBook
        center.skipBackwardCommand.isEnabled = isBook
        center.changePlaybackRateCommand.isEnabled = isBook
        center.changeShuffleModeCommand.isEnabled = !isBook
        center.changeRepeatModeCommand.isEnabled = !isBook
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changeRepeatModeCommand.currentRepeatType = switch queue.repeatMode {
        case .off: .off
        case .all: .all
        case .one: .one
        }
        center.changeShuffleModeCommand.currentShuffleType = queue.isShuffled ? .items : .off
    }

    // MARK: The audio session

    private func activateSession() {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        // Long-form audio: it goes on with the screen locked, to AirPlay speakers as music does.
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(true)
        #endif
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    #if os(iOS) || os(tvOS)
    /// A call, Siri, an alarm: the system paused it; it goes on afterwards when the system says so.
    private func interrupted(_ type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                isPlaying = false
                saveBookPosition()
                updateNowPlaying()
            }
        case .ended:
            if wasPlayingBeforeInterruption, options.contains(.shouldResume) { resume() }
            wasPlayingBeforeInterruption = false
        default:
            break
        }
    }

    /// Headphones pulled out: it stops, as people expect, instead of playing out loud.
    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        if reason == .oldDeviceUnavailable, isPlaying {
            pause()
        }
    }
    #endif
}
