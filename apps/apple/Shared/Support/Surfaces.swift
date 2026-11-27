// SPDX-License-Identifier: MPL-2.0
#if !os(tvOS)
import SwiftUI

// The app's own surfaces under the system's lists, forms, windows and bars.

extension View {
    /// The app's window colour under a page, in place of the system's grey or translucent one.
    func lobbyPage() -> some View {
        modifier(LobbyPage())
    }

    /// A row of a panel in a `List`: the panel's colour, and rounded where the panel ends.
    /// iPhone and iPad round their own. Inside `lobbyReadableList()`.
    func lobbyPanelRow(isFirst: Bool = false, isLast: Bool = false) -> some View {
        modifier(LobbyPanelRow(isFirst: isFirst, isLast: isLast))
    }

    /// The heading or footer of such a panel: as far in as its rows.
    func lobbyPanelHeading() -> some View {
        modifier(LobbyPanelHeading())
    }

    #if os(macOS)
    /// The Mac's toolbar on the window's own colour.
    func lobbyToolbar() -> some View {
        modifier(LobbyToolbar())
    }
    #endif

    /// Keeps a list at a readable width, in the middle of a wide window.
    func lobbyReadableList() -> some View {
        modifier(ReadableList())
    }
}

/// A form on the app's window colour, its groups of rows as panels. `Form` in every screen and
/// sheet is this.
struct LobbyForm<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form {
            Group {
                content
            }
            .listRowBackground(Color.lobbySurface(scheme))
            .listRowSeparatorTint(Color.lobbyHairline(scheme))
        }
        .formStyle(.grouped)
        .modifier(LobbyPage())
    }
}

private struct LobbyPage: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color.lobbyBackground(scheme).ignoresSafeArea())
    }
}

private struct LobbyPanelRow: ViewModifier {
    let isFirst: Bool
    let isLast: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.lobbyListInset) private var inset

    func body(content: Content) -> some View {
        #if os(macOS)
        let top = isFirst ? AppTheme.Radius.control : 0
        let bottom = isLast ? AppTheme.Radius.control : 0
        content
            .frame(minHeight: 36)
            .padding(.vertical, 2)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: 0, leading: inset + AppTheme.Space.m, bottom: 0, trailing: inset + AppTheme.Space.m))
            .listRowBackground(
                UnevenRoundedRectangle(
                    topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top,
                    style: .continuous
                )
                .fill(Color.lobbySurface(scheme))
                .overlay(alignment: .bottom) {
                    if !isLast {
                        Rectangle()
                            .fill(Color.lobbyHairline(scheme))
                            .frame(height: 1)
                            .padding(.leading, AppTheme.Space.m)
                    }
                }
                .padding(.horizontal, inset))
        #else
        content
            .listRowBackground(Color.lobbySurface(scheme))
            .listRowSeparatorTint(Color.lobbyHairline(scheme))
        #endif
    }
}

extension AppTheme {
    /// The widest a list of settings gets in a wide window: its labels and its controls are to
    /// be seen together.
    static let listWidth: CGFloat = 680
}

private struct LobbyPanelHeading: ViewModifier {
    @Environment(\.lobbyListInset) private var inset

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, inset)
            .listRowSeparator(.hidden)
    }
}

extension EnvironmentValues {
    /// How far the rows of a list are in from its sides.
    @Entry fileprivate var lobbyListInset: CGFloat = 0
}

private struct ReadableList: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        let inset = max(0, (width - AppTheme.listWidth) / 2)
        content
            #if os(macOS)
            // A Mac list has no content margins: its rows bring their own.
            .environment(\.lobbyListInset, max(inset, AppTheme.Space.s))
            #else
            .contentMargins(.horizontal, inset > 0 ? inset : nil, for: .scrollContent)
            #endif
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

#if os(macOS)
private struct LobbyToolbar: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // Glass over the page, which fades under it by itself.
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content.toolbarBackground(Color.lobbyBackground(scheme), for: .windowToolbar)
        }
    }
}

/// Gives a Mac window the app's own opaque background, in place of the system's translucent
/// one, which takes a tint from the desktop picture.
struct SolidWindow: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.color = NSColor(Color.lobbyBackground(scheme))
    }

    final class Probe: NSView {
        var color = NSColor.windowBackgroundColor {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            window?.backgroundColor = color
            window?.isOpaque = true
        }
    }
}
#endif
#endif
