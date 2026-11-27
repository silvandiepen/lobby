// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Observation

/// Playing on another device (docs/api.md, "Playing on another device"): this
/// device's side of the live channel.
///
/// It says what this device does, does what others ask of it, and shows what the household's
/// other devices play so that this one can start something there and control it. Everything goes
/// through the server. One per app, owned by `AppModel`.
@MainActor
@Observable
final class RemoteModel {
    /// What this device can be asked to do. No volume: an app cannot set a TV's own.
    nonisolated static let capabilities = ["play", "pause", "resume", "seek", "skip", "next", "stop", "setAudio", "setSubtitle", "upNext"]
    /// How often this device says it is there, and how often it looks whether what plays changed.
    nonisolated static let beat: Duration = .seconds(5)
    nonisolated static let look: Duration = .seconds(1)
    /// How long a command waits for its result.
    nonisolated static let resultWait: Duration = .seconds(12)
    /// How long the others stay on screen after this device lost the channel.
    nonisolated static let keepAfterLoss: Duration = .seconds(12)

    weak var app: AppModel?

    /// The id of this run of the app: one channel per server for as long as it runs.
    let session = UUID().uuidString.lowercased()

    /// The household's devices this one sees, itself included, as the channel last said.
    private(set) var devices: [ShownDevice] = []
    /// The channel is open and said hello.
    private(set) var isConnected = false
    /// "Played from Alex's iPhone", for a moment after another device started something here.
    private(set) var toast: String?
    /// The viewers kids televisions belong to, as a manager can know it. By device id.
    private(set) var boundViewers: [String: String] = [:]

    /// The app is in front. Set by the scene.
    var isForeground = true {
        didSet { if isForeground != oldValue { changed() } }
    }

    private var clock = ServerClock()
    private var order = 0
    private var lastReport: PlayerReport?
    private var lastReportAtMs: Double = 0
    private var lastPostAtMs: Double = 0
    private var isAnnouncing = false
    private var announceAgain = false
    private var needsFull = true
    private var waiting: [String: CheckedContinuation<RemoteOutcome, Never>] = [:]
    /// Plays the server keeps for a TV it wakes, by the play's id: the TV's id, and what to say on
    /// the way.
    private var wakePlays: [String: (deviceID: String, step: @MainActor (WakeStep) -> Void)] = [:]
    /// Commands for this device that were answered, by id, with their answer.
    private var answered: [String: CommandOutcome] = [:]
    private var queue: [IncomingCommand] = []
    private var isWorking = false
    /// A handover took what played here: kept paused until the server says how it went
    /// (`stop` ends it, `resume` takes it up again).
    private var yielded: String?
    private var channel: Task<Void, Never>?
    private var reopen = false
    private var forgetting: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    nonisolated init() {}

    // MARK: What the screens read

    /// Where to play: every other device, open ones first.
    var targets: [ShownDevice] {
        guard showsRemote else { return [] }
        return RemoteTargets.ordered(devices)
    }

    /// What another device plays that this one sees, the one to show first first.
    var nowPlaying: [ShownDevice] {
        guard showsRemote else { return [] }
        return RemoteTargets.nowPlaying(devices)
    }

    /// The names the screens use, with numbers where two are the same.
    var names: [String: String] { RemoteTargets.names(of: devices.filter { !$0.isSelf }) }

    func name(of device: ShownDevice) -> String { names[device.id] ?? device.name }

    /// Only for grown-ups: a kids device controls nothing but itself, and the kids screens have
    /// no remote.
    var showsRemote: Bool {
        guard let app else { return false }
        return !app.isBoundToKids && !app.showsKidsScreens && app.phase == .library
    }

    /// Kids mode on a phone, a tablet or a Mac: Play on TV (docs/decisions.md, "Kids mode plays on the TV"). The server shows TVs only while
    /// this device may control others, and to a child only those it may play on.
    var showsKidsRemote: Bool {
        #if os(tvOS)
        false
        #else
        guard let app else { return false }
        return app.isKidsMode && app.phase == .library
        #endif
    }

    /// The TVs the kids screens can play on now.
    var kidsTargets: [ShownDevice] {
        guard showsKidsRemote, let app else { return [] }
        return RemoteTargets.forKids(devices, atHome: app.road == .home)
    }

    /// The TV that plays the child's own film, while there is one.
    var kidsPlaying: ShownDevice? {
        guard showsKidsRemote else { return nil }
        return RemoteTargets.kidsPlaying(devices)
    }

    func device(_ id: String) -> ShownDevice? { devices.first { $0.id == id } }

    /// This device as the channel shows it.
    var me: ShownDevice? { devices.first { $0.isSelf } }

    /// Where a film on another device is now, by the server's clock.
    func positionMs(of state: RemotePlayerState) -> Int {
        state.positionMs(atServerTime: clock.serverNow(steadyMs: SteadyClock.nowMs()) ?? state.at)
    }

    /// How long until what another device shows at the end starts by itself. nil: it waits.
    func upNextRemainingMs(of state: RemotePlayerState) -> Int? {
        state.upNextRemainingMs(atServerTime: clock.serverNow(steadyMs: SteadyClock.nowMs()) ?? state.at)
    }

    // MARK: The channel

    /// Runs for as long as the app does: keeps the channel open while there is a server to talk
    /// to, and opens it again at another address when the app moves there.
    func run() async {
        while !Task.isCancelled {
            guard let app, let client = app.liveClient, app.phase == .library || app.phase == .chooseProfile else {
                lose(clearing: true)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                continue
            }
            reopen = false
            let refused = await follow(LiveChannel(client: client, session: session), at: client)
            lose(clearing: false)
            if Task.isCancelled { return }
            // A server without the channel, or one that will not have this device: ask again later.
            do { try await Task.sleep(for: refused ? .seconds(60) : .milliseconds(200)) } catch { return }
        }
    }

    /// Reads one channel until it is refused, the app moves to another address, or the channel
    /// asks to be opened again. Returns true when it was refused.
    private func follow(_ channel: LiveChannel, at client: LobbyClient) async -> Bool {
        let reading = Task { [weak self] () -> Bool in
            for await update in channel.updates() {
                guard let self else { return false }
                if case .refused(let error) = update {
                    self.lose(clearing: true)
                    if error.requiresPairing { await self.app?.credentialLost(error) }
                    return true
                }
                self.take(update)
            }
            return false
        }
        // Moves, a lost server, a session the server does not know any more: a new channel.
        let watching = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.look) } catch { return }
                guard let self, let app = self.app else { return reading.cancel() }
                let now = app.liveClient
                if self.reopen || now?.baseURL != client.baseURL || now?.isCarriedByRoad != client.isCarriedByRoad {
                    return reading.cancel()
                }
                if self.isConnected { await self.tick() }
            }
        }
        let refused = await withTaskCancellationHandler {
            await reading.value
        } onCancel: {
            reading.cancel()
        }
        watching.cancel()
        return refused
    }

    private func take(_ update: LiveChannel.Update) {
        let now = SteadyClock.nowMs()
        switch update {
        case .lost:
            lose(clearing: false)
        case .refused:
            lose(clearing: true)
        case .event(let event):
            switch event {
            case .hello(let hello):
                clock.heard(serverTime: hello.serverTime, atMs: now)
                isConnected = true
                // Woken for a play: it comes in a moment, and who is watching is not asked first.
                app?.heardOfRemotePlay(waiting: hello.pendingPlay == true)
                forgetting?.cancel()
                forgetting = nil
                if !hello.resumed { devices = [] }
                needsFull = true
                changed()
            case .snapshot(let all, let time):
                clock.heard(serverTime: time, atMs: now)
                devices = all
                fetchBoundViewers()
            case .device(let device, let time):
                clock.heard(serverTime: time, atMs: now)
                if let index = devices.firstIndex(where: { $0.id == device.id }) {
                    devices[index] = device
                } else {
                    devices.append(device)
                    fetchBoundViewers()
                }
            case .gone(let id, _):
                devices.removeAll { $0.id == id }
            case .command(let command):
                queue.append(command)
                Task { await work() }
            case .result(let result):
                let outcome: RemoteOutcome = switch result.status {
                case .done: .done
                case .superseded: .superseded
                case .expired: .expired
                default: result.code == "device_offline" ? .offline : .failed(code: result.code)
                }
                waiting.removeValue(forKey: result.commandId)?.resume(returning: outcome)
            case .wake(let progress):
                guard let id = progress.commandId, let play = wakePlays[id] else { break }
                switch progress.step {
                case .profile: play.step(.profileHint)
                case .notOpen: play.step(.notOpen)
                case .unknown: break
                }
            case .heartbeat(let time):
                clock.heard(serverTime: time, atMs: now)
            case .kidsMode, .kidsRequest, .kidsRequestClosed:
                Task { [weak app] in await app?.kidsHeard(event) }
            case .unknown:
                break
            }
        }
    }

    /// The channel is gone. What the others do stays on screen a little longer: the next
    /// connection usually comes within a second.
    private func lose(clearing: Bool) {
        isConnected = false
        if clearing {
            forgetting?.cancel()
            forgetting = nil
            devices = []
            return
        }
        guard forgetting == nil, !devices.isEmpty else { return }
        forgetting = Task { [weak self] in
            do { try await Task.sleep(for: Self.keepAfterLoss) } catch { return }
            guard let self, !self.isConnected else { return }
            self.devices = []
            self.forgetting = nil
        }
    }

    // MARK: Saying what this device does

    /// Something changed here: say so now rather than at the next look.
    func changed() {
        Task { await announce() }
    }

    /// Every second: say what changed, and at least every five seconds that this device is here.
    private func tick() async {
        let now = SteadyClock.nowMs()
        let report = currentReport()
        if worthSaying(report, now: now) || now - lastPostAtMs >= Double(Self.beat.components.seconds) * 1000 {
            await announce()
        }
    }

    private func currentReport() -> PlayerReport? {
        guard let app, let player = app.player else { return nil }
        return player.remoteReport(profileID: app.activeProfile?.id)
    }

    /// The report differs from what was said by more than the place a playing film reaches by itself.
    private func worthSaying(_ report: PlayerReport?, now: Double) -> Bool {
        guard let report else { return lastReport != nil }
        guard let last = lastReport else { return true }
        if !report.sameApartFromPlace(as: last) { return true }
        let expected = last.expectedPositionMs(afterMs: Int(now - lastReportAtMs))
        return abs(report.positionMs - expected) > 1_000
    }

    /// `POST /v1/live/{session}`, one at a time: what comes meanwhile goes in the next one.
    private func announce() async {
        guard let app, let client = app.liveClient, isConnected else { return }
        if isAnnouncing {
            announceAgain = true
            return
        }
        isAnnouncing = true
        defer { isAnnouncing = false }
        repeat {
            announceAgain = false
            order += 1
            let now = SteadyClock.nowMs()
            let report = currentReport()
            let field: Announcement.PlayerField
            if needsFull || worthSaying(report, now: now) {
                field = report.map { .playing($0) } ?? .nothing
            } else {
                field = .unchanged
            }
            let announcement = Announcement(
                order: order, foreground: isForeground, canPlay: canPlay, profileId: app.activeProfile?.id,
                capabilities: Self.capabilities, player: field)
            do {
                let reply = try await client.announce(announcement, session: session)
                let received = SteadyClock.nowMs()
                clock.measure(serverTime: reply.serverTime, sentMs: now, receivedMs: received)
                lastPostAtMs = received
                if case .unchanged = field {} else {
                    lastReport = report
                    lastReportAtMs = now
                    needsFull = false
                }
            } catch let refusal as RemoteRefusal where refusal.needsChannel {
                reopen = true
                return
            } catch {
                // Said again at the next look.
                return
            }
        } while announceAgain
    }

    /// Whether a title can be started here now.
    private var canPlay: Bool {
        guard let app, isForeground else { return false }
        return app.phase == .library || app.phase == .chooseProfile
    }

    // MARK: Being controlled

    private func work() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        while !queue.isEmpty {
            let command = queue.removeFirst()
            let received = SteadyClock.nowMs()
            // Done already: the same answer again.
            if let known = answered[command.commandId] {
                await answer(known)
                continue
            }
            let outcome: CommandOutcome
            if SteadyClock.nowMs() - received > Double(command.expiresInMs) {
                outcome = CommandOutcome(commandId: command.commandId, status: .failed, code: RemoteFailure.expired)
            } else {
                outcome = await perform(command)
            }
            answered[command.commandId] = outcome
            if answered.count > 200 { answered.removeAll() }
            await answer(outcome)
        }
    }

    private func answer(_ outcome: CommandOutcome) async {
        guard let client = app?.liveClient else { return }
        do {
            try await client.sendResult(outcome, session: session)
        } catch let refusal as RemoteRefusal where refusal.needsChannel {
            reopen = true
        } catch {
            // The sender learns it expired.
        }
    }

    private func perform(_ incoming: IncomingCommand) async -> CommandOutcome {
        let id = incoming.commandId
        func done(_ report: Bool = true) -> CommandOutcome {
            let field: Announcement.PlayerField = report ? (currentReport().map { .playing($0) } ?? .nothing) : .unchanged
            return CommandOutcome(commandId: id, status: .done, player: field)
        }
        func failed(_ code: String) -> CommandOutcome { CommandOutcome(commandId: id, status: .failed, code: code) }
        guard let app else { return failed(RemoteFailure.error) }

        if case .play(let play) = incoming.command {
            yielded = nil
            let problem = await app.playFromRemote(play)
            app.heardOfRemotePlay(waiting: false)
            if let problem { return failed(problem) }
            if let from = incoming.from, from.deviceId != app.device?.id {
                show("Played from \(from.name)")
            }
            changed()
            return done()
        }

        guard let player = app.player else { return failed(RemoteFailure.nothingPlaying) }
        switch incoming.command {
        case .pause:
            player.remotePause()
        case .resume:
            yielded = nil
            player.remoteResume()
        case .stop:
            yielded = nil
            await player.close()
            changed()
            return done()
        case .seek(let position):
            player.remoteSeek(toMs: position)
        case .skip(let delta):
            player.remoteSkip(byMs: delta)
        case .next:
            guard player.upNext != nil else { return failed(RemoteFailure.notFound) }
            player.playNext()
        case .upNext(let action):
            // The answer to what this player shows at the end, from the phone that controls it.
            switch action {
            case .playNow:
                guard player.ending != nil || player.upNext != nil else { return failed(RemoteFailure.notFound) }
                player.playUpNextNow()
            case .cancel:
                guard player.countdown != nil else { return failed(RemoteFailure.notFound) }
                player.cancelUpNext()
            case .continue:
                guard player.ending == .stillWatching else { return failed(RemoteFailure.notFound) }
                player.continueWatching()
            }
        case .setAudio(let track):
            guard player.selectRemoteAudio(track) else { return failed(RemoteFailure.notFound) }
        case .setSubtitle(let track):
            guard player.selectRemoteSubtitle(track) else { return failed(RemoteFailure.notFound) }
        case .yield:
            // First in a handover: stop here, write down where, and say it.
            player.remotePause()
            await player.checkpoint()
            yielded = incoming.handoverId ?? id
        case .setVolume, .handover, .unknown, .play:
            return failed(RemoteFailure.unsupported)
        }
        changed()
        return done()
    }

    private func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.toast = nil
        }
    }

    // MARK: Controlling others

    /// Sends a command and waits for how it went, at most a few seconds.
    func send(_ command: RemoteCommand, to deviceID: String) async -> RemoteOutcome {
        guard let app, let client = app.liveClient, isConnected else { return .unreachable }
        let id = UUID().uuidString.lowercased()
        let request = CommandRequest(id: id, session: session, deviceId: deviceID, command: command)
        return await withCheckedContinuation { (continuation: CheckedContinuation<RemoteOutcome, Never>) in
            // Before it is sent: the result can come before the answer to the post.
            waiting[id] = continuation
            Task {
                do {
                    _ = try await client.sendCommand(request)
                } catch let refusal as RemoteRefusal {
                    if refusal.needsChannel { reopen = true }
                    finish(id, refusal.isDeviceOffline ? .offline : .failed(code: refusal.reason ?? refusal.code))
                    return
                } catch {
                    finish(id, .unreachable)
                    return
                }
                do { try await Task.sleep(for: Self.resultWait) } catch {}
                finish(id, .expired)
            }
        }
    }

    private func finish(_ id: String, _ outcome: RemoteOutcome) {
        waiting.removeValue(forKey: id)?.resume(returning: outcome)
    }

    /// Where a film starts on the other device.
    enum Start: Hashable, Sendable {
        /// Where the viewer was.
        case resume
        case beginning
        case at(ms: Int)

        var startMs: Int? {
            switch self {
            case .resume: nil
            case .beginning: 0
            case .at(let ms): ms
            }
        }
    }

    /// Starts a title on another device, as a viewer.
    func play(
        _ item: Item, on device: ShownDevice, start: Start, profileID: String, audioTrackID: String? = nil,
        subtitleTrackID: String? = nil
    ) async -> RemoteOutcome {
        await send(
            .play(PlayCommand(
                itemId: item.id, profileId: profileID, startMs: start.startMs, audioTrackId: audioTrackID,
                subtitleTrackId: subtitleTrackID)),
            to: device.id)
    }

    /// How waking a TV goes, for the screen that shows it.
    enum WakeStep: Hashable, Sendable {
        /// The server turns it on.
        case waking
        /// It is on; Lobby opens there and connects.
        case opening
        /// Lobby has not come up for a while: tvOS probably asks who is watching, and opens no app
        /// until someone answers.
        case profileHint
        /// Lobby did not come up even after that. The play still waits on the server.
        case notOpen
        /// Lobby is there: the title is sent.
        case starting
    }

    /// How long Lobby may take to open on a TV that was woken, and how often to look. Long enough
    /// to pick a profile on the TV.
    nonisolated static let openWait: Duration = .seconds(60)
    nonisolated static let openLook: Duration = .milliseconds(250)
    /// After this long without Lobby on the TV, the screen says to choose a profile there.
    nonisolated static let profileHintAfter: Duration = .seconds(10)
    /// What the server keeps a play for when it does not say (an older server keeps none).
    nonisolated static let heldPlayWait: Duration = .seconds(180)

    /// Wakes the TV and has the server keep the play until Lobby is open there (docs/decisions.md, "Wake and Play"): the film
    /// starts there also when this app is closed meanwhile. Says each step on the way; returns
    /// how it went, `.cancelled` after `cancelWake`.
    func wakeAndPlay(
        _ item: Item, on device: ShownDevice, start: Start, profileID: String, audioTrackID: String? = nil,
        subtitleTrackID: String? = nil, step: @escaping @MainActor (WakeStep) -> Void
    ) async -> RemoteOutcome {
        guard let app, let client = app.liveClient, isConnected else { return .unreachable }
        let id = UUID().uuidString.lowercased()
        let command = PlayCommand(
            itemId: item.id, profileId: profileID, startMs: start.startMs, audioTrackId: audioTrackID,
            subtitleTrackId: subtitleTrackID)
        step(.waking)
        wakePlays[id] = (device.id, step)
        defer { wakePlays[id] = nil }
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<RemoteOutcome, Never>) in
            // Before it is sent: the TV may be open before the answer comes.
            waiting[id] = continuation
            Task {
                let reply: WakeReply
                do {
                    reply = try await client.wake(deviceID: device.id, session: session, play: HeldPlayRequest(id: id, command: command))
                } catch let refusal as RemoteRefusal {
                    if refusal.needsChannel { reopen = true }
                    finish(id, .notWoken(reason: refusal.reason ?? refusal.code))
                    return
                } catch {
                    finish(id, .unreachable)
                    return
                }
                guard waiting[id] != nil else { return }
                step(.opening)
                guard let held = reply.play else {
                    // A server that keeps nothing: wait for the TV here and send it then.
                    let outcome: RemoteOutcome = if let ready = await awaitReady(device.id) {
                        await play(item, on: ready, start: start, profileID: profileID, audioTrackID: audioTrackID, subtitleTrackID: subtitleTrackID)
                    } else {
                        .notWoken(reason: "did_not_open")
                    }
                    finish(id, outcome)
                    return
                }
                let hint = Task { [weak self] in
                    do { try await Task.sleep(for: Self.profileHintAfter) } catch { return }
                    guard let self, self.waiting[id] != nil, self.device(device.id)?.canPlay != true else { return }
                    self.wakePlays[id]?.step(.profileHint)
                }
                let left = clock.serverNow(steadyMs: SteadyClock.nowMs()).map { held.expiresAt - $0 }
                let wait = left.map { Duration.milliseconds(max(0, $0)) } ?? Self.heldPlayWait
                do { try await Task.sleep(for: wait + Self.resultWait) } catch {}
                hint.cancel()
                finish(id, .expired)
            }
        }
        // The server's time for it ran out: Lobby never opened there.
        return outcome == .expired ? .notWoken(reason: "did_not_open") : outcome
    }

    /// The play that waits for this TV is not wanted any more.
    func cancelWake(_ deviceID: String) {
        for (id, play) in wakePlays where play.deviceID == deviceID {
            finish(id, .cancelled)
            guard let client = app?.liveClient else { continue }
            Task { _ = try? await client.cancelWakePlay(deviceID: deviceID, id: id) }
        }
    }

    /// Whether a play waits for this TV to wake, from here.
    func isWaking(_ deviceID: String) -> Bool {
        wakePlays.values.contains { $0.deviceID == deviceID }
    }

    /// Has Lobby Server turn an Apple TV on and open Lobby on it, waits until it is there on the
    /// channel, and then does `then` (play, or hand over), saying each step on the way.
    func wake(
        _ device: ShownDevice, step: @escaping @MainActor (WakeStep) -> Void,
        then: @MainActor (ShownDevice) async -> RemoteOutcome
    ) async -> RemoteOutcome {
        guard let app, let client = app.liveClient, isConnected else { return .unreachable }
        step(.waking)
        do {
            try await client.wake(deviceID: device.id, session: session)
        } catch let refusal as RemoteRefusal {
            if refusal.needsChannel { reopen = true }
            return .notWoken(reason: refusal.reason ?? refusal.code)
        } catch {
            return .unreachable
        }
        step(.opening)
        let hint = Task { [weak self] in
            do { try await Task.sleep(for: Self.profileHintAfter) } catch { return }
            guard self?.device(device.id)?.canPlay != true else { return }
            step(.profileHint)
        }
        let ready = await awaitReady(device.id)
        hint.cancel()
        guard let ready else { return .notWoken(reason: "did_not_open") }
        step(.starting)
        return await then(ready)
    }

    /// The device once it is open and can play, at most `openWait` from now.
    func awaitReady(_ id: String, wait: Duration = RemoteModel.openWait) async -> ShownDevice? {
        let steady = ContinuousClock()
        let end = steady.now.advanced(by: wait)
        while steady.now < end {
            if let now = device(id), now.online, now.canPlay { return now }
            do { try await Task.sleep(for: Self.openLook) } catch { return nil }
        }
        return nil
    }

    /// From the kids screens: plays the title on a TV as the child, where the title page would
    /// start it here, and wakes the TV first when it sleeps and the household lets kids do that.
    func playForKids(
        _ request: PlayRequest, on device: ShownDevice, step: @escaping @MainActor (WakeStep) -> Void = { _ in }
    ) async -> RemoteOutcome {
        guard let kid = app?.activeProfile?.id else { return .unreachable }
        let start = Start.at(ms: request.startPositionMs)
        if RemoteTargets.willWake(device) {
            return await wakeAndPlay(request.item, on: device, start: start, profileID: kid, step: step)
        }
        return await play(request.item, on: device, start: start, profileID: kid)
    }

    /// From the kids player: what plays here goes on at the TV, waking it first when it sleeps
    /// and the household lets kids do that.
    func sendForKids(to device: ShownDevice, step: @escaping @MainActor (WakeStep) -> Void = { _ in }) async -> RemoteOutcome {
        if RemoteTargets.willWake(device) {
            return await wake(device, step: step) { ready in await self.sendHere(to: ready) }
        }
        return await sendHere(to: device)
    }

    /// What plays there goes on here, at the same place.
    func watchHere(from device: ShownDevice) async -> RemoteOutcome {
        guard let me = app?.device?.id else { return .unreachable }
        return await send(.handover(toDeviceId: me), to: device.id)
    }

    /// What plays here goes on there, at the same place.
    func sendHere(to device: ShownDevice) async -> RemoteOutcome {
        guard let me = app?.device?.id else { return .unreachable }
        return await send(.handover(toDeviceId: device.id), to: me)
    }

    /// The viewer a kids television belongs to: from the manager's list, where this device may
    /// read it. The channel does not say.
    private func fetchBoundViewers() {
        guard let app, app.isManager, devices.contains(where: { $0.isKids && !$0.isSelf && boundViewers[$0.id] == nil }) else { return }
        Task {
            guard let list = try? await app.asManager({ try await $0.devices() }) else { return }
            var bound: [String: String] = [:]
            for device in list.devices { if let kid = device.kidsProfileId { bound[device.id] = kid } }
            boundViewers = bound
        }
    }
}
