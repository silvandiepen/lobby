// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The app for a kids viewer: the regular one, simpler, larger and richer in colour. Four places, a
/// page per title, and no way to anything else but through a grown-up.
struct KidsRootView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        // When and what: resting, listening or asking shows no library at all.
        let screen = app.kidsControl.screen
        if screen.showsFilms {
            library
                .overlay(alignment: .top) { KidsCountdown() }
        } else if screen == .listening, app.kidsControl.now?.at.listening == true {
            KidsListeningHome()
                .environment(\.lobbyIsPlayful, true)
                .preferredColorScheme(.dark)
        } else {
            KidsControlPage(screen: screen)
                .environment(\.lobbyIsPlayful, true)
                .preferredColorScheme(.dark)
        }
    }

    private var library: some View {
        @Bindable var app = app
        return NavigationStack(path: $app.kidsPath) {
            KidsSectionView(section: app.kidsSection)
                .modifier(KidsSectionArrival(section: app.kidsSection))
                .safeAreaInset(edge: .bottom, spacing: 0) { KidsTabBar(selection: $app.kidsSection) }
                .kidsWithoutBars()
                .navigationDestination(for: KidsRoute.self) { route in
                    Group {
                        if let category = route.categoryID {
                            KidsCategoryView(categoryID: category)
                        } else {
                            KidsTitleView(route: route)
                        }
                    }
                    .opensPage(route)
                }
                #if os(macOS)
                .returns(isInFront: app.kidsPath.isEmpty)
                #endif
        }
        .opensFromTiles()
        .environment(\.lobbyIsPlayful, true)
        .sensoryFeedback(.selection, trigger: app.kidsSection)
        // Pages of deep colour, by day too: white words, light clock, dark glass.
        .preferredColorScheme(.dark)
        .sheet(item: $app.grownUpNotice) { KidsGrownUpNotice(notice: $0) }
        .alert(
            "Time for something else", isPresented: Binding(get: { app.kidsNotice != nil }, set: { if !$0 { app.kidsNotice = nil } })
        ) {
            Button("OK") { app.kidsNotice = nil }
        } message: {
            Text("The film waits for you, right where you stopped.")
        }
    }
}

/// The bar: four places on dark glass, larger than the regular app's.
private struct KidsTabBar: View {
    @Binding var selection: KidsSection
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.motion) private var motion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .headline) private var scale: CGFloat = 1

    private var isWide: Bool { sizeClass == .regular }
    private var height: CGFloat { (isWide ? 92 : 80) * scale }
    private var symbolSize: CGFloat { (isWide ? 28 : 25) * scale }
    /// On a phone the tabs share the width; in a wide window the bar is as wide as its tabs.
    private var tabWidth: CGFloat { isWide ? 140 * scale : .infinity }

    var body: some View {
        HStack(spacing: AppTheme.Space.xs) {
            ForEach(KidsSection.allCases, id: \.self) { section in
                tab(section)
            }
        }
        .padding(7)
        .frame(height: height)
        .background {
            let shape = RoundedRectangle(cornerRadius: KidsTheme.barRadius, style: .continuous)
            if reduceTransparency {
                shape.fill(Color.lobbySurface(.dark))
            } else {
                shape.fill(.ultraThinMaterial)
                    .background(Color.black.opacity(0.3), in: shape)
            }
        }
        .shadow(color: KidsTheme.shadow, radius: 14, y: 6)
        .padding(.horizontal, AppTheme.Space.m)
        .padding(.bottom, isWide ? AppTheme.Space.l : AppTheme.Space.s)
        // Larger text makes it larger, up to where four names still fit beside each other.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
    }

    private func tab(_ section: KidsSection) -> some View {
        let isSelected = section == selection
        return Button {
            selection = section
        } label: {
            VStack(spacing: AppTheme.Space.xs) {
                Image(systemName: section.symbol)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .frame(height: symbolSize * 1.15)
                    .foregroundStyle(isSelected ? KidsTheme.tab(section.theme) : KidsTheme.words)
                Text(section.name)
                    .font((isWide ? Font.headline : .subheadline).weight(isSelected ? .bold : .semibold))
                    .foregroundStyle(KidsTheme.words)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: tabWidth, maxHeight: .infinity)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: KidsTheme.barRadius - 7, style: .continuous).fill(Color.white.opacity(0.16))
                        .transition(.opacity)
                }
            }
            .animation(motion.animation(.change), value: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lobbyPill)
        .frame(maxWidth: tabWidth)
        .accessibilityLabel(section.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("kids.tab.\(section.rawValue)")
        .accessibilityShowsLargeContentViewer {
            Label(section.name, systemImage: section.symbol)
        }
    }
}

extension View {
    /// The kids screens fill the window: no bar above them, and no way out in one.
    func kidsWithoutBars() -> some View {
        modifier(WithoutBars())
    }
}

private struct WithoutBars: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        // The window's own buttons stay, on the page's colour.
        content
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .navigationBarBackButtonHidden()
        #else
        content.toolbar(.hidden, for: .navigationBar)
        #endif
    }
}

/// Another of the four places, over the page's own colours.
private struct KidsSectionArrival: ViewModifier {
    let section: KidsSection

    func body(content: Content) -> some View {
        content
            .modifier(FadesIn())
            .id(section)
    }
}

/// What a grown-up reads who cannot leave from here.
private struct KidsGrownUpNotice: View {
    let notice: GrownUpNotice
    @Environment(AppModel.self) private var app

    var body: some View {
        LobbySheet(title: "For Grown-ups") {
            ScrollView {
                VStack(spacing: AppTheme.Space.l) {
                    Image(systemName: notice == .bound ? AppSymbol.devices : AppSymbol.secret)
                        .font(.system(size: 48))
                        .foregroundStyle(.lobbySecondary)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(text)
                        .foregroundStyle(.lobbySecondary)
                    // A device for a child never reaches Settings: its lock is set up here, past
                    // the grown-up's check.
                    if notice == .bound, let lock = app.environment.kidsLock {
                        KidsLockSetUp(lock: lock)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppTheme.readableWidth)
                .padding(AppTheme.Space.xl)
                .frame(maxWidth: .infinity)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kids.notice.\(notice.rawValue)")
        }
    }

    private var title: String {
        switch notice {
        case .bound:
            app.activeProfile.flatMap { $0.name.isEmpty ? nil : "This device is for \($0.name)" } ?? "This device is for a child"
        case .noPasscode: Self.hasNoPasscode
        }
    }

    #if os(macOS)
    private static let hasNoPasscode = "This Mac has no password"
    private static let noPasscode = "Lobby leaves the kids screens only for a grown-up, who proves it with Touch ID or the Mac's password. Set a password in System Settings first, then come back here."
    #else
    private static let hasNoPasscode = "This device has no passcode"
    private static let noPasscode = "Lobby leaves the kids screens only for a grown-up, who proves it with the device's passcode or Face ID. Set a passcode in the Settings app first, then come back here."
    #endif

    private var text: String {
        switch notice {
        case .bound:
            "A manager changes that from their own device: in Devices and Viewers, open this device and choose who it is for."
        case .noPasscode:
            Self.noPasscode
        }
    }
}
