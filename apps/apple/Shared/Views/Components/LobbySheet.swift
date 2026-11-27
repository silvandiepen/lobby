// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// A sheet that looks like the platform's own: on iPhone and iPad a navigation bar with Done,
/// on the Mac a title at the top and the button at the bottom right.
struct LobbySheet<Content: View>: View {
    let title: String
    /// The Mac's size. Elsewhere the system decides.
    var width: CGFloat = 480
    var height: CGFloat? = nil
    /// The button that does it. Without one there is only Done.
    var confirm: Confirm? = nil
    @ViewBuilder var content: Content

    struct Confirm {
        var title: String
        var isEnabled = true
        var action: () async -> Void
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var isBusy = false

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, AppTheme.Space.l)
                .padding(.top, AppTheme.Space.l)
                .padding(.bottom, AppTheme.Space.s)
            // A search field of the content belongs to this stack's own bar.
            NavigationStack {
                content
                    .scrollContentBackground(.hidden)
            }
            Divider()
            HStack(spacing: AppTheme.Space.m) {
                Spacer()
                if let confirm {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    confirmButton(confirm)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("sheet.done")
                }
            }
            .padding(AppTheme.Space.l)
        }
        .frame(width: width)
        .frame(height: height ?? 480)
        .background(Color.lobbyBackground(scheme))
        .presentationBackground(Color.lobbyBackground(scheme))
        #else
        NavigationStack {
            content
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .background(Color.lobbyBackground(scheme))
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let confirm {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            confirmButton(confirm)
                        }
                    } else {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                                .accessibilityIdentifier("sheet.done")
                        }
                    }
                }
        }
        .presentationBackground(Color.lobbyBackground(scheme))
        #endif
    }

    private func confirmButton(_ confirm: Confirm) -> some View {
        Button(confirm.title) {
            isBusy = true
            Task {
                await confirm.action()
                isBusy = false
            }
        }
        .disabled(!confirm.isEnabled || isBusy)
        .accessibilityIdentifier("sheet.confirm")
    }
}
