// SPDX-License-Identifier: MPL-2.0
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Puts the pairing code on the clipboard, to send to whoever approves the device.
struct CopyCodeButton: View {
    let code: String
    @State private var copies = 0
    @State private var justCopied = false
    @Environment(\.motion) private var motion

    var body: some View {
        Button {
            Self.copy(code)
            copies += 1
        } label: {
            Label(
                justCopied ? "Copied" : "Copy Code",
                systemImage: justCopied ? "checkmark" : "doc.on.doc"
            )
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(QuietButtonStyle())
        .animation(motion.animation(.change), value: justCopied)
        .keyboardShortcut("c", modifiers: .command)
        .sensoryFeedback(.success, trigger: copies)
        .accessibilityIdentifier("connect.copy")
        .task(id: copies) {
            guard copies > 0 else { return }
            justCopied = true
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            justCopied = false
        }
    }

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
