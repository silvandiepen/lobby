// SPDX-License-Identifier: MPL-2.0
import AVKit
import LobbyKit
import SwiftUI

/// "Play on…" on a film's or series' page: shown while there is another device to play on.
struct PlayOnButton: View {
    /// The film or episode that would play.
    let item: Item

    @Environment(AppModel.self) private var app
    @State private var isOpen = false

    var body: some View {
        if !app.remote.targets.isEmpty {
            RoundAction(name: "Play On") {
                Button {
                    isOpen = true
                } label: {
                    RoundLabel(symbol: AppSymbol.playOn)
                }
                .buttonStyle(.lobbyPill)
                .accessibilityLabel("Play on Another Device")
                .accessibilityHint("Chooses a TV or Mac of the household to play this on")
                .accessibilityIdentifier("detail.playOn")
            }
            .sheet(isPresented: $isOpen) {
                PlayOnSheet(item: item)
            }
        }
    }
}

/// Which device to play on, from where, as whom, and with which sound and subtitles.
struct PlayOnSheet: View {
    let item: Item
    /// From the player: what plays here goes over, at its place (a handover).
    var handsOver = false

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var start = Choice.resume
    @State private var profileID: String?
    @State private var audioID = ""
    @State private var subtitleID = ""
    @State private var busy: String?
    @State private var chosenForAirPlay: ShownDevice?
    @State private var problem: String?
    @State private var started: String?
    /// "Waking Living Room…", while a TV is woken for this.
    @State private var progress: String?
    /// "Choose a profile on the TV if it asks", when Lobby is slow to come up there.
    @State private var hint: String?

    enum Choice: Hashable { case resume, beginning, here }

    var body: some View {
        let remote = app.remote
        LobbySheet(title: handsOver ? "Send to Another Device" : "Play On", width: 520, height: 620) {
            LobbyForm {
                Section {
                    LabeledContent("What", value: title)
                    if !handsOver {
                        Picker("Start", selection: $start) {
                            if showsResume { Text(resumeWords).tag(Choice.resume) }
                            Text("From the Beginning").tag(Choice.beginning)
                            if let here = herePosition {
                                Text("Where It Is Here (\(MediaFormat.clock(ms: here)))").tag(Choice.here)
                            }
                        }
                        .accessibilityIdentifier("playOn.start")
                        if viewers.count > 1 {
                            Picker("Viewer", selection: $profileID) {
                                ForEach(viewers) { viewer in
                                    Text(viewer.name).tag(Optional(viewer.id))
                                }
                            }
                            .accessibilityIdentifier("playOn.viewer")
                            .onChange(of: profileID) {
                                if start == .resume, !showsResume { start = .beginning }
                                if start == .beginning, showsResume, profileID != app.activeProfile?.id { start = .resume }
                            }
                        }
                        if file?.audio.count ?? 0 > 1 {
                            Picker("Sound", selection: $audioID) {
                                Text("Automatic").tag("")
                                ForEach(Array((file?.audio ?? []).enumerated()), id: \.offset) { position, track in
                                    Text(PlayerModel.audioLabel(track, position: position + 1)).tag(String(track.index))
                                }
                            }
                        }
                        if !subtitles.isEmpty {
                            Picker("Subtitles", selection: $subtitleID) {
                                Text("Automatic").tag("")
                                Text("Off").tag(PlayCommand.subtitlesOff)
                                ForEach(Array(subtitles.enumerated()), id: \.offset) { position, track in
                                    Text(SubtitleOption.label(language: track.language, title: track.title, isForced: track.isForced, position: position + 1))
                                        .tag(track.id)
                                }
                            }
                        }
                    }
                } footer: {
                    if let progress {
                        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                            HStack(spacing: AppTheme.Space.m) {
                                Label {
                                    Text(progress)
                                } icon: {
                                    ProgressView().controlSize(.small)
                                }
                                .accessibilityIdentifier("playOn.progress")
                                Spacer(minLength: 0)
                                if let id = busy, remote.isWaking(id) {
                                    Button("Cancel", role: .cancel) {
                                        remote.cancelWake(id)
                                    }
                                    .buttonStyle(.lobbyText)
                                    .accessibilityIdentifier("playOn.cancel")
                                }
                            }
                            if let hint {
                                Text(hint)
                                    .accessibilityIdentifier("playOn.hint")
                            }
                        }
                    } else if let started {
                        Label(started, systemImage: AppSymbol.done)
                            .accessibilityIdentifier("playOn.started")
                    }
                }

                let sections = RemoteTargets.playOnSections(remote.targets)
                // The household's Lobby TVs first: AirPlay is never on its own above them.
                if !sections.televisions.isEmpty {
                    Section {
                        ForEach(sections.televisions) { device in
                            row(device)
                        }
                    } header: {
                        Label("Lobby TVs", systemImage: AppSymbol.television)
                    } footer: {
                        Text(sections.televisions.contains(where: RemoteTargets.willWake)
                            ? "An Apple TV with Lobby open plays by itself, and this device controls it. One that says “Will wake” is turned on by Lobby Server, which opens Lobby there and starts the film once it is open, also when you close Lobby here."
                            : "An Apple TV with Lobby open plays by itself, and this device controls it.")
                    }
                }

                Section {
                    ForEach(sections.others) { device in
                        row(device)
                    }
                    airPlayRow
                } header: {
                    Label(sections.televisions.isEmpty ? "Devices" : "Other Devices", systemImage: AppSymbol.playOn)
                } footer: {
                    if !sections.others.isEmpty {
                        Text("A Mac or other device with Lobby open plays by itself, and this device controls it.")
                    }
                }

                if let device = chosenForAirPlay {
                    airPlay(device)
                }
            }
            .alert(
                "That did not work",
                isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
        }
        .onAppear {
            profileID = profileID ?? app.activeProfile?.id
            start = herePosition != nil ? .here : showsResume ? .resume : .beginning
        }
    }

    // MARK: What

    private var title: String {
        guard item.kind == .episode else { return item.title }
        let show = app.wholeCatalogue.show(of: item)
        return "\(show?.title ?? item.title) · \(ItemText.episodeLine(item, show: show))"
    }

    private var file: MediaFile? {
        PlayActionBuilder.action(for: item, progress: nil, context: app.playbackContext).request?.file ?? item.mainFiles.first
    }

    private var subtitles: [SubtitleTrack] { file?.subtitles.filter(\.isText) ?? [] }

    /// Grown-ups and kids alike: a television plays as anyone. A kids viewer only what they may see.
    private var viewers: [Profile] {
        app.profiles.filter { app.mayWatch(item.id, as: $0) }
    }

    private var resumeWords: String {
        guard profileID == app.activeProfile?.id else { return "Where That Viewer Was" }
        guard let progress = app.progress[item.id], progress.isInProgress else { return "Resume" }
        return "Resume at \(MediaFormat.clock(ms: progress.positionMs))"
    }

    /// Resume means something: another viewer's place, or this viewer's part-way.
    private var showsResume: Bool {
        profileID != app.activeProfile?.id || app.progress[item.id]?.isInProgress == true
    }

    /// Where the film is in the player here, when it is this one.
    private var herePosition: Int? {
        guard let player = app.player, player.request.item.id == item.id else { return nil }
        return player.currentPositionMs
    }

    // MARK: Where

    private func row(_ device: ShownDevice) -> some View {
        let name = app.remote.name(of: device)
        return HStack(spacing: AppTheme.Space.m) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(RemoteTargets.playOnState(of: device) { app.wholeCatalogue.item($0)?.title })
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                }
            } icon: {
                Image(systemName: RemoteTargets.symbol(device.platform))
                    .foregroundStyle(.lobbySecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("playOn.device.\(name)")
            Spacer(minLength: 0)
            if busy == device.id {
                ProgressView().controlSize(.small)
            } else if device.online && device.canPlay {
                Button(handsOver ? "Send" : "Play", systemImage: AppSymbol.play) {
                    Task { await play(on: device) }
                }
                .buttonStyle(.lobbyText)
                .disabled(busy != nil || (!handsOver && profileID == nil))
                .accessibilityLabel("Play on \(name)")
                .accessibilityIdentifier("playOn.play.\(name)")
            } else if RemoteTargets.willWake(device), app.road == .home {
                Button(handsOver ? "Wake and Send" : "Wake and Play", systemImage: AppSymbol.play) {
                    Task { await play(on: device, waking: true) }
                }
                .buttonStyle(.lobbyText)
                .disabled(busy != nil || (!handsOver && profileID == nil))
                .accessibilityLabel("Wake \(name) and play on it")
                .accessibilityIdentifier("playOn.wake.\(name)")
            } else if !device.online, device.platform == .tvos {
                Button("AirPlay", systemImage: "airplayvideo") {
                    chosenForAirPlay = device
                }
                .buttonStyle(.lobbyText)
                .accessibilityLabel("Play on \(name) with AirPlay")
                .accessibilityIdentifier("playOn.airPlay.\(name)")
            }
        }
    }

    /// Any AirPlay receiver: this device plays, and sends picture and sound there.
    @ViewBuilder
    private var airPlayRow: some View {
        if app.road == .home {
            HStack(spacing: AppTheme.Space.m) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AirPlay")
                        Text("Plays here and sends it to the TV")
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                    }
                } icon: {
                    Image(systemName: "airplayvideo").foregroundStyle(.lobbySecondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                AirPlayPicker()
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("AirPlay")
                    .accessibilityIdentifier("playOn.airPlayRoute")
                if app.player == nil {
                    Button("Play Here", systemImage: AppSymbol.play) {
                        playHere()
                    }
                    .buttonStyle(.lobbyText)
                    .accessibilityIdentifier("playOn.airPlayPlayHere")
                }
            }
        } else {
            Label("AirPlay works at home", systemImage: "airplayvideo")
                .foregroundStyle(.lobbySecondary)
        }
    }

    @ViewBuilder
    private func airPlay(_ device: ShownDevice) -> some View {
        let name = app.remote.name(of: device)
        Section {
            if app.road == .home {
                Text("Lobby is not open on \(name), so it cannot be told what to play. AirPlay wakes it: choose \(name) in the AirPlay list, then play here.")
                HStack(spacing: AppTheme.Space.m) {
                    AirPlayPicker()
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("AirPlay")
                        .accessibilityIdentifier("playOn.routePicker")
                    Text("Choose \(name)")
                        .foregroundStyle(.lobbySecondary)
                    Spacer(minLength: 0)
                    if app.player == nil {
                        Button("Play Here", systemImage: AppSymbol.play) {
                            playHere()
                        }
                        .buttonStyle(.lobbyText)
                        .accessibilityIdentifier("playOn.playHere")
                    }
                }
            } else {
                Text("AirPlay works at home: \(name) fetches the film from Lobby Server by itself, and cannot reach it from here.")
            }
        } header: {
            Label("AirPlay to \(name)", systemImage: "airplayvideo")
        } footer: {
            Text("Open Lobby on \(name) to control it fully from here.")
        }
    }

    // MARK: Doing it

    private func play(on device: ShownDevice, waking: Bool = false) async {
        busy = device.id
        chosenForAirPlay = nil
        started = nil
        defer {
            busy = nil
            progress = nil
            hint = nil
        }
        let remote = app.remote
        let name = remote.name(of: device)
        let step: @MainActor (RemoteModel.WakeStep) -> Void = { step in
            progress = RemoteTargets.progress(step, device: name)
            hint = RemoteTargets.hint(step, device: name) ?? hint
        }
        let outcome: RemoteOutcome
        if waking, !handsOver {
            // The server keeps the play and starts it once Lobby is open there (docs/decisions.md, "Wake and Play").
            let (viewer, from) = startChoice(for: device)
            outcome = await remote.wakeAndPlay(
                item, on: device, start: from, profileID: viewer,
                audioTrackID: audioID.isEmpty ? nil : audioID, subtitleTrackID: subtitleID.isEmpty ? nil : subtitleID,
                step: step)
            if outcome.succeeded, start == .here { await app.player?.close() }
        } else if waking {
            outcome = await remote.wake(device, step: step) { ready in
                await playThere(ready)
            }
        } else {
            outcome = await playThere(device)
        }
        if outcome == .cancelled { return }
        if outcome == .offline {
            chosenForAirPlay = device
        }
        if case .notWoken = outcome, device.platform == .tvos {
            chosenForAirPlay = device
        }
        if let words = outcome.words(device: name) {
            problem = words
        } else {
            progress = nil
            started = "Playing on \(name)"
            try? await Task.sleep(for: .seconds(1))
            dismiss()
        }
    }

    /// Plays there, or hands over, on a device that is open.
    private func playThere(_ device: ShownDevice) async -> RemoteOutcome {
        let remote = app.remote
        let outcome: RemoteOutcome
        if handsOver {
            outcome = await remote.sendHere(to: device)
        } else {
            let (viewer, from) = startChoice(for: device)
            outcome = await remote.play(
                item, on: device, start: from, profileID: viewer,
                audioTrackID: audioID.isEmpty ? nil : audioID, subtitleTrackID: subtitleID.isEmpty ? nil : subtitleID)
            if outcome.succeeded, start == .here { await app.player?.close() }
        }
        return outcome
    }

    /// As whom and from where, as chosen above.
    private func startChoice(for device: ShownDevice? = nil) -> (viewer: String, start: RemoteModel.Start) {
        let viewer = device.flatMap { app.remote.boundViewers[$0.id] } ?? profileID ?? app.activeProfile?.id ?? ""
        let from: RemoteModel.Start = switch start {
        case .resume: viewer == app.activeProfile?.id ? .at(ms: app.progress[item.id]?.isInProgress == true ? app.progress[item.id]?.positionMs ?? 0 : 0) : .resume
        case .beginning: .beginning
        case .here: .at(ms: herePosition ?? 0)
        }
        return (viewer, from)
    }

    private func playHere() {
        guard app.player == nil, let request = PlayActionBuilder.action(
            for: item, show: item.kind == .episode ? app.wholeCatalogue.show(of: item) : nil,
            progress: app.progress[item.id], context: app.playbackContext
        ).request else { return dismiss() }
        dismiss()
        app.play(request)
    }
}

/// The system's AirPlay button: the person chooses the receiver. An app cannot choose it.
#if os(macOS)
struct AirPlayPicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}
#else
struct AirPlayPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif

/// In the player: what plays here goes on at another device, at the same place.
struct PlayerSendButton: View {
    let model: PlayerModel
    @State private var isOpen = false

    var body: some View {
        if let app = model.appModel, !model.isForKids, !app.remote.targets.isEmpty {
            Button {
                isOpen = true
            } label: {
                Label("Play on Another Device", systemImage: AppSymbol.playOn)
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.lobbyIcon)
            .help("Play on another device")
            .accessibilityIdentifier("player.playOn")
            .sheet(isPresented: $isOpen) {
                PlayOnSheet(item: model.request.item, handsOver: true)
                    .environment(app)
                    .lobbyMotion()
            }
        }
    }
}
