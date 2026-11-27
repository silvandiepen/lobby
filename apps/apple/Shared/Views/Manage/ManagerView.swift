// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The manager's tools: approve a new device, remove a device, keep the viewers, and see how
/// the server is doing. Shown only on a device paired as manager.
struct ManagerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let model: ManagerModel
    @State private var isAddingViewer = false
    /// What each waiting device is let in as, by request id. Viewer until changed.
    @State private var waitingRoles: [String: DeviceAccess] = [:]
    @State private var deviceToRemove: ManagerModel.DeviceRow?
    @State private var viewerToRemove: Profile?
    @State private var isInviting = false
    @State private var invites: HouseholdsModel?

    var body: some View {
        @Bindable var model = model
        LobbyForm { sections }
        .navigationTitle("Devices and Viewers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .disabled(model.isLoading)
            }
        }
        .task {
            // One for the page, so the invitation it made is still there to show.
            if invites == nil { invites = HouseholdsModel(app: app) }
            await app.refreshKidsGlances()
            await model.watch()
        }
        .onChange(of: app.isRefreshing) { _, refreshing in
            // Refresh (⌘R, or pulling down) brings this page up to date too.
            if !refreshing { Task { await model.refresh() } }
        }
        .alert(
            "That did not work",
            isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
        .confirmationDialog(
            deviceToRemove.map { "Remove “\($0.device.name)”?" } ?? "",
            isPresented: Binding(get: { deviceToRemove != nil }, set: { if !$0 { deviceToRemove = nil } }),
            titleVisibility: .visible, presenting: deviceToRemove
        ) { row in
            Button("Remove Device", role: .destructive) {
                Task { await model.remove(row) }
            }
            .accessibilityIdentifier("manage.confirmRemoveDevice")
        } message: { _ in
            Text("It can no longer reach the library until it is paired again. What it downloaded stays on it.")
        }
        .confirmationDialog(
            viewerToRemove.map { "Remove the viewer “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { viewerToRemove != nil }, set: { if !$0 { viewerToRemove = nil } }),
            titleVisibility: .visible, presenting: viewerToRemove
        ) { profile in
            Button("Remove Viewer", role: .destructive) {
                Task { await model.removeViewer(profile) }
            }
            .accessibilityIdentifier("manage.confirmRemoveViewer")
        } message: { _ in
            Text("Everything this viewer watched, and where they stopped, is deleted on Lobby Server.")
        }
        .sheet(isPresented: $isAddingViewer) {
            AddProfileView()
        }
        .sheet(isPresented: $isInviting) {
            if let invites { InviteSomeoneSheet(model: invites) }
        }
        .sheet(item: Binding(get: { invites?.invitation }, set: { if $0 == nil { invites?.dismissInvitation() } })) { invitation in
            LobbySheet(title: "Invitation", width: 520, height: 560) {
                LobbyForm { InvitationSection(invitation: invitation) }
            }
        }
    }


    @ViewBuilder
    private var sections: some View {
        householdSections
        serverSections
    }

    @ViewBuilder
    private var householdSections: some View {
        if app.isGuest {
            HouseholdLabelSection()
        } else {
            waitingSection
        }
        devicesSection
        if !app.isGuest {
            // Pairing at home is pairing into the owner's household.
            approveSection
        }
        viewersSection
        Section {
            Button("Invite Someone…", systemImage: AppSymbol.add) { isInviting = true }
                .accessibilityIdentifier("manage.invite")
        } footer: {
            Text("A code and a link for a device elsewhere, into this household or, for a server admin, a new one.")
        }

    }

    @ViewBuilder
    private var serverSections: some View {
        KidsCodeSection()
        if app.uploads().isAvailable {
            Section {
                NavigationLink(value: Route.uploads) {
                    Label("Upload", systemImage: AppSymbol.upload)
                }
                .accessibilityIdentifier("manage.uploads")
                NavigationLink(value: Route.inbox) {
                    Label("Inbox", systemImage: AppSymbol.inbox)
                }
                .accessibilityIdentifier("manage.inbox")
            } footer: {
                Text("Films and episodes from this device, and what Lobby could not place by itself.")
            }
        }
        if app.isOwnerManager {
            Section {
                NavigationLink(value: Route.households) {
                    Label("Households", systemImage: AppSymbol.households)
                }
                .accessibilityIdentifier("manage.households")
                NavigationLink(value: Route.serverSettings) {
                    Label("Server Settings", systemImage: AppSymbol.settings)
                }
                .accessibilityIdentifier("manage.serverSettings")
            } footer: {
                Text("Who you share the library with, its name, library folders, the TMDB key, converting, access from away and backups.")
            }
        }
        if model.offersOutside {
            Section {
                NavigationLink(value: Route.outside) {
                    Label(app.isGuest ? "Add a Device" : "Access From Outside", systemImage: AppSymbol.outside)
                }
                .accessibilityIdentifier("manage.outside")
            } footer: {
                Text(
                    app.isGuest
                        ? "A device of your household joins with a code you give it here."
                        : "For devices that are neither at home nor on Tailscale.")
            }
        }
        if let status = model.status {
            Section {
                ForEach(ManagerModel.summary(status), id: \.self) { line in
                    Text(line)
                }
            } header: {
                Label("Lobby Server", systemImage: AppSymbol.server)
            }
            .accessibilityIdentifier("manage.server")
        }
    
    }

    // MARK: Waiting

    private var waitingSection: some View {
        Section {
            if model.waiting.isEmpty {
                Text("No device is waiting. Open Lobby on it and choose this server.")
                    .foregroundStyle(.lobbySecondary)
            }
            ForEach(model.waiting) { request in
                // The role is chosen on the request itself, before it is let in: a quick button
                // let a device in as a viewer when an admin was meant.
                let role = Binding(
                    get: { waitingRoles[request.id] ?? .viewer },
                    set: { waitingRoles[request.id] = $0 })
                VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                    LabeledContent {
                        EmptyView()
                    } label: {
                        Text(request.deviceName)
                        if let code = request.code {
                            Text("\(ManagerModel.name(request.platform)) · code \(ManagerModel.spaced(code))")
                        } else {
                            Text(ManagerModel.name(request.platform))
                        }
                    }
                    Picker("Let it in as", selection: role) {
                        ForEach(model.grantable, id: \.self) { access in
                            Text(ManagerModel.name(access)).tag(access)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("manage.waitingRole.\(request.deviceName)")
                    Button(ManagerModel.letInLabel(role.wrappedValue), systemImage: AppSymbol.approve) {
                        let chosen = role.wrappedValue
                        Task {
                            await model.approve(request, as: chosen)
                            waitingRoles[request.id] = nil
                        }
                    }
                    .accessibilityLabel("Let \(request.deviceName) in as \(ManagerModel.article(role.wrappedValue))")
                    .accessibilityIdentifier("manage.approveWaiting.\(request.deviceName)")
                }
                .accessibilityIdentifier("manage.waiting.\(request.deviceName)")
            }
            // Let in by a household admin; a server admin's yes is still to come.
            ForEach(model.awaitingAdmin) { request in
                LabeledContent {
                    if app.isOwnerManager {
                        HStack {
                            Button("Let In") { Task { await model.approve(request, as: nil) } }
                                .accessibilityIdentifier("manage.letIn.\(request.deviceName)")
                            Button("Refuse", role: .destructive) { Task { await model.refuse(request) } }
                                .accessibilityIdentifier("manage.refuse.\(request.deviceName)")
                        }
                        .fixedSize()
                    } else {
                        Text("Waiting for the server owner").foregroundStyle(.lobbySecondary)
                    }
                } label: {
                    Text(request.deviceName)
                    Text("\(ManagerModel.name(request.platform)) · approved by its household admin")
                }
                .accessibilityIdentifier("manage.awaitingAdmin.\(request.deviceName)")
            }
            if let approval = model.lastApproval {
                Label(approval, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.lobbySecondary)
                    .accessibilityIdentifier("manage.approved")
            }
        } header: {
            Label("Waiting to Connect", systemImage: AppSymbol.waiting)
        } footer: {
            Text("Check that the code matches the one on the device, choose what it is let in as, then let it in. A household admin can set up this household's viewers and devices.")
        }
    }

    // MARK: Approve

    @ViewBuilder
    private var approveSection: some View {
        @Bindable var model = model
        Section {
            TextField("Code", text: $model.code, prompt: Text("6 digits"))
                .font(.system(.title3, design: .monospaced))
                #if !os(macOS)
                .keyboardType(.numberPad)
                #endif
                .onSubmit { Task { await model.approve() } }
                .accessibilityLabel("Pairing code")
                .accessibilityIdentifier("manage.code")
            Picker("Let it in as", selection: $model.role) {
                ForEach(model.grantable, id: \.self) { access in
                    Text(ManagerModel.name(access)).tag(access)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("manage.role")
            Button("Approve", systemImage: AppSymbol.approve) {
                Task { await model.approve() }
            }
            .disabled(!model.canApprove)
            .accessibilityIdentifier("manage.approve")
        } header: {
            Label("Type a Code Instead", systemImage: AppSymbol.enterAddress)
        } footer: {
            Text("A new device shows a six-digit code on its Connect screen. A viewer can watch; a household admin can also do what is on this page; a server admin can do everything.")
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        Section {
            ForEach(model.devices) { row in
                NavigationLink(value: Route.device(row.id)) {
                    DeviceRowView(row: row)
                }
                .accessibilityIdentifier("manage.device.\(row.device.name)")
                .contextMenu {
                    if !row.isThisDevice {
                        Button("Remove Device", systemImage: AppSymbol.remove, role: .destructive) { deviceToRemove = row }
                    }
                }
                #if !os(macOS)
                .swipeActions(edge: .trailing) {
                    if !row.isThisDevice {
                        Button("Remove", systemImage: AppSymbol.remove, role: .destructive) { deviceToRemove = row }
                    }
                }
                #endif
            }
        } header: {
            Label("Devices", systemImage: AppSymbol.devices)
        } footer: {
            Text("Open a device to choose what is downloaded on it, or to remove it.")
        }
    }

    // MARK: Viewers

    private var viewersSection: some View {
        Section {
            ForEach(app.profiles) { profile in
                NavigationLink(value: Route.viewer(profile.id)) {
                    LabeledContent {
                        Button("Remove", role: .destructive) { viewerToRemove = profile }
                            .buttonStyle(.lobbyText)
                            .accessibilityLabel("Remove \(profile.name)")
                            .accessibilityIdentifier("manage.removeViewer.\(profile.name)")
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                if profile.kids != nil {
                                    Text(app.kidsGlances[profile.id].map(KidsGlance.line) ?? "Kids viewer")
                                        .font(.footnote)
                                        .foregroundStyle(.lobbySecondary)
                                }
                            }
                        } icon: {
                            ProfileAvatar(profile: profile, size: 24)
                        }
                    }
                }
                .accessibilityIdentifier("manage.viewer.\(profile.name)")
            }
            Button("Add a Viewer…", systemImage: AppSymbol.add) { isAddingViewer = true }
                .accessibilityIdentifier("manage.addViewer")
        } header: {
            Label("Viewers", systemImage: AppSymbol.viewers)
        } footer: {
            Text("One for each person who watches, so everyone keeps their own place. Open a viewer to make it a kids viewer and choose what it may watch.")
        }
    }
}

/// A device in the list: what it is, how it is doing with its list, its space and when it was
/// last seen.
struct DeviceRowView: View {
    let row: ManagerModel.DeviceRow

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.device.name)
                Text(row.isThisDevice ? "\(row.caption) · This device" : row.caption)
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
                if let progress = row.progress {
                    DeviceProgressLabel(progress: progress)
                }
                if !row.facts.isEmpty {
                    Text(row.facts.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                }
            }
        } icon: {
            Image(systemName: ManagerModel.symbol(row.device.platform))
                .foregroundStyle(.lobbySecondary)
        }
        .padding(.vertical, AppTheme.Space.xs)
        .accessibilityElement(children: .combine)
    }
}

struct DeviceProgressLabel: View {
    let progress: DeviceProgress

    var body: some View {
        // Not a Label: inside a row's label, the form would give its symbol a column.
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.xs) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            Text(progress.text)
        }
            .font(.footnote)
            .foregroundStyle(progress.kind == .problem ? Color.lobbyWarning : .secondary)
    }

    private var symbol: String {
        switch progress.kind {
        case .nothing: AppSymbol.download
        case .complete: AppSymbol.done
        case .underway: AppSymbol.underway
        case .problem: AppSymbol.problem
        }
    }
}
