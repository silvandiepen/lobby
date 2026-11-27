// SPDX-License-Identifier: MPL-2.0
#if !os(tvOS)
import SwiftUI

extension View {
    /// Search in a wide window as a magnifier that opens into a small field, instead of a wide
    /// capsule that is always there. `isSearching` opens it and puts the cursor in it (⌘F).
    func lobbySearch(text: Binding<String>, isSearching: Binding<Bool>, prompt: String) -> some View {
        modifier(QuietSearch(text: text, isSearching: isSearching, prompt: prompt))
    }
}

private struct QuietSearch: ViewModifier {
    @Binding var text: String
    @Binding var isSearching: Bool
    let prompt: String
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        #if os(macOS)
        // The system's own toolbar search cannot be made small on the Mac.
        content.toolbar {
            ToolbarItem(placement: .primaryAction) {
                Group {
                if isSearching || !text.isEmpty {
                    HStack(spacing: AppTheme.Space.xs) {
                        Image(systemName: AppSymbol.search)
                            .foregroundStyle(.lobbySecondary)
                            .accessibilityHidden(true)
                        SmallSearchField(text: $text, isSearching: $isSearching, prompt: prompt)
                            .frame(width: 180)
                    }
                    .padding(.horizontal, AppTheme.Space.s)
                    .transition(motion.moves ? .scale(scale: 0.6, anchor: .trailing).combined(with: .opacity) : .opacity)
                } else {
                    Button("Search", systemImage: AppSymbol.search) { isSearching = true }
                        .transition(.opacity)
                        .help("Search films and series (⌘F)")
                        .accessibilityIdentifier("search.open")
                }
                }
                .animation(motion.animation(.change), value: isSearching)
            }
        }
        #else
        let searchable = content.searchable(text: $text, isPresented: $isSearching, prompt: prompt)
        if #available(iOS 26.0, *) {
            searchable.searchToolbarBehavior(.minimize)
        } else {
            searchable
        }
        #endif
    }
}

#if os(macOS)
/// AppKit's search field: its clear button, Escape, and what VoiceOver calls it.
private struct SmallSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isSearching: Bool
    let prompt: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusingField()
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        field.setAccessibilityIdentifier("search.field")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        // A field without its bezel puts its own magnifier under the words: it is drawn beside.
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        // ⌘F while the field is open but the cursor is somewhere else.
        if isSearching, !context.coordinator.wasSearching, let window = field.window, field.currentEditor() == nil {
            window.makeFirstResponder(field)
        }
        context.coordinator.wasSearching = isSearching
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SmallSearchField
        var wasSearching = true

        init(_ parent: SmallSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        /// The cursor left: an empty field folds back into its magnifier.
        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isSearching = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.text = ""
            parent.isSearching = false
            control.window?.makeFirstResponder(nil)
            return true
        }
    }

    /// Takes the cursor when it appears: it appears because somebody asked to search.
    private final class FocusingField: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
    }
}
#endif
#endif
