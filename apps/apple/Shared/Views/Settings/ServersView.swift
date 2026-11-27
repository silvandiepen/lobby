// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Settings → Servers: the servers this device holds, in the person's order. Switch, rename,
/// give one another look, reorder, remove, add.
struct ServersView: View {
    @Environment(ServersModel.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: ServerAccount?
    @State private var newName = ""
    @State private var restyling: ServerAccount?
    @State private var removing: ServerAccount?

    var body: some View {
        List {
            if !servers.canChangeServers {
                Section {
                    Text("This device belongs to a kids viewer on “\(servers.activeAccount?.displayName ?? "")”, and stays on that server. A manager can change that from their own device.")
                        .foregroundStyle(.lobbySecondary)
                        .accessibilityIdentifier("servers.bound")
                }
            }
            Section {
                ForEach(servers.accounts) { account in
                    row(account)
                }
                .onMove(perform: servers.canChangeServers ? { servers.move(fromOffsets: $0, toOffset: $1) } : nil)
            } footer: {
                Text("Each server keeps its own viewers, downloads, kids mode and settings on this device. Nothing of one is shown or sent with another.")
            }
            if servers.libraries.count > 1 {
                Section {
                    Toggle(
                        "Ask Which Library at Start",
                        isOn: Binding(get: { !servers.remembersLibrary }, set: { servers.setRemembersLibrary(!$0) }))
                        .accessibilityIdentifier("servers.asksLibrary")
                } footer: {
                    Text("Off: Lobby opens the library used last, on this device.")
                }
            }
            Section {
                Button("Add Server…", systemImage: AppSymbol.add) {
                    Task {
                        await servers.addServer()
                        dismiss()
                    }
                }
                .disabled(!servers.canChangeServers)
                .accessibilityIdentifier("servers.add")
            } footer: {
                Text("Find one on this network, type its address, or pair from outside with the code its manager gives you.")
            }
        }
        .navigationTitle("Servers")
        #if os(iOS)
        .toolbar {
            if servers.canChangeServers, servers.accounts.count > 1 { EditButton() }
        }
        #endif
        .alert("Rename Server", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
                .accessibilityIdentifier("servers.renameField")
            Button("Rename") {
                if let renaming { servers.rename(renaming.id, to: newName) }
                renaming = nil
            }
            .accessibilityIdentifier("servers.confirmRename")
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Only on this device. Empty: the server's own name\(renaming?.serverName.map { ", “\($0)”" } ?? "").")
        }
        .sheet(item: $restyling) { account in
            ServerLookPicker(account: account)
        }
        .confirmationDialog(
            "Remove “\(removing?.displayName ?? "")” from this device?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let removing { Task { await servers.remove(removing.id) } }
                removing = nil
            }
            .accessibilityIdentifier("servers.confirmRemove")
        } message: {
            Text("Its access, its copy of the library, its settings and its downloads on this device are deleted, and what was watched and not yet sent to it is lost. Your other servers stay as they are.")
        }
    }

    private func row(_ account: ServerAccount) -> some View {
        let isActive = account.id == servers.activeID
        return Button {
            Task { await servers.switchTo(account.id) }
        } label: {
            HStack(spacing: AppTheme.Space.m) {
                ServerBadge(account: account, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName).foregroundStyle(.primary)
                    Text(caption(account, isActive: isActive))
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.lobbyRow)
        .disabled(isActive || !servers.canChangeServers || !account.isPaired)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("servers.row.\(account.displayName)")
        .swipeActions(edge: .trailing) {
            if servers.canRemove(account.id) {
                Button("Remove", systemImage: AppSymbol.remove, role: .destructive) { removing = account }
            }
            Button("Rename", systemImage: "pencil") { startRenaming(account) }
        }
        .contextMenu { actions(account) }
        #if os(macOS)
        .overlay(alignment: .trailing) {
            Menu {
                actions(account)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.trailing, isActive ? 28 : 0)
            .accessibilityLabel("Actions for \(account.displayName)")
            .accessibilityIdentifier("servers.actions.\(account.displayName)")
        }
        #endif
    }

    @ViewBuilder
    private func actions(_ account: ServerAccount) -> some View {
        Button("Rename…", systemImage: "pencil") { startRenaming(account) }
            .accessibilityIdentifier("servers.rename")
        Button("Symbol and Colour…", systemImage: "paintpalette") { restyling = account }
        if servers.canChangeServers {
            Button("Move Up", systemImage: "arrow.up") { servers.move(account.id, by: -1) }
                .disabled(servers.accounts.first?.id == account.id)
            Button("Move Down", systemImage: "arrow.down") { servers.move(account.id, by: 1) }
                .disabled(servers.accounts.last?.id == account.id)
        }
        if servers.canRemove(account.id) {
            Button("Remove…", systemImage: AppSymbol.remove, role: .destructive) { removing = account }
                .accessibilityIdentifier("servers.remove")
        }
    }

    private func startRenaming(_ account: ServerAccount) {
        newName = account.localName ?? account.displayName
        renaming = account
    }

    private func caption(_ account: ServerAccount, isActive: Bool) -> String {
        let state = !account.isPaired ? "Not paired yet" : isActive ? "In use" : nil
        let own = account.localName != nil ? account.serverName : nil
        return [own, state].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A server's symbol and colour, chosen from a few.
private struct ServerLookPicker: View {
    let account: ServerAccount
    @Environment(ServersModel.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var symbol: String
    @State private var color: String

    init(account: ServerAccount) {
        self.account = account
        _symbol = State(initialValue: account.symbol)
        _color = State(initialValue: account.color)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Symbol") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: AppTheme.Space.m) {
                        ForEach(ServerAccount.symbols, id: \.self) { name in
                            Button {
                                symbol = name
                            } label: {
                                Image(systemName: name)
                                    .font(.title2)
                                    .frame(width: 48, height: 48)
                                    .background(symbol == name ? Color.lobbyProfile(color).opacity(0.3) : .clear, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(symbol == name ? .isSelected : [])
                        }
                    }
                }
                Section("Colour") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: AppTheme.Space.m) {
                        ForEach(ServerAccount.colors, id: \.self) { name in
                            Button {
                                color = name
                            } label: {
                                Circle()
                                    .fill(Color.lobbyProfile(name))
                                    .frame(width: 40, height: 40)
                                    .overlay { if color == name { Image(systemName: "checkmark").foregroundStyle(.white) } }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(name.capitalized)
                            .accessibilityAddTraits(color == name ? .isSelected : [])
                        }
                    }
                }
            }
            .navigationTitle(account.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        servers.setLook(account.id, symbol: symbol, color: color)
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #endif
    }
}
