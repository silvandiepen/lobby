// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A film's or series' page: its picture from edge to edge, the title, one Play, and a button
/// that says the title; Play on TV while a TV can play it, and what the child plays there. A
/// series has its episodes under that, as large pictures.
struct KidsTitleView: View {
    let route: KidsRoute
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var speaker = TitleSpeaker()
    @State private var seasonID: String?
    /// The title a question was asked for here: it plays by itself when a grown-up says yes.
    @State private var askedFor: String?
    @Environment(\.motion) private var motion

    private var catalogue: Catalogue { route.onlyOnDevice ? app.kidsLibrary.onDevice : app.kidsLibrary.catalogue }
    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        let item = catalogue.item(route.itemID)
        GeometryReader { proxy in
            ScrollView {
                if let item {
                    page(item, size: proxy.size, inset: proxy.safeAreaInsets.top)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .topLeading) {
                KidsBackButton { dismiss() }
                    .padding(.leading, KidsTheme.margin)
                    .padding(.top, AppTheme.Space.s)
            }
        }
        .artworkBackground(item?.artwork.pageColours, kids: true)
        .kidsWithoutBars()
        .accessibilityAction(.escape) { dismiss() }
        #if os(macOS)
        .onExitCommand { dismiss() }
        #endif
        .onDisappear { speaker.stop() }
        .onChange(of: item == nil) { _, isGone in
            // A manager took it away, or the server went out of reach: back to what there is.
            if isGone { dismiss() }
        }
    }

    private func page(_ item: Item, size: CGSize, inset: CGFloat) -> some View {
        let show = item.kind == .show
            ? ShowDetail(show: item, catalogue: catalogue, progress: app.progress, context: app.playbackContext) : nil
        let action = show.map { $0.primary?.action } ?? app.movieDetail(for: item).action
        // A series leaves room for its episodes to be seen.
        let part = show == nil ? (isWide ? 0.86 : 0.66) : (isWide ? 0.66 : 0.54)
        let height = min(max(360, (size.height + inset) * part), size.width * (isWide ? 0.7 : 1.6))
        return VStack(alignment: .leading, spacing: KidsTheme.gap + 4) {
            ZStack(alignment: isWide ? .bottomLeading : .bottom) {
                SlidePicture(
                    artwork: item.artwork.backdrop ?? item.artwork.poster, title: item.title,
                    size: CGSize(width: size.width, height: height), grows: false)
                    .overlay { scrim }
                    .parallaxHeader(height: height)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0), .init(color: .black, location: 0.7),
                                .init(color: .black.opacity(0.5), location: 0.88), .init(color: .clear, location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                            // Where the picture is pulled out above its frame.
                            .overlay(alignment: .top) { Color.black.frame(height: 600).offset(y: -600) }
                    }
                    .accessibilityHidden(true)
                VStack(alignment: isWide ? .leading : .center, spacing: AppTheme.Space.l + 4) {
                    title(item)
                    HStack(spacing: AppTheme.Space.l) {
                        if let request = action?.request, let action {
                            let isResume = if case .play(_, .resume, _) = action { true } else { false }
                            let ids = [item.id] + (item.parentId.map { [$0] } ?? [])
                            if app.kidsControl.allowsVideo(of: ids) {
                                KidsPlayButton(title: isResume ? "Resume" : "Play") { start(request) }
                                    .accessibilityIdentifier("kids.play")
                            } else {
                                // Ask per title: a grown-up says yes, and it plays by itself.
                                let asked = app.kidsControl.request.map { $0.itemId == item.id && $0.state == .waiting } ?? false
                                KidsPlayButton(title: asked ? "Asked — waiting…" : "Ask to Watch") {
                                    askedFor = item.id
                                    Task { await app.askToWatch(item.id) }
                                }
                                .disabled(asked)
                                .accessibilityIdentifier("kids.askToWatch")
                                .onChange(of: app.kidsControl.allowsVideo(of: ids)) { _, allowed in
                                    if allowed, askedFor == item.id {
                                        askedFor = nil
                                        start(request)
                                    }
                                }
                            }
                        }
                        KidsRoundButton(symbol: AppSymbol.sayIt, label: "Say it", size: 68, isSpeaking: speaker.isSpeaking) {
                            speaker.say(item.title)
                        }
                        .accessibilityHint("Says the title")
                        .accessibilityIdentifier("kids.sayIt")
                    }
                    .arrives(1)
                    if let request = action?.request, app.kidsControl.allowsVideo(of: [item.id] + (item.parentId.map { [$0] } ?? [])) {
                        KidsPlayOnButton(request: request)
                            .arrives(1)
                    }
                    KidsTVRemote()
                        .frame(maxWidth: 520)
                }
                .padding(.horizontal, KidsTheme.margin)
                .padding(.bottom, isWide ? 56 : 24)
                .padding(.top, inset + 76)
            }
            .frame(width: size.width, height: height)
            if let show {
                episodes(show, width: size.width, columns: isWide ? max(2, Int(size.width / 330)) : 1)
                    .padding(.horizontal, KidsTheme.margin)
            }
            let related = app.kidsRelated(to: item)
            if related.count >= BrowseBuilder.least {
                KidsRow(title: "Related", items: related, width: isWide ? 190 : 150, onlyOnDevice: route.onlyOnDevice)
                    .accessibilityIdentifier("kids.related")
            }
        }
        .padding(.bottom, AppTheme.Space.xl)
        .frame(maxWidth: .infinity)
        .staggersArrival()
    }

    @ViewBuilder
    private var scrim: some View {
        let dark = Color.lobbyArtworkScrim
        if isWide {
            LinearGradient(
                stops: [.init(color: dark.opacity(0.66), location: 0), .init(color: dark.opacity(0.4), location: 0.3), .init(color: .clear, location: 0.64)],
                startPoint: .leading, endPoint: .trailing)
        } else {
            LinearGradient(
                stops: [.init(color: .clear, location: 0.4), .init(color: dark.opacity(0.62), location: 0.85), .init(color: dark.opacity(0.4), location: 1)],
                startPoint: .top, endPoint: .bottom)
        }
    }

    private func title(_ item: Item) -> some View {
        TitleLogo(
            title: item.title, logo: item.artwork.logo, font: .system(size: isWide ? 64 : 46, weight: .heavy, design: .rounded),
            maxWidth: isWide ? 480 : 330, maxHeight: isWide ? 190 : 130, lines: 3, alignment: isWide ? .leading : .center)
            .kidsWords()
            .scaleEffect(speaker.isSpeaking && motion.moves ? 1.03 : 1, anchor: isWide ? .leading : .center)
            .animation(motion.animation(.change), value: speaker.isSpeaking)
            .arrives(0)
            .accessibilityIdentifier("kids.title")
    }

    private func start(_ request: PlayRequest) {
        speaker.stop()
        app.play(request)
    }

    // MARK: Seasons and episodes

    @ViewBuilder
    private func episodes(_ show: ShowDetail, width: CGFloat, columns: Int) -> some View {
        let season = show.seasons.first { $0.id == seasonID ?? show.currentSeasonID } ?? show.seasons.first
        if show.seasons.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: AppTheme.Space.m) {
                    ForEach(show.seasons) { one in
                        seasonButton(one, isSelected: one.id == season?.id)
                    }
                }
                .padding(.horizontal, KidsTheme.margin)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -KidsTheme.margin)
        }
        if let season {
            let still = ((width - 2 * KidsTheme.margin - CGFloat(columns - 1) * KidsTheme.gap) / CGFloat(columns)).rounded(.down)
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(max(120, still)), spacing: KidsTheme.gap), count: columns),
                spacing: KidsTheme.gap
            ) {
                ForEach(season.episodes) { episode in
                    KidsEpisode(episode: episode, show: show.show, width: max(120, still)) { start($0) }
                        .edgeEase(.vertical)
                }
            }
            .id(season.id)
            .transition(.lobbySwap(motion))
            .arrives(3)
        }
    }

    private func seasonButton(_ season: ShowDetail.Season, isSelected: Bool) -> some View {
        Button {
            withAnimation(motion.animation(.section)) { seasonID = season.id }
        } label: {
            Text(season.name)
                .font(.title3.weight(.bold))
                .foregroundStyle(isSelected ? KidsTheme.onPlay : KidsTheme.words)
                .padding(.horizontal, AppTheme.Space.l)
                .frame(minHeight: 54)
                .background(isSelected ? KidsTheme.play : KidsTheme.quiet, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.lobbyPill)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("kids.season.\(season.name)")
    }
}

/// An episode as a large picture that plays.
private struct KidsEpisode: View {
    let episode: ShowDetail.Episode
    let show: Item
    let width: CGFloat
    let start: (PlayRequest) -> Void

    var body: some View {
        Button {
            if let request = episode.action.request { start(request) }
        } label: {
            ArtworkView(artwork: episode.item.artwork.still ?? show.artwork.backdrop, width: width) {
                TintField(title: episode.title)
            }
            .frame(width: width, height: width / AppTheme.wideAspect)
            .overlay {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.45), .init(color: KidsTheme.scrim, location: 1)],
                    startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                    HStack(spacing: AppTheme.Space.m) {
                        KidsPlayCircle(size: 48)
                        Text(episode.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(KidsTheme.words)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .multilineTextAlignment(.leading)
                    }
                    if case .inProgress(let fraction?) = episode.watch {
                        ProgressBar(fraction: fraction, track: KidsTheme.track, fill: KidsTheme.progress, height: 8)
                    }
                }
                .padding(KidsTheme.margin)
            }
            .kidsFrame(radius: KidsTheme.cardRadius)
        }
        .buttonStyle(.kidsPlayer)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([episode.title, episode.watch.label].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits([.isButton, .startsMediaSession])
        .accessibilityIdentifier("kids.episode.\(episode.item.episodeNumber.map(String.init) ?? episode.title)")
    }
}
