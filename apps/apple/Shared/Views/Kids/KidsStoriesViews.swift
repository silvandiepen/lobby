// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

// Stories and music for a child: big covers to choose by, a page per story, and a player a
// small child can use alone (docs/kids.md, "Kids music and stories"). In the kids look: dark, the colours
// of the covers, large words, round buttons.

/// The stories place, and the whole kids screens in Only listening: what was begun, the stories
/// as big covers, then the music.
struct KidsStoriesPage: View {
    /// Only listening: "Time to listen", and the way out for grown-ups at its foot.
    var onlyListening = false
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        let music = app.music
        let books = music.isAvailable ? music.catalogue.sortedBooks : []
        let albums = music.isAvailable ? music.catalogue.sortedAlbums : []
        let begun = app.continueListening
        GeometryReader { proxy in
            let room = max(200, proxy.size.width - 2 * KidsTheme.margin)
            ScrollView {
                VStack(alignment: .leading, spacing: KidsTheme.gap + 10) {
                    heading
                        .padding(.top, AppTheme.Space.m)
                    if books.isEmpty, albums.isEmpty {
                        nothing
                    }
                    if !begun.isEmpty {
                        KidsKeepListeningRow(books: begun, room: room, isWide: isWide)
                    }
                    if !books.isEmpty {
                        VStack(alignment: .leading, spacing: AppTheme.Space.m) {
                            KidsRowTitle(title: "Stories")
                                .padding(.horizontal, KidsTheme.margin)
                            grid(room: room) { width in
                                ForEach(books) { book in
                                    NavigationLink(value: KidsRoute(storyID: book.id)) {
                                        KidsCoverTile(
                                            title: book.title, coverID: book.coverId, width: width,
                                            fraction: app.storyPlace(book).fraction, symbol: AppSymbol.audiobooks)
                                    }
                                    .buttonStyle(.kidsTile(opens: KidsRoute(storyID: book.id)))
                                    .accessibilityIdentifier("kids.story.\(book.title)")
                                }
                            }
                        }
                        .arrives(1)
                    }
                    if !albums.isEmpty {
                        VStack(alignment: .leading, spacing: AppTheme.Space.m) {
                            KidsRowTitle(title: "Music")
                                .padding(.horizontal, KidsTheme.margin)
                            grid(room: room) { width in
                                ForEach(albums) { album in
                                    Button {
                                        app.listen(to: album)
                                    } label: {
                                        KidsCoverTile(
                                            title: album.title, coverID: album.coverId, width: width, fraction: nil,
                                            symbol: AppSymbol.albums, playsAtOnce: true)
                                    }
                                    .buttonStyle(.kidsPlayer)
                                    .accessibilityAddTraits(.startsMediaSession)
                                    .accessibilityIdentifier("kids.album.\(album.title)")
                                }
                            }
                        }
                        .arrives(2)
                    }
                }
                .padding(.bottom, KidsTheme.gap)
            }
            .scrollIndicators(.hidden)
            .staggersArrival()
            .refreshable { await app.refresh() }
        }
        .artworkBackground(
            (begun.prefix(1) + books.prefix(2)).compactMap(\.coverId).map(Artwork.musicCover), kids: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(onlyListening ? "kids.listening" : "kids.stories")
    }

    /// "Time to listen" with the door, or the place's name; the child's picture beside it.
    private var heading: some View {
        HStack(spacing: AppTheme.Space.m) {
            if onlyListening {
                KidsDoorMark(size: 44)
            }
            Text(onlyListening ? "Time to listen" : "Stories")
                .kidsHeading(onlyListening ? 34 : 42)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .kidsWords()
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("kids.heading")
            Spacer(minLength: 0)
            KidsAvatar()
        }
        .padding(.horizontal, KidsTheme.margin)
        .arrives(0)
    }

    private var nothing: some View {
        VStack(spacing: AppTheme.Space.m) {
            KidsDoorMark(size: 96)
            Text("There is nothing to listen to yet.")
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("kids.nothing")
        }
        .kidsWords()
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, KidsTheme.margin)
    }

    /// Two across on a phone, as many as fit in a wide window.
    private func grid<Content: View>(room: CGFloat, @ViewBuilder content: (CGFloat) -> Content) -> some View {
        let columns = isWide ? max(3, Int(room / 230)) : 2
        let width = ((room - CGFloat(columns - 1) * KidsTheme.gap) / CGFloat(columns)).rounded(.down)
        return LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(width), spacing: KidsTheme.gap, alignment: .top), count: columns),
            spacing: KidsTheme.gap + 6
        ) {
            content(width)
        }
        .padding(.horizontal, KidsTheme.margin)
    }
}

/// The stories the child began, to go on with at once.
struct KidsKeepListeningRow: View {
    let books: [MusicBook]
    let room: CGFloat
    let isWide: Bool

    var body: some View {
        let width = isWide ? min(460, (room - KidsTheme.gap) / 2) : room * 0.86
        VStack(alignment: .leading, spacing: AppTheme.Space.m) {
            KidsRowTitle(title: "Keep listening")
                .padding(.horizontal, KidsTheme.margin)
            ScrollView(.horizontal) {
                HStack(spacing: KidsTheme.gap) {
                    ForEach(books) { book in
                        KidsKeepListeningCard(book: book, width: books.count == 1 && !isWide ? room : width)
                            .edgeEase(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .modifier(ShelfScrolling(margin: KidsTheme.margin))
        }
        .arrives(0)
    }
}

/// A big square cover with the name under it, large enough to choose by. A story that was
/// begun shows how far; music shows that it plays at once.
struct KidsCoverTile: View {
    let title: String
    let coverID: String?
    let width: CGFloat
    let fraction: Double?
    var symbol = AppSymbol.audiobooks
    var playsAtOnce = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
            MusicCover(coverID: coverID, size: width, radius: KidsTheme.cardRadius, symbol: symbol)
                .overlay(alignment: .bottom) {
                    if let fraction, fraction > 0 {
                        ProgressBar(fraction: fraction, track: KidsTheme.track, fill: KidsTheme.progress, height: 8)
                            .padding(AppTheme.Space.m)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if playsAtOnce {
                        KidsPlayCircle(size: max(40, width * 0.24))
                            .padding(AppTheme.Space.s)
                    }
                }
                .kidsFrame(radius: KidsTheme.cardRadius)
            Text(title)
                .font(.title3.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.leading)
                .kidsWords()
                .frame(width: width, alignment: .leading)
                .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent heard" } ?? "")
    }
}

/// Goes on with a story at once: its cover, its name, how far, and a play sign.
private struct KidsKeepListeningCard: View {
    let book: MusicBook
    let width: CGFloat
    @Environment(AppModel.self) private var app

    var body: some View {
        let place = app.storyPlace(book)
        let cover = min(132, width * 0.4)
        Button {
            app.listen(to: book)
        } label: {
            HStack(spacing: KidsTheme.gap) {
                MusicCover(coverID: book.coverId, size: cover, radius: KidsTheme.posterRadius, symbol: AppSymbol.audiobooks)
                VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                    Text(book.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.leading)
                    if let left = place.leftMs {
                        Text("\(MusicTime.long(left)) left")
                            .font(.headline)
                            .foregroundStyle(KidsTheme.words.opacity(0.8))
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: AppTheme.Space.m) {
                        KidsPlayCircle(size: 44)
                        if let fraction = place.fraction {
                            ProgressBar(fraction: fraction, track: KidsTheme.track, fill: KidsTheme.progress, height: 8)
                        }
                    }
                }
                .foregroundStyle(KidsTheme.words)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(AppTheme.Space.m)
            .frame(width: width, height: cover + 2 * AppTheme.Space.m)
            .background(KidsTheme.quiet, in: RoundedRectangle(cornerRadius: KidsTheme.cardRadius, style: .continuous))
            .kidsFrame(radius: KidsTheme.cardRadius)
        }
        .buttonStyle(.kidsPlayer)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keep listening to \(book.title)")
        .accessibilityAddTraits([.isButton, .startsMediaSession])
        .accessibilityIdentifier("kids.keepListening.\(book.title)")
    }
}

/// A story's page: the cover large, its name, who reads it and how long it is, one Play or
/// Resume, Say it, and the film of the same name while the child may watch.
struct KidsStoryView: View {
    let storyID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.motion) private var motion
    @State private var speaker = TitleSpeaker()

    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        let book = app.music.book(storyID)
        GeometryReader { proxy in
            ScrollView {
                if let book {
                    page(book, size: proxy.size)
                        .padding(.top, 76)
                }
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .topLeading) {
                KidsBackButton { dismiss() }
                    .padding(.leading, KidsTheme.margin)
                    .padding(.top, AppTheme.Space.s)
            }
        }
        .artworkBackground(book?.coverId.map(Artwork.musicCover), kids: true)
        .kidsWithoutBars()
        .accessibilityAction(.escape) { dismiss() }
        #if os(macOS)
        .onExitCommand { dismiss() }
        #endif
        .onDisappear { speaker.stop() }
        .onChange(of: book == nil) { _, isGone in
            if isGone { dismiss() }
        }
    }

    private func page(_ book: MusicBook, size: CGSize) -> some View {
        let cover = min(size.width - 2 * KidsTheme.margin - 40, size.height * (isWide ? 0.48 : 0.42), 460)
        return VStack(alignment: .center, spacing: KidsTheme.gap + 8) {
            MusicCover(coverID: book.coverId, size: max(180, cover), radius: 28, symbol: AppSymbol.audiobooks)
                .kidsFrame(radius: 28)
                .scaleEffect(speaker.isSpeaking && motion.moves ? 1.03 : 1)
                .animation(motion.animation(.change), value: speaker.isSpeaking)
                .arrives(0)
            details(book)
                .frame(maxWidth: 560)
        }
        .padding(.horizontal, KidsTheme.margin)
        .padding(.bottom, AppTheme.Space.xl)
        .frame(width: size.width)
        .staggersArrival()
    }

    private func details(_ book: MusicBook) -> some View {
        let place = app.storyPlace(book)
        let alignment = HorizontalAlignment.center
        return VStack(alignment: alignment, spacing: AppTheme.Space.l) {
            VStack(alignment: alignment, spacing: AppTheme.Space.s) {
                Text(book.title)
                    .kidsHeading(isWide ? 46 : 36)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .kidsWords()
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("kids.story.title")
                Text(([book.readBy, MusicTime.long(book.durationMs)].compactMap { $0 }).joined(separator: " · "))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(KidsTheme.words.opacity(0.85))
            }
            .arrives(1)
            if let fraction = place.fraction, let left = place.leftMs {
                VStack(alignment: alignment, spacing: AppTheme.Space.xs) {
                    ProgressBar(fraction: fraction, track: KidsTheme.track, fill: KidsTheme.progress, height: 10)
                        .frame(maxWidth: 320)
                    Text("\(MusicTime.long(left)) left")
                        .font(.headline)
                        .kidsWords()
                }
                .arrives(1)
            }
            HStack(spacing: AppTheme.Space.l) {
                KidsPlayButton(title: place.label) {
                    speaker.stop()
                    app.listen(to: book)
                }
                .accessibilityLabel("\(place.label) \(book.title)")
                .accessibilityIdentifier("kids.story.play")
                KidsRoundButton(symbol: AppSymbol.sayIt, label: "Say it", size: 68, isSpeaking: speaker.isSpeaking) {
                    speaker.say(book.title)
                }
                .accessibilityHint("Says the title")
                .accessibilityIdentifier("kids.sayIt")
            }
            .arrives(2)
            KidsSpeakerButtons(audio: .story(book))
                .arrives(2)
            if let film = app.film(ofStory: book) {
                NavigationLink(value: KidsRoute(itemID: film.id)) {
                    KidsLinkLabel(title: "Watch the film", symbol: AppSymbol.movies)
                }
                .buttonStyle(.lobbyPill)
                .accessibilityIdentifier("kids.story.film")
                .arrives(3)
            }
        }
    }
}

/// A quieter way to somewhere else: a word and its sign on dark glass.
struct KidsLinkLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.title3.weight(.bold))
            .foregroundStyle(KidsTheme.words)
            .padding(.horizontal, AppTheme.Space.l)
            .frame(minHeight: 56)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.black.opacity(0.25), in: Capsule())
            .contentShape(Capsule())
    }
}

/// What plays, over the kids bar: the cover, the name, and a big play and pause. A tap opens
/// the player.
struct KidsNowPlayingBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.motion) private var motion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let player = app.music.player
        if let track = player.currentTrack {
            let title = player.book?.title ?? track.title
            HStack(spacing: AppTheme.Space.m) {
                Button {
                    player.showsNowPlaying = true
                } label: {
                    HStack(spacing: AppTheme.Space.m) {
                        MusicCover(coverID: player.currentCoverID, size: 54, radius: 12)
                        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                            Text(title)
                                .font(.headline.weight(.bold))
                                .lineLimit(1)
                            if player.duration > 0 {
                                ProgressBar(
                                    fraction: min(1, player.elapsed / player.duration), track: KidsTheme.track,
                                    fill: KidsTheme.progress, height: 5)
                                    .frame(maxWidth: 220)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.lobbyPill)
                .accessibilityLabel("Now playing: \(title)")
                .accessibilityHint("Opens the player")
                .accessibilityIdentifier("kids.nowPlaying")
                KidsPlayPause(size: 56)
            }
            .foregroundStyle(KidsTheme.words)
            .padding(AppTheme.Space.s)
            .padding(.leading, 2)
            .background {
                let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
                if reduceTransparency {
                    shape.fill(Color.lobbySurface(.dark))
                } else {
                    shape.fill(.ultraThinMaterial).background(Color.black.opacity(0.3), in: shape)
                }
            }
            .shadow(color: KidsTheme.shadow, radius: 14, y: 6)
            .frame(maxWidth: 560)
            .padding(.horizontal, AppTheme.Space.m)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The white round play and pause of the kids player.
struct KidsPlayPause: View {
    var size: CGFloat
    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.music.player
        Button {
            player.togglePlay()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.4, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(KidsTheme.onPlay)
                .offset(x: player.isPlaying ? 0 : size * 0.04)
                .frame(width: size, height: size)
                .background(KidsTheme.play, in: Circle())
                .contentShape(Circle())
                .shadow(color: KidsTheme.shadow, radius: 12, y: 5)
        }
        .buttonStyle(.lobbyPill)
        .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier("kids.player.play")
    }
}

/// The player for a child: the cover large, the name, how far, a big play and pause, back a
/// little, and when to stop. Nothing small to hit by mistake.
struct KidsNowPlaying: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.motion) private var motion
    @State private var choosesSleep = false

    var body: some View {
        let player = app.music.player
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height && proxy.size.width > 700
            let cover = wide
                ? min(proxy.size.height * 0.62, proxy.size.width * 0.4, 460)
                : min(proxy.size.width - 2 * KidsTheme.margin - 24, proxy.size.height * 0.42, 460)
            VStack(spacing: 0) {
                topBar(player)
                Spacer(minLength: AppTheme.Space.m)
                if let track = player.currentTrack {
                    let layout = wide
                        ? AnyLayout(HStackLayout(alignment: .center, spacing: 56))
                        : AnyLayout(VStackLayout(alignment: .center, spacing: KidsTheme.gap + 12))
                    layout {
                        MusicCover(coverID: player.currentCoverID, size: max(160, cover), radius: 32, symbol: AppSymbol.audiobooks)
                            .kidsFrame(radius: 32)
                            .scaleEffect(player.isPlaying || !motion.moves ? 1 : 0.9)
                            .animation(motion.animation(.open), value: player.isPlaying)
                        controls(player, track: track)
                            .frame(maxWidth: 520)
                    }
                }
                Spacer(minLength: AppTheme.Space.l)
            }
            .padding(.horizontal, KidsTheme.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(KidsTheme.words)
        .artworkBackground(player.currentCoverID.map(Artwork.musicCover), kids: true)
        .environment(\.lobbyIsPlayful, true)
        .preferredColorScheme(.dark)
        .onChange(of: player.isActive) { _, active in if !active { dismiss() } }
        .accessibilityAction(.escape) { dismiss() }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 720)
        .onExitCommand { dismiss() }
        #endif
        .sheet(isPresented: $choosesSleep) {
            KidsSleepChoices()
                .environment(app)
                #if os(iOS)
                // A phone shows half a sheet; an iPad's sheet is as tall as its choices.
                .presentationDetents(sizeClass == .compact ? [.medium, .large] : [.large])
                #endif
        }
        // A place of its own, so that its buttons keep their names.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kids.player")
    }

    private func topBar(_ player: MusicPlayer) -> some View {
        HStack {
            KidsRoundButton(symbol: "chevron.down", label: "Close", size: 60) { dismiss() }
                .accessibilityIdentifier("kids.player.close")
            Spacer()
            Button {
                choosesSleep = true
            } label: {
                HStack(spacing: AppTheme.Space.s) {
                    Image(systemName: player.sleepTimer == nil ? "moon.zzz" : "moon.zzz.fill")
                        .font(.title2.weight(.semibold))
                    if case .at(let moment) = player.sleepTimer {
                        Text(timerInterval: Date()...max(Date(), moment), countsDown: true)
                            .font(.headline.monospacedDigit())
                    } else if player.sleepTimer == .endOfTrack {
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.bold))
                    }
                }
                .foregroundStyle(player.sleepTimer == nil ? KidsTheme.words : KidsTheme.tab(.stories))
                .padding(.horizontal, AppTheme.Space.m)
                .frame(minWidth: 60, minHeight: 60)
                .background(.ultraThinMaterial, in: Capsule())
                .background(Color.black.opacity(0.25), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.lobbyPill)
            .accessibilityLabel("Sleep timer")
            .accessibilityValue(player.sleepTimer == nil ? "Off" : "On")
            .accessibilityIdentifier("kids.player.sleep")
        }
        .padding(.top, AppTheme.Space.m)
    }

    private func controls(_ player: MusicPlayer, track: MusicTrack) -> some View {
        let isStory = player.book != nil
        return VStack(spacing: KidsTheme.gap + 8) {
            VStack(spacing: AppTheme.Space.s) {
                Text(player.book?.title ?? track.title)
                    .kidsHeading(30)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .kidsWords()
                    .accessibilityIdentifier("kids.player.title")
                if let line = player.book.flatMap(\.readBy) ?? (isStory ? nil : track.artistCredit) {
                    Text(line)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(KidsTheme.words.opacity(0.85))
                        .lineLimit(1)
                }
            }
            VStack(spacing: AppTheme.Space.xs) {
                ProgressBar(
                    fraction: player.duration > 0 ? min(1, player.elapsed / player.duration) : 0, track: KidsTheme.track,
                    fill: KidsTheme.progress, height: 12)
                HStack {
                    Text(MusicTime.clock(player.elapsed))
                    Spacer()
                    if player.isLoading {
                        ProgressView().tint(KidsTheme.words)
                    }
                    Spacer()
                    Text("-" + MusicTime.clock(max(0, player.duration - player.elapsed)))
                }
                .font(.headline.monospacedDigit())
                .foregroundStyle(KidsTheme.words.opacity(0.85))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Position")
            .accessibilityValue("\(MusicTime.clock(player.elapsed)) of \(MusicTime.clock(player.duration))")
            HStack(spacing: 28) {
                if isStory {
                    KidsRoundButton(symbol: "gobackward.15", label: "Back 15 seconds", size: 84) { player.skip(by: -15) }
                        .accessibilityIdentifier("kids.player.back")
                } else {
                    KidsRoundButton(symbol: "backward.fill", label: "Previous", size: 84) { player.previous() }
                        .accessibilityIdentifier("kids.player.back")
                }
                KidsPlayPause(size: 128)
                if isStory {
                    KidsRoundButton(symbol: "goforward.30", label: "Forward 30 seconds", size: 84) { player.skip(by: 30) }
                } else {
                    KidsRoundButton(symbol: "forward.fill", label: "Next", size: 84) { player.next() }
                }
            }
            if let sleep = sleepLine(player) {
                Label(sleep, systemImage: "moon.zzz.fill")
                    .font(.headline)
                    .kidsWords()
            }
        }
    }

    private func sleepLine(_ player: MusicPlayer) -> String? {
        switch player.sleepTimer {
        case .at?: "Stops by itself"
        case .endOfTrack?: KidsSleep.endOfStory.title(isStory: player.book != nil, chapters: !(player.book?.chapters.isEmpty ?? true))
        case nil: nil
        }
    }
}

/// When the player stops by itself, as large choices.
private struct KidsSleepChoices: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let player = app.music.player
        let isStory = player.book != nil
        let chapters = !(player.book?.chapters.isEmpty ?? true)
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Space.m) {
                HStack {
                    Text("Stop playing")
                        .kidsHeading(30)
                        .kidsWords()
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    KidsRoundButton(symbol: "xmark", label: "Cancel", size: 52) { dismiss() }
                        .accessibilityIdentifier("kids.player.sleep.cancel")
                }
                ForEach(KidsSleep.allCases, id: \.self) { choice in
                    Button {
                        choose(choice, player)
                        dismiss()
                    } label: {
                        HStack(spacing: AppTheme.Space.m) {
                            Image(systemName: choice.symbol)
                                .font(.title2.weight(.semibold))
                                .frame(width: 40)
                            Text(choice.title(isStory: isStory, chapters: chapters))
                                .font(.title3.weight(.bold))
                            Spacer(minLength: 0)
                            if isChosen(choice, player) {
                                Image(systemName: "checkmark")
                                    .font(.title3.weight(.bold))
                            }
                        }
                        .foregroundStyle(KidsTheme.words)
                        .padding(.horizontal, AppTheme.Space.l)
                        .frame(minHeight: 68)
                        .background(KidsTheme.quiet, in: RoundedRectangle(cornerRadius: KidsTheme.cardRadius, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: KidsTheme.cardRadius, style: .continuous))
                    }
                    .buttonStyle(.lobbyPill)
                    .accessibilityAddTraits(isChosen(choice, player) ? .isSelected : [])
                    .accessibilityIdentifier("kids.player.sleep.\(choice)")
                }
            }
            .padding(KidsTheme.margin)
        }
        .background(KidsTheme.page(contrast).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func choose(_ choice: KidsSleep, _ player: MusicPlayer) {
        switch choice {
        case .endOfStory: player.setSleepTimer(.endOfTrack)
        case .off: player.setSleepTimer(nil)
        case .minutes15, .minutes30: player.sleep(inMinutes: choice.minutes ?? 15)
        }
    }

    private func isChosen(_ choice: KidsSleep, _ player: MusicPlayer) -> Bool {
        switch (choice, player.sleepTimer) {
        case (.endOfStory, .endOfTrack?), (.off, nil): true
        default: false
        }
    }
}
