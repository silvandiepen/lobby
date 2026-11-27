// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// What the kids screens show instead of the library when the plan says so: resting, only
/// listening, or asking a grown-up (docs/kids-control.md, §3). One calm page, the child's
/// picture, and when it opens again in a child's words.
struct KidsControlPage: View {
    let screen: KidsScreen
    @Environment(AppModel.self) private var app
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: AppTheme.Space.l) {
            Spacer(minLength: 0)
            if let profile = app.activeProfile {
                ProfileAvatar(profile: profile, size: 132)
                    .overlay(alignment: .bottomTrailing) { KidsDoorMark(size: 48).offset(x: 10, y: 6) }
                    .accessibilityHidden(true)
            }
            VStack(spacing: AppTheme.Space.s) {
                Text(title)
                    .font(.largeTitle.weight(.heavy))
                Text(screen.line(now: Date()))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            if case .asking(let asking) = screen { askingFooter(asking) }
            Spacer(minLength: 0)
            KidsGrownUpsButton()
        }
        .padding(AppTheme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KidsTheme.page(contrast).ignoresSafeArea())
        .foregroundStyle(.white)
    }

    private var title: String {
        switch screen {
        case .asking(.sending), .asking(.waiting): return app.kidsControl.askingText
        default: return screen.title
        }
    }

    @ViewBuilder
    private func askingFooter(_ asking: KidsAsking) -> some View {
        switch asking {
        case .sending, .waiting:
            ProgressView().controlSize(.large).tint(.white)
        case .declined, .noAnswer:
            Button("Try again") {
                Task { await app.askKidsAgain() }
            }
            .buttonStyle(ProminentButtonStyle())
            .disabled(Self.retryWait(asking, now: Date()) != nil)
        case .offline:
            EmptyView()
        }
    }

    static func retryWait(_ asking: KidsAsking, now: Date) -> TimeInterval? {
        guard case .noAnswer(let retryAt?) = asking, retryAt > now else { return nil }
        return retryAt.timeIntervalSince(now)
    }
}

/// The last minutes before a switch: a small calm line on top, no flashing, no sound.
struct KidsCountdown: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            if let left = app.kidsControl.countdown(at: context.date) {
                Text(KidsCountdownText.text(left: left, next: app.kidsControl.now?.next))
                    .font(.headline)
                    .padding(.horizontal, AppTheme.Space.m)
                    .padding(.vertical, AppTheme.Space.s)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, AppTheme.Space.s)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }
}


/// Only listening: the household's music and audiobooks in the kids look, nothing to watch.
struct KidsListeningHome: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorSchemeContrast) private var contrast
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: AppTheme.Space.l)]

    var body: some View {
        let music = app.music
        let catalogue = music.catalogue
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Space.l) {
                HStack(spacing: AppTheme.Space.m) {
                    KidsDoorMark(size: 44)
                    Text("Time to listen")
                        .font(.largeTitle.weight(.heavy))
                }
                if !music.isAvailable {
                    Text("There is nothing to listen to yet.")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if !catalogue.sortedBooks.isEmpty {
                    Text("Stories").font(.title2.weight(.bold))
                    LazyVGrid(columns: columns, spacing: AppTheme.Space.l) {
                        ForEach(catalogue.sortedBooks) { book in
                            Button {
                                music.player.play(book: book)
                            } label: {
                                MusicTile(title: book.title, subtitle: book.authors.first, coverID: book.coverId, width: 150, symbol: AppSymbol.music)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !catalogue.sortedAlbums.isEmpty {
                    Text("Music").font(.title2.weight(.bold))
                    LazyVGrid(columns: columns, spacing: AppTheme.Space.l) {
                        ForEach(catalogue.sortedAlbums) { album in
                            Button {
                                music.play(album: album)
                            } label: {
                                MusicTile(title: album.title, subtitle: album.artistCredit, coverID: album.coverId, width: 150)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(AppTheme.Space.xl)
        }
        .safeAreaInset(edge: .bottom) { KidsGrownUpsButton() }
        .background(KidsTheme.page(contrast).ignoresSafeArea())
        .foregroundStyle(.white)
    }
}

/// The way out for a grown-up, as on the child's own page: it asks for Face ID or the passcode.
private struct KidsGrownUpsButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button("For Grown-ups") { Task { await app.askToLeaveKidsMode() } }
            .buttonStyle(.lobbyText)
            .foregroundStyle(.white.opacity(0.8))
            .padding(.bottom, AppTheme.Space.m)
            .accessibilityIdentifier("kids.forGrownUps")
    }
}
