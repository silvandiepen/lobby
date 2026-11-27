// SPDX-License-Identifier: MPL-2.0
import Foundation
import os

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Which of Lobby's two icons the device shows.
enum AppIconChoice: Sendable, Equatable {
    /// The door left open onto a lit room.
    case primary
    /// The same door with sparkles in a yellow doorway (Brand/portal-kids.png), while a kid is
    /// the viewer.
    case kids
}

/// When Lobby shows its kids icon: while the device is in kids mode (bound to a kids viewer, or
/// a kids viewer chosen on a grown-up device), unless the person turned that off on this device.
enum KidsIconRule {
    /// Settings → This Device → Kids Icon in Kids Mode. One for the device, whichever server.
    static let settingKey = "lobby.kidsIconInKidsMode"

    /// How long kids mode, or its end, has to last before the icon follows. iPhone, iPad and
    /// Apple TV say so in an alert each time the icon changes, so a grown-up who looks at
    /// something for a moment and hands the device back sees none, and neither does a launch
    /// that passes through "nobody chosen yet" on its way to the kids viewer it kept.
    static let settle: Duration = .seconds(20)

    /// The asset catalog's alternate icon. tvOS's is a brand asset of its own: the tvOS app also
    /// carries the iPhone's catalog, so the two cannot share a name.
    #if os(tvOS)
    static let alternateName = "AppIcon-Kids-TV"
    #else
    static let alternateName = "AppIcon-Kids"
    #endif

    static func wanted(isKidsMode: Bool, isOn: Bool) -> AppIconChoice {
        isKidsMode && isOn ? .kids : .primary
    }

    /// What the system calls the icon: nil for the primary.
    static func name(of icon: AppIconChoice) -> String? {
        icon == .kids ? alternateName : nil
    }

    static func icon(named name: String?) -> AppIconChoice {
        name == alternateName ? .kids : .primary
    }
}

/// What shows the icon: the system's alternate icons on iPhone, iPad and Apple TV, the Dock on
/// the Mac.
@MainActor
protocol AppIconSurface: AnyObject {
    /// Whether this device can show another icon at all.
    var canSwitch: Bool { get }
    /// The icon shown now, as the system says.
    var current: AppIconChoice { get }
    func show(_ icon: AppIconChoice) async
}

/// Follows kids mode with the app's icon, without an alert for every passing moment: it changes
/// the icon only when the one wanted differs from the one shown, only once the wish has lasted
/// `settle` with the app in front and no film playing, and it asks the system at most once per
/// wish.
@MainActor
final class KidsIconSwitcher {
    struct State: Equatable {
        var isKidsMode: Bool
        /// Settings → This Device → Kids Icon in Kids Mode.
        var isOn: Bool
        /// The app is in front. iOS changes the icon only then, and shows its alert there.
        var isActive: Bool
        /// A film plays: the alert would cover it, so the change waits for the film to end.
        var isPlaying: Bool
    }

    private let surface: AppIconSurface
    private let settle: Duration
    /// The icon a change is waiting to make, and the wait.
    private(set) var pendingIcon: AppIconChoice?
    private(set) var pending: Task<Void, Never>?

    init(surface: AppIconSurface, settle: Duration = KidsIconRule.settle) {
        self.surface = surface
        self.settle = settle
    }

    func update(_ state: State) {
        guard surface.canSwitch else { return }
        let wanted = KidsIconRule.wanted(isKidsMode: state.isKidsMode, isOn: state.isOn)
        // Already shown, or not now: whatever was waiting is off. When the app is in front
        // again, or the film ends, the next update starts the wait anew.
        guard wanted != surface.current, state.isActive, !state.isPlaying else { return cancel() }
        // The same wish goes on waiting where it was.
        if pendingIcon == wanted { return }
        cancel()
        pendingIcon = wanted
        pending = Task { [weak self, settle] in
            do { try await Task.sleep(for: settle) } catch { return }
            guard let self, self.pendingIcon == wanted else { return }
            if self.surface.current != wanted { await self.surface.show(wanted) }
            if self.pendingIcon == wanted { self.pendingIcon = nil }
        }
    }

    private func cancel() {
        pending?.cancel()
        pending = nil
        pendingIcon = nil
    }
}

#if os(macOS)
/// The Mac has no alternate icons: the Dock shows the kids picture while the app runs in kids
/// mode, and the app's own icon again when it leaves. Nothing asks, so it follows at once.
@MainActor
final class DockIconSurface: AppIconSurface {
    private(set) var current = AppIconChoice.primary
    var canSwitch: Bool { true }

    func show(_ icon: AppIconChoice) async {
        // nil puts the bundle's icon back.
        NSApp.applicationIconImage = icon == .kids ? NSImage(named: "KidsDockIcon") : nil
        current = icon
    }
}
#else
/// iPhone, iPad and Apple TV: the asset catalog's alternate icon, which the system announces
/// with an alert of its own.
@MainActor
final class AlternateIconSurface: AppIconSurface {
    private static let log = Logger(subsystem: "mt.sil.lobby", category: "icon")

    var canSwitch: Bool { UIApplication.shared.supportsAlternateIcons }
    var current: AppIconChoice { KidsIconRule.icon(named: UIApplication.shared.alternateIconName) }

    func show(_ icon: AppIconChoice) async {
        do {
            try await UIApplication.shared.setAlternateIconName(KidsIconRule.name(of: icon))
        } catch {
            // The icon stays as it was; the next change of kids mode tries again.
            Self.log.error("The icon did not change: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif

extension KidsIconSwitcher {
    static func live() -> KidsIconSwitcher {
        #if os(macOS)
        KidsIconSwitcher(surface: DockIconSurface(), settle: .zero)
        #else
        KidsIconSwitcher(surface: AlternateIconSurface())
        #endif
    }
}
