// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The download of one film on its page: a button that says where it is, and what is wrong
/// when something is.
struct DownloadButton: View {
    let item: Item

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.motion) private var motion
    @State private var confirmsRemoval = false

    var body: some View {
        let status = app.downloadStatus(for: item.id)
        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
            Button {
                act(status.actions.first, status: status)
            } label: {
                HStack(spacing: AppTheme.Space.s) {
                    DownloadSymbol(status: status)
                    Text(Self.title(status, item: item))
                        .contentTransition(.opacity)
                    if let percent = status.percentText, status.kind != .notDownloaded {
                        Text(percent)
                            .monospacedDigit()
                            .contentTransition(motion.moves ? .numericText() : .opacity)
                            .foregroundStyle(.lobbySecondary)
                    }
                }
            }
            .buttonStyle(QuietButtonStyle())
            .frame(maxWidth: 360)
            .accessibilityLabel(status.kind == .notDownloaded ? Self.title(status, item: item) : status.accessibilityText)
            .accessibilityHint(Self.hint(status.actions.first))
            .accessibilityIdentifier("detail.download")
            .contextMenu { menu(status) }

            if let fraction = status.fraction, status.kind != .notDownloaded {
                ProgressBar(fraction: fraction, track: Color.lobbySurfaceRaised(scheme), fill: Color.lobbyAccent(scheme))
                    .frame(maxWidth: 360)
                    .transition(.opacity)
            }
            if let detail = status.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
                    .accessibilityIdentifier("detail.downloadDetail")
            }
        }
        .animation(motion.animation(.list), value: status)
        .sensoryFeedback(trigger: status.kind) { old, now in Self.feedback(from: old, to: now) }
        .confirmationDialog("Remove this download?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove from This Device", systemImage: AppSymbol.remove, role: .destructive) {
                Task { await app.removeDownload(itemID: item.id) }
            }
            .accessibilityIdentifier("download.confirmRemove")
        } message: {
            Text("The copy on this device is deleted. The film stays on Lobby Server.")
        }
    }

    @ViewBuilder
    private func menu(_ status: DownloadStatus) -> some View {
        ForEach(status.actions, id: \.self) { action in
            Button(Self.name(action), systemImage: Self.symbol(action), role: action == .remove ? .destructive : nil) {
                act(action, status: status)
            }
        }
    }

    private func act(_ action: DownloadAction?, status: DownloadStatus) {
        guard let action else { return }
        if action == .remove {
            confirmsRemoval = true
        } else {
            Task { await app.perform(action, on: item) }
        }
    }

    /// Felt when a download starts, and when it is there.
    static func feedback(from old: DownloadStatus.Kind, to now: DownloadStatus.Kind) -> SensoryFeedback? {
        if now == .downloaded { return .success }
        return old == .notDownloaded ? .impact(weight: .light) : nil
    }

    /// "Download · 1.8 GB" before, the state after.
    static func title(_ status: DownloadStatus, item: Item) -> String {
        guard status.kind == .notDownloaded else { return status.label }
        let size = item.mainFiles.first.map { MediaFormat.size(bytes: $0.sizeBytes) }
        return ["Download", size].compactMap { $0 }.joined(separator: " · ")
    }

    static func name(_ action: DownloadAction) -> String {
        switch action {
        case .download: "Download"
        case .pause: "Pause"
        case .resume: "Continue"
        case .update: "Download the New File"
        case .remove: "Remove Download"
        }
    }

    static func symbol(_ action: DownloadAction) -> String {
        switch action {
        case .download, .update: "arrow.down.circle"
        case .pause: "pause.circle"
        case .resume: "play.circle"
        case .remove: "trash"
        }
    }

    static func hint(_ action: DownloadAction?) -> String {
        switch action {
        case .download: "Keeps it on this device"
        case .pause: "Pauses the download"
        case .resume: "Continues the download"
        case .update: "Downloads the new file"
        case .remove: "Removes it from this device"
        case nil: ""
        }
    }
}

/// The download of one episode in its row: a symbol that is also the button.
struct DownloadGlyph: View {
    let item: Item

    @Environment(AppModel.self) private var app
    @Environment(\.motion) private var motion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let status = app.downloadStatus(for: item.id)
        Menu {
            ForEach(status.actions, id: \.self) { action in
                Button(
                    DownloadButton.name(action), systemImage: DownloadButton.symbol(action),
                    role: action == .remove ? .destructive : nil
                ) {
                    Task { await app.perform(action, on: item) }
                }
            }
            if let detail = status.detail {
                Section(detail) {}
            }
        } label: {
            ZStack {
                if let fraction = status.fraction, status.kind == .downloading || status.kind == .preparing || status.kind == .paused {
                    Circle()
                        .trim(from: 0, to: max(0.03, fraction))
                        .stroke(Color.lobbyAccent(scheme), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 26, height: 26)
                        .animation(motion.animation(.list), value: fraction)
                        .transition(ring)
                    Image(systemName: status.kind == .paused ? "pause.fill" : "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.lobbySecondary)
                        .transition(.opacity)
                } else {
                    DownloadSymbol(status: status)
                        .font(.title2)
                        .foregroundStyle(Self.tint(status, scheme))
                        .transition(ring)
                }
            }
            .animation(motion.animation(.change), value: status.kind)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        } primaryAction: {
            // One tap does the obvious thing. Removing is in the menu, on a long press.
            if let first = status.actions.first, first != .remove {
                Task { await app.perform(first, on: item) }
            }
        }
        #if os(macOS)
        .menuStyle(.button)
        .buttonStyle(.lobbyIcon)
        .menuIndicator(.hidden)
        .fixedSize()
        #endif
        .sensoryFeedback(trigger: status.kind) { old, now in DownloadButton.feedback(from: old, to: now) }
        .accessibilityLabel(status.kind == .notDownloaded ? "Download" : status.accessibilityText)
        .accessibilityIdentifier("episode.download.\(item.episodeNumber.map(String.init) ?? item.id)")
    }

    /// The ring closes into the mark of what it became.
    private var ring: AnyTransition {
        motion.moves ? .scale(scale: 0.6).combined(with: .opacity) : .opacity
    }

    private static func tint(_ status: DownloadStatus, _ scheme: ColorScheme) -> Color {
        switch status.kind {
        case .failed: .lobbyFailure
        case .outOfDate, .waitingForNetwork: .lobbyWarning
        case .downloaded: .lobbyAccent(scheme)
        default: .secondary
        }
    }
}

/// The download of one film or episode as a round button: its state, and how far it is as a
/// ring around it. One tap does the obvious thing; the rest, removing it too, is in its menu.
struct DownloadCircle: View {
    let item: Item
    var size: CGFloat = 48

    @Environment(AppModel.self) private var app
    @Environment(\.motion) private var motion
    @Environment(\.colorScheme) private var scheme
    @State private var confirmsRemoval = false

    var body: some View {
        let status = app.downloadStatus(for: item.id)
        Button {
            act(status.actions.first)
        } label: {
            ZStack {
                RoundFill()
                if let fraction = status.fraction, status.kind != .notDownloaded, status.kind != .downloaded {
                    Circle()
                        .trim(from: 0, to: max(0.03, fraction))
                        .stroke(Color.lobbyAccent(scheme), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(1.5)
                        .animation(motion.animation(.list), value: fraction)
                }
                Image(systemName: Self.symbol(status))
                    .contentTransition(motion.animatesSymbols ? .symbolEffect(.replace) : .opacity)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(status.kind == .downloaded ? AnyShapeStyle(Color.lobbyAccent(scheme)) : AnyShapeStyle(.primary))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.lobbyPill)
        .help(DownloadButton.title(status, item: item))
        .accessibilityLabel(status.kind == .notDownloaded ? DownloadButton.title(status, item: item) : status.accessibilityText)
        .accessibilityHint(DownloadButton.hint(status.actions.first))
        .contextMenu {
            ForEach(status.actions, id: \.self) { action in
                Button(DownloadButton.name(action), systemImage: DownloadButton.symbol(action), role: action == .remove ? .destructive : nil) {
                    act(action)
                }
            }
        }
        .sensoryFeedback(trigger: status.kind) { old, now in DownloadButton.feedback(from: old, to: now) }
        .confirmationDialog("Remove this download?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove from This Device", systemImage: AppSymbol.remove, role: .destructive) {
                Task { await app.removeDownload(itemID: item.id) }
            }
            .accessibilityIdentifier("download.confirmRemove")
        } message: {
            Text("The copy on this device is deleted. The film stays on Lobby Server.")
        }
    }

    /// The circle is the button's: its symbols have none of their own.
    private static func symbol(_ status: DownloadStatus) -> String {
        switch status.kind {
        case .notDownloaded: "arrow.down.to.line"
        case .downloaded: "checkmark"
        case .downloading, .preparing: "pause.fill"
        case .paused: "arrow.down"
        default: status.symbol
        }
    }

    private func act(_ action: DownloadAction?) {
        guard let action else { return }
        if action == .remove {
            confirmsRemoval = true
        } else {
            Task { await app.perform(action, on: item) }
        }
    }
}

/// A download's symbol: one becomes the next, and it bounces once it is there.
struct DownloadSymbol: View {
    let status: DownloadStatus
    @Environment(\.motion) private var motion

    var body: some View {
        Image(systemName: status.symbol)
            .contentTransition(motion.animatesSymbols ? .symbolEffect(.replace) : .opacity)
            .symbolEffect(.bounce, value: motion.animatesSymbols && status.kind == .downloaded)
    }
}

/// Download Season: says what it would fetch and whether it fits, then asks.
struct DownloadSeasonButton: View {
    let seasonID: String
    let seasonName: String

    @Environment(AppModel.self) private var app
    @State private var plan: SeasonDownloadPlan?

    var body: some View {
        Button {
            Task { plan = await app.seasonDownloadPlan(seasonID: seasonID) }
        } label: {
            Label("Download \(seasonName)", systemImage: "arrow.down.circle")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.lobbyText)
        .accessibilityIdentifier("show.downloadSeason")
        .alert(
            plan?.title ?? "",
            isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } }),
            presenting: plan
        ) { plan in
            if !plan.episodes.isEmpty, plan.fits {
                Button("Download") {
                    Task { await app.download(plan) }
                }
                .accessibilityIdentifier("show.confirmDownloadSeason")
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { plan in
            Text(plan.message)
        }
    }
}
