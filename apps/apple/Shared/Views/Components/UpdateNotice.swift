// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// What comes up to say there is something to update.
enum UpdateNotice: Hashable, Identifiable, Sendable {
    /// A newer Lobby is in the App Store.
    case release(StoreRelease)
    /// This app and its server do not work together: for a manager.
    case mismatch(ServerCompatibility)

    var id: String {
        switch self {
        case .release(let release): "release \(release.version)"
        case .mismatch(let compatibility): "mismatch \(compatibility.key ?? "")"
        }
    }
}

/// Shows `AppModel.updateNotice` over the library, and records the answer.
struct UpdateNoticePresenter: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.alert(
            title,
            isPresented: Binding(get: { app.updateNotice != nil }, set: { if !$0 { closed() } }),
            presenting: app.updateNotice
        ) { notice in
            switch notice {
            case .release(let release):
                Button("Update") { update(release) }
                Button("Skip This Version") { app.updates.skip(release) }
                Button("Later", role: .cancel) { app.updates.later(release) }
            case .mismatch(let compatibility):
                Button("OK", role: .cancel) { app.updates.told(compatibility) }
            }
        } message: { notice in
            Text(message(notice))
        }
        #else
        content.sheet(item: Binding(get: { app.updateNotice }, set: { if $0 == nil { closed() } })) { notice in
            UpdateNoticeSheet(
                notice: notice,
                update: { release in update(release) },
                later: { release in app.updates.later(release) },
                skip: { release in app.updates.skip(release) },
                told: { compatibility in app.updates.told(compatibility) },
                appStorePage: app.updates.storePage)
        }
        #endif
    }

    private var title: String {
        switch app.updateNotice {
        case .release?: "A new version of Lobby is ready"
        case .mismatch(let compatibility)?: compatibility.title
        case nil: ""
        }
    }

    private func message(_ notice: UpdateNotice) -> String {
        switch notice {
        case .release(let release):
            let version = "Version \(release.version) is in the App Store."
            return release.shortNotes.map { "\(version)\n\n\($0)" } ?? version
        case .mismatch(let compatibility):
            return compatibility.advice
        }
    }

    private func update(_ release: StoreRelease) {
        if let page = app.updates.done(release) { openURL(page) }
    }

    /// Closed without a button (swiped away, Escape): an answer too, unless the notice went
    /// because something started playing. Then it comes back later.
    private func closed() {
        switch app.updateNotice {
        case .release(let release)?: app.updates.done(release)
        case .mismatch(let compatibility)?: app.updates.told(compatibility)
        case nil: break
        }
    }
}

#if !os(tvOS)
/// The notice on iPhone, iPad and Mac: calm, with what is new and two answers.
struct UpdateNoticeSheet: View {
    let notice: UpdateNotice
    let update: (StoreRelease) -> Void
    let later: (StoreRelease) -> Void
    let skip: (StoreRelease) -> Void
    let told: (ServerCompatibility) -> Void
    /// Where the App Store's page is, when the app is the one behind.
    let appStorePage: URL?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.l) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("update.title")
            ScrollView {
                Text(message)
                    .foregroundStyle(.lobbySecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            buttons
        }
        .padding(AppTheme.Space.xl)
        #if os(macOS)
        .frame(width: 420)
        #else
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        #endif
        .presentationBackground(Color.lobbyBackground(scheme))
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: AppTheme.Space.m) {
            switch notice {
            case .release(let release):
                Button("Later") {
                    later(release)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("update.later")
                Button("Skip This Version") {
                    skip(release)
                    dismiss()
                }
                .accessibilityIdentifier("update.skip")
                Spacer()
                Button("Update") {
                    update(release)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("update.update")
            case .mismatch(let compatibility):
                if case .appBehind = compatibility, let appStorePage {
                    Button("Open the App Store") {
                        told(compatibility)
                        openURL(appStorePage)
                        dismiss()
                    }
                }
                Spacer()
                Button("OK") {
                    told(compatibility)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("update.ok")
            }
        }
        .controlSize(.large)
    }

    private var symbol: String {
        switch notice {
        case .release: AppSymbol.update
        case .mismatch: AppSymbol.problem
        }
    }

    private var title: String {
        switch notice {
        case .release: "A new version of Lobby is ready"
        case .mismatch(let compatibility): compatibility.title
        }
    }

    private var message: String {
        switch notice {
        case .release(let release):
            let version = "Version \(release.version) is in the App Store."
            return release.shortNotes.map { "\(version)\n\n\($0)" } ?? version
        case .mismatch(let compatibility):
            return compatibility.advice
        }
    }
}
#endif

extension View {
    /// Tells a grown-up in the library when there is something to update.
    func offersUpdates() -> some View {
        modifier(UpdateNoticePresenter())
    }
}
