// SPDX-License-Identifier: MPL-2.0
#if !os(tvOS)
import LobbyKit
import SwiftUI

/// "Which library?": with more than one server, the first step of the start, before that
/// server's viewers. The one used last is first and chosen when nothing else is.
struct LibraryChoiceView: View {
    @Environment(ServersModel.self) private var servers
    @Environment(\.colorScheme) private var scheme
    @State private var remember = false

    var body: some View {
        ScrollView {
            VStack(spacing: AppTheme.Space.xl) {
                Text("Which library?")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, AppTheme.Space.xl * 2)
                VStack(spacing: AppTheme.Space.m) {
                    ForEach(servers.libraries) { account in
                        card(account)
                    }
                }
                Toggle("Remember my choice on this device", isOn: $remember)
                    .accessibilityIdentifier("library.remember")
                Text("Each library has its own viewers. To be asked again, turn this off in Settings → Servers.")
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
                if servers.active.phase != .launching {
                    Button("Cancel") { servers.closeLibraryChoice() }
                        .buttonStyle(QuietButtonStyle())
                        .frame(maxWidth: 280)
                        .accessibilityIdentifier("library.cancel")
                }
            }
            .frame(maxWidth: AppTheme.readableWidth)
            .padding(AppTheme.Space.l)
            .frame(maxWidth: .infinity)
        }
        .background(Color.lobbyBackground(scheme).ignoresSafeArea())
        .accessibilityIdentifier("library.screen")
        .task { await servers.checkReachability() }
    }

    private func card(_ account: ServerAccount) -> some View {
        let isPreselected = account.id == servers.preselectedLibrary
        let state = servers.reachability[account.id].text(downloads: servers.downloadCounts[account.id] ?? 0)
        return Button {
            Task { await servers.chooseLibrary(account.id, remember: remember) }
        } label: {
            HStack(spacing: AppTheme.Space.m) {
                ServerBadge(account: account, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    Text(state).font(.subheadline).foregroundStyle(.lobbySecondary)
                }
                Spacer()
                Image(systemName: "chevron.forward").foregroundStyle(.lobbySecondary)
            }
            .padding(AppTheme.Space.l)
            .background(Color.lobbySurfaceRaised(scheme), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                if isPreselected {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(Color.lobbyProfile(account.color), lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(isPreselected ? .defaultAction : nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(account.displayName), \(state)")
        .accessibilityAddTraits(isPreselected ? .isSelected : [])
        .accessibilityIdentifier("library.choose.\(account.displayName)")
    }
}
#endif
