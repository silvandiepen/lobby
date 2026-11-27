// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// "Which library?" on the Apple TV: a large card for each server, the one used last in focus.
/// Arrows and select, on the Siri Remote as in the Remote app.
struct TVLibraryChoice: View {
    @Environment(ServersModel.self) private var servers
    @FocusState private var focused: String?
    @State private var remember = false

    var body: some View {
        VStack(spacing: AppTheme.Space.xl * 2) {
            Text("Which library?")
                .font(.system(size: 64, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: TVMetrics.gap * 2) {
                ForEach(servers.libraries) { account in
                    card(account)
                }
            }
            .focusSection()
            Toggle("Remember my choice on this Apple TV", isOn: $remember)
                .frame(maxWidth: TVMetrics.readable)
                .focusSection()
                .accessibilityIdentifier("library.remember")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focused, servers.preselectedLibrary, priority: .userInitiated)
        .task { await servers.checkReachability() }
        // Back from a choice opened in the library is back to it; at the start it leaves the app.
        .onExitCommand(perform: servers.active.phase == .launching ? nil : { servers.closeLibraryChoice() })
        .accessibilityIdentifier("library.screen")
    }

    private func card(_ account: ServerAccount) -> some View {
        let state = servers.reachability[account.id].text(downloads: servers.downloadCounts[account.id] ?? 0)
        return Button {
            Task { await servers.chooseLibrary(account.id, remember: remember) }
        } label: {
            VStack(spacing: AppTheme.Space.l) {
                ServerBadge(account: account, size: 160)
                Text(account.displayName).font(.title3.weight(.semibold)).lineLimit(2)
                Text(state).font(.callout).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(width: 380, height: 380)
        }
        .buttonStyle(.card)
        .focused($focused, equals: account.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(account.displayName), \(state)")
        .accessibilityIdentifier("library.choose.\(account.displayName)")
    }
}
