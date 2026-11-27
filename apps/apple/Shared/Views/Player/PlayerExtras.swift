// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import LobbyKit
import SwiftUI

/// The line of a subtitle the app draws itself, at the foot of the picture.
struct SubtitleOverlay: View {
    let model: PlayerModel

    #if os(tvOS)
    private static let widest: CGFloat = 1400
    #else
    private static let widest: CGFloat = 720
    #endif

    var body: some View {
        if let text = model.subtitleText {
            let style = model.subtitleStyle
            Text(text)
                .font(Self.font(style.size))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.lobbyOnArtwork)
                .padding(.vertical, AppTheme.Space.xs)
                .padding(.horizontal, AppTheme.Space.m)
                // Readable on any picture: the same dark box the system offers for captions, or
                // without it a shadow around the letters.
                .background(
                    Color.lobbyArtworkScrim.opacity(style.background ? 0.7 : 0),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .shadow(color: Color.lobbyArtworkScrim.opacity(style.background ? 0 : 0.9), radius: 2)
                .padding(.horizontal, AppTheme.Space.l)
                .frame(maxWidth: Self.widest)
                .accessibilityIdentifier("player.subtitle")
        } else if let problem = model.subtitleProblem {
            Text(problem)
                .font(.footnote)
                .foregroundStyle(Color.lobbyOnArtwork)
                .padding(AppTheme.Space.s)
                .background(Color.lobbyArtworkScrim.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    static func font(_ size: SubtitlePreferences.Size) -> Font {
        switch size {
        case .small: .body.weight(.medium)
        case .medium: .title3.weight(.medium)
        case .large: .title.weight(.medium)
        }
    }
}

/// A subtitle stored as a picture, drawn where it belongs on the film's picture. Fills the
/// player's view: the film is fitted into it, and so is the screen the cue is placed on.
struct PictureSubtitleOverlay: View {
    let model: PlayerModel

    var body: some View {
        GeometryReader { proxy in
            if let shown = model.subtitlePicture, shown.width > 0, shown.height > 0,
                let image = Self.image(shown.cue.png)
            {
                let scale = min(proxy.size.width / CGFloat(shown.width), proxy.size.height / CGFloat(shown.height))
                let left = (proxy.size.width - CGFloat(shown.width) * scale) / 2
                let top = (proxy.size.height - CGFloat(shown.height) * scale) / 2
                image
                    .resizable()
                    .interpolation(.high)
                    .frame(width: CGFloat(shown.cue.width) * scale, height: CGFloat(shown.cue.height) * scale)
                    .position(
                        x: left + (CGFloat(shown.cue.x) + CGFloat(shown.cue.width) / 2) * scale,
                        y: top + (CGFloat(shown.cue.y) + CGFloat(shown.cue.height) / 2) * scale)
                    .accessibilityLabel("Subtitle")
                    .accessibilityIdentifier("player.pictureSubtitle")
            }
        }
        .allowsHitTesting(false)
    }

    private static func image(_ png: Data) -> Image? {
        #if os(macOS)
        NSImage(data: png).map { Image(nsImage: $0) }
        #else
        UIImage(data: png).map { Image(uiImage: $0) }
        #endif
    }
}

/// Moving the subtitles against the picture, in half seconds, as menu items.
struct SubtitleTimingItems: View {
    let model: PlayerModel

    var body: some View {
        if model.showsSubtitles, !model.isForKids {
            Section("Subtitle Timing: \(SubtitleTiming.text(model.subtitleOffsetMs))") {
                Button("Earlier", systemImage: "gobackward") { model.moveSubtitles(byMs: -PlayerModel.subtitleStepMs) }
                    .accessibilityIdentifier("player.subtitlesEarlier")
                Button("Later", systemImage: "goforward") { model.moveSubtitles(byMs: PlayerModel.subtitleStepMs) }
                    .accessibilityIdentifier("player.subtitlesLater")
                if model.subtitleOffsetMs != 0 {
                    Button("In Time Again", systemImage: "arrow.uturn.backward") { model.resetSubtitleTiming() }
                }
            }
        }
    }
}

/// How far subtitles are moved, in words.
enum SubtitleTiming {
    /// "In time", "0.5 s later", "1.5 s earlier".
    static func text(_ offsetMs: Int) -> String {
        guard offsetMs != 0 else { return "In time" }
        let seconds = Double(abs(offsetMs)) / 1000
        let number = seconds.formatted(.number.precision(.fractionLength(0...1)))
        return offsetMs > 0 ? "\(number) s later" : "\(number) s earlier"
    }
}

/// The choices of the subtitles the app draws itself, as menu items.
struct DrawnSubtitleItems: View {
    let model: PlayerModel

    var body: some View {
        ForEach(model.menuSubtitleOptions) { option in
            Button {
                model.selectSubtitle(option.id)
            } label: {
                if model.selectedSubtitleID == option.id {
                    Label(option.label, systemImage: "checkmark")
                } else {
                    Text(option.label)
                }
            }
        }
    }
}

/// Subtitles the system player's menu does not have: a button of the app's own beside the
/// system's controls. The subtitles the film itself carries stay in the system's menu.
struct ExtraSubtitlesButton: View {
    let model: PlayerModel

    var body: some View {
        if !model.menuSubtitleOptions.isEmpty || (model.showsSubtitles && !model.isForKids), model.preparing == nil {
            Menu {
                if !model.menuSubtitleOptions.isEmpty {
                    Section("More Subtitles") {
                        Button {
                            model.selectSubtitle(nil)
                        } label: {
                            if model.selectedSubtitleID == nil {
                                Label("Off", systemImage: "checkmark")
                            } else {
                                Text("Off")
                            }
                        }
                        DrawnSubtitleItems(model: model)
                    }
                }
                SubtitleTimingItems(model: model)
            } label: {
                Image(systemName: model.selectedSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.lobbyOnArtwork)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
            }
            .accessibilityLabel("More subtitles")
            .accessibilityValue(model.menuSubtitleOptions.first { $0.id == model.selectedSubtitleID }?.label ?? "Off")
            .accessibilityIdentifier("player.moreSubtitles")
        }
    }
}

/// The sound tracks and subtitles to choose from, as menu items, where the app draws its own
/// transport.
struct PlayerChoiceItems: View {
    let model: PlayerModel

    var body: some View {
        if !model.audioChoices.isEmpty {
            Section("Sound") {
                ForEach(model.audioChoices, id: \.self) { option in
                    Button {
                        model.selectAudio(option)
                    } label: {
                        if model.selectedAudio == option {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            }
        }
        Section("Subtitles") {
            Button {
                model.selectSubtitle(nil)
                model.selectStreamSubtitle(nil)
            } label: {
                if model.selectedSubtitleID == nil, model.selectedStreamSubtitle == nil {
                    Label("Off", systemImage: "checkmark")
                } else {
                    Text("Off")
                }
            }
            ForEach(model.streamSubtitleChoices, id: \.self) { option in
                Button {
                    model.selectStreamSubtitle(option)
                } label: {
                    if model.selectedStreamSubtitle == option {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
            DrawnSubtitleItems(model: model)
        }
        SubtitleTimingItems(model: model)
    }
}

/// The film from start to end: what was played, what this device holds, what the server has
/// prepared, what it has not, and where the viewer is.
struct PreparingBar: View {
    let timeline: PreparingTimeline
    /// 0…1, where the viewer is.
    let played: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let here = min(played, timeline.preparedFraction)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.lobbyOnArtwork.opacity(0.18))
                Capsule().fill(Color.lobbyOnArtwork.opacity(0.32)).frame(width: max(4, width * timeline.preparedFraction))
                ForEach(timeline.bufferedFractions, id: \.lowerBound) { part in
                    Capsule().fill(Color.lobbyOnArtwork.opacity(0.6))
                        .frame(width: max(4, width * (part.upperBound - part.lowerBound)))
                        .offset(x: width * part.lowerBound)
                }
                Capsule().fill(Color.lobbyOnArtwork).frame(width: max(4, width * here))
                Circle().fill(Color.lobbyOnArtwork)
                    .frame(width: height * 2.4, height: height * 2.4)
                    .offset(x: min(max(0, width * here - height * 1.2), max(0, width - height * 2.4)))
            }
        }
    }
}

#if !os(tvOS)
/// The transport of a film whose copy the server is still writing: the film's own length,
/// how far the copy reaches, and the usual controls. Shown instead of the system's transport,
/// which would call the growing stream a live broadcast.
struct PreparingTransport: View {
    let model: PlayerModel
    let close: () -> Void

    @State private var showsControls = true
    @State private var dragFraction: Double?
    @Environment(\.motion) private var motion

    var body: some View {
        if let timeline = model.preparing {
            ZStack {
                // A tap on the picture shows or hides the controls, as in the system player.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { showsControls.toggle() }
                    .accessibilityHidden(true)

                if showsControls || !model.isPlaying {
                    controls(timeline)
                        .transition(.opacity)
                }
            }
            .animation(motion.animation(.section), value: showsControls)
            .foregroundStyle(Color.lobbyOnArtwork)
            .environment(\.colorScheme, .dark)
        }
    }

    private func controls(_ timeline: PreparingTimeline) -> some View {
        VStack(spacing: AppTheme.Space.l) {
            HStack(spacing: AppTheme.Space.m) {
                round("xmark", "Close", action: close)
                    .accessibilityIdentifier("player.close")
                Spacer()
                if !model.isForKids, !model.audioChoices.isEmpty || !model.streamSubtitleChoices.isEmpty || !model.subtitleOptions.isEmpty {
                    choicesMenu
                }
            }

            Spacer()

            HStack(spacing: AppTheme.Space.xl) {
                round("gobackward.10", "Back 10 seconds") { model.skip(bySeconds: -10) }
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .animation(motion.animation(.change), value: model.isPlaying)
                        .font(.largeTitle)
                        .frame(width: 84, height: 84)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.lobbyIcon)
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("player.playPause")
                round("goforward.10", "Forward 10 seconds") { model.skip(bySeconds: 10) }
            }

            Spacer()

            VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                Text([model.request.title, model.request.subtitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline)
                Text(timeline.hasCaughtUp ? "Waiting for Lobby Server to prepare more of this film." : timeline.statusText)
                    .font(.footnote)
                    .opacity(0.8)
                    .accessibilityIdentifier("player.preparingStatus")
                HStack(spacing: AppTheme.Space.m) {
                    Text(timeline.elapsedText)
                        .monospacedDigit()
                        .accessibilityIdentifier("player.elapsed")
                    bar(timeline)
                    Text(timeline.remainingText)
                        .monospacedDigit()
                        .accessibilityIdentifier("player.remaining")
                }
                .font(.footnote.weight(.medium))
                .padding(.vertical, AppTheme.Space.s)
                .padding(.horizontal, AppTheme.Space.m)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(AppTheme.Space.l)
    }

    /// The film from start to end: what was played, what the server has prepared, what it has not.
    private func bar(_ timeline: PreparingTimeline) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let played = dragFraction ?? timeline.positionFraction
            PreparingBar(timeline: timeline, played: played)
            .frame(height: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragFraction = min(1, max(0, $0.location.x / max(1, width))) }
                    .onEnded { value in
                        model.seek(toFraction: min(1, max(0, value.location.x / max(1, width))))
                        dragFraction = nil
                    })
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Position in the film")
        .accessibilityValue(timeline.accessibilityValue)
        .accessibilityAdjustableAction { direction in
            model.skip(bySeconds: direction == .increment ? 10 : -10)
        }
        .accessibilityIdentifier("player.bar")
    }

    private var choicesMenu: some View {
        Menu {
            PlayerChoiceItems(model: model)
        } label: {
            Image(systemName: "captions.bubble")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Sound and subtitles")
        .accessibilityIdentifier("player.choices")
    }

    private func round(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.lobbyIcon)
        .accessibilityLabel(label)
    }
}
#endif
