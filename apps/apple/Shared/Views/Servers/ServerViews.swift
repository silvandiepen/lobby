// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A server's symbol on its colour, as the switcher shows it.
struct ServerBadge: View {
    let account: ServerAccount
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: account.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.lobbyProfile(account.color), in: Circle())
            .accessibilityHidden(true)
    }
}

/// The servers in a menu: back to "Which library?" when there are several, and Add Server.
/// In the viewer menu and the Apple TV's viewer page.
struct ServerChoices: View {
    @Environment(ServersModel.self) private var servers

    var body: some View {
        if servers.canChangeServers {
            Section("Library") {
                if servers.libraries.count > 1 {
                    Button("Switch Library…", systemImage: "rectangle.stack") {
                        Task { await servers.showLibraryChoice() }
                    }
                    .accessibilityIdentifier("server.switch")
                }
                Button("Add Server…", systemImage: AppSymbol.add) {
                    Task { await servers.addServer() }
                }
                .accessibilityIdentifier("server.add")
            }
        }
    }
}

/// On Who is watching: which library the viewers are of, and the way back to "Which library?".
struct ServerSwitcherButton: View {
    @Environment(ServersModel.self) private var servers
    @Environment(AppModel.self) private var app

    var body: some View {
        let name = servers.activeAccount?.displayName ?? app.connection?.serverName
        if servers.canChangeServers, servers.libraries.count > 1 {
            Button {
                Task { await servers.showLibraryChoice() }
            } label: {
                HStack(spacing: AppTheme.Space.s) {
                    if let account = servers.activeAccount { ServerBadge(account: account, size: 22) }
                    Text(name.map { "Library: \($0)" } ?? "Choose a Library")
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                }
                .font(.subheadline)
            }
            .accessibilityLabel(name.map { "Library: \($0)" } ?? "Library")
            .accessibilityHint("Back to the choice of library")
            .accessibilityIdentifier("server.switcher")
        } else if let name {
            Text("Connected to \(name)")
                .font(.subheadline)
                .foregroundStyle(.lobbySecondary)
        }
    }
}

extension ServersModel.Reach? {
    /// Beside a library's name on "Which library?".
    func text(downloads: Int) -> String {
        switch self {
        case .reachable?: return "Connected"
        case .offline?:
            return downloads == 0 ? "Offline" : "Offline · \(downloads) \(downloads == 1 ? "download" : "downloads") on this device"
        case .checking?, nil: return "Looking…"
        }
    }
}

/// On the Connect screen of a server being added: back to the one that was in use.
struct CancelAddingServerButton: View {
    @Environment(ServersModel.self) private var servers

    var body: some View {
        if servers.isAdding, let from = servers.addingFrom.flatMap({ servers.account($0) }) {
            Button("Back to \(from.displayName)", systemImage: "chevron.backward") {
                Task { await servers.cancelAdding() }
            }
            .accessibilityIdentifier("server.cancelAdding")
        }
    }
}

/// The downloads of the servers not in use, under each one's name. Played there, by that
/// server's rules: choosing one switches to it.
struct OtherServersDownloads: View {
    @Environment(ServersModel.self) private var servers

    var body: some View {
        ForEach(servers.otherServersDownloads, id: \.account.id) { entry in
            Section {
                ForEach(entry.overview.films + entry.overview.shows.flatMap(\.rows)) { row in
                    Button {
                        Task { await servers.playDownload(itemID: row.id, of: entry.account.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                            Text(row.title).font(.headline).foregroundStyle(.primary)
                            Text([row.caption, row.status.label, row.sizeText].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.lobbySecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .disabled(!row.isPlayable || !servers.canChangeServers)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(row.isPlayable ? "Switches to \(entry.account.displayName) and plays the copy on this device" : "")
                    .accessibilityIdentifier("download.other.\(row.title)")
                }
            } header: {
                HStack(spacing: AppTheme.Space.s) {
                    ServerBadge(account: entry.account, size: 20)
                    Text(entry.account.displayName)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("downloads.server.\(entry.account.displayName)")
            } footer: {
                if let total = entry.overview.total { Text(total) }
            }
        }
    }
}
