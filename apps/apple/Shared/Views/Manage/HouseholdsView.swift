// SPDX-License-Identifier: MPL-2.0
import LobbyDirect
import LobbyKit
import SwiftUI

/// The households that share the server, for a manager of the owner's household.
struct HouseholdsView: View {
    @Environment(AppModel.self) private var app
    @State private var model: HouseholdsModel
    @State private var isInviting = false

    init(app: AppModel) {
        _model = State(initialValue: HouseholdsModel(app: app))
    }

    var body: some View {
        LobbyForm {
            Section {
                if model.guests.isEmpty, !model.isLoading {
                    Text("Nobody else yet.").foregroundStyle(.lobbySecondary)
                }
                ForEach(model.guests) { household in
                    NavigationLink(value: Route.household(household.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(household.name, systemImage: AppSymbol.households)
                            Text(HouseholdsModel.caption(household))
                                .font(.footnote)
                                .foregroundStyle(.lobbySecondary)
                        }
                    }
                    .accessibilityIdentifier("households.row.\(household.name)")
                }
                Button("Invite a Household…", systemImage: AppSymbol.add) { isInviting = true }
                    .disabled(model.isWorking || model.isUnavailable)
                    .accessibilityIdentifier("households.invite")
            } header: {
                Label("Sharing the Library", systemImage: AppSymbol.households)
            } footer: {
                Text("Another household gets its own viewers, kids, devices and managers, and watches your library, as far as you allow. Sharing films outside your own household can be restricted by law where you live; that is up to you.")
            }
        }
        .overlay {
            if model.isUnavailable {
                ContentUnavailableView(
                    "Not on this server yet", systemImage: AppSymbol.households,
                    description: Text("Update Lobby Server to share it with other households."))
            }
        }
        .navigationTitle("Households")
        .task { await model.refresh() }
        .sheet(isPresented: $isInviting) {
            InviteHouseholdSheet(model: model, groups: app.categoryGroups)
        }
        .sheet(item: Binding(get: { model.invitation }, set: { if $0 == nil { model.dismissInvitation() } })) { invitation in
            LobbySheet(title: "Invitation", width: 520, height: 560) {
                LobbyForm { InvitationSection(invitation: invitation) }
            }
        }
        .alert(
            "That did not work",
            isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }
}

/// One guest household: what it may see and use, its devices, invitations, pause and remove.
struct HouseholdPageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: HouseholdsModel
    @State private var draft = HouseholdsModel.Draft()
    @State private var confirmsRemove = false
    let householdID: String

    init(app: AppModel, householdID: String) {
        _model = State(initialValue: HouseholdsModel(app: app))
        self.householdID = householdID
    }

    var body: some View {
        LobbyForm {
            if let detail = model.detail {
                HouseholdLimitsSections(draft: $draft, groups: app.categoryGroups)
                Section {
                    Button("Save Changes", systemImage: AppSymbol.approve) {
                        Task { await model.save(draft, for: householdID) }
                    }
                    .disabled(model.isWorking || !draft.isValid || HouseholdsModel.Draft(detail.household) == draft)
                    .accessibilityIdentifier("household.save")
                }
                devicesSection(detail)
                invitesSection(detail)
                Section {
                    Toggle(
                        "Paused",
                        isOn: Binding(
                            get: { detail.household.paused },
                            set: { paused in Task { await model.setPaused(paused, id: householdID) } })
                    )
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("household.paused")
                    Button("Remove Household…", systemImage: AppSymbol.remove, role: .destructive) { confirmsRemove = true }
                        .accessibilityIdentifier("household.remove")
                } footer: {
                    Text("Paused, its devices get nothing until you let it in again; nothing is removed. Removing it cuts its devices off at once and deletes its viewers and what they watched. Your library stays as it is.")
                }
            }
        }
        .overlay {
            if model.detail == nil, model.problem == nil { ProgressView() }
        }
        .navigationTitle(model.detail?.household.name ?? "Household")
        .task {
            await model.open(householdID)
            if let household = model.detail?.household { draft = HouseholdsModel.Draft(household) }
        }
        .confirmationDialog(
            "Remove “\(model.detail?.household.name ?? "")”?", isPresented: $confirmsRemove, titleVisibility: .visible
        ) {
            Button("Remove Household", role: .destructive) {
                Task { if await model.remove(householdID) { dismiss() } }
            }
            .accessibilityIdentifier("household.confirmRemove")
        } message: {
            Text("Its devices can no longer reach your server, and its viewers are deleted with what they watched.")
        }
        .sheet(item: Binding(get: { model.invitation }, set: { if $0 == nil { model.dismissInvitation() } })) { invitation in
            LobbySheet(title: "Invitation", width: 520, height: 560) {
                LobbyForm { InvitationSection(invitation: invitation) }
            }
        }
        .alert(
            "That did not work",
            isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }

    private func devicesSection(_ detail: HouseholdDetail) -> some View {
        Section {
            if detail.devices.isEmpty {
                Text("No device yet: the invitation was not used.").foregroundStyle(.lobbySecondary)
            }
            ForEach(detail.devices) { device in
                LabeledContent(device.name, value: "\(ManagerModel.name(device.platform)) · \(ManagerModel.name(device.role))")
            }
        } header: {
            Label("Devices", systemImage: AppSymbol.devices)
        } footer: {
            Text("Its managers add and remove its devices and viewers. You see which devices it has, not what they watch.")
        }
    }

    private func invitesSection(_ detail: HouseholdDetail) -> some View {
        Section {
            ForEach(detail.invites.filter { $0.isOpen() }) { invite in
                LabeledContent("Open until", value: invite.expiresAt.formatted(date: .abbreviated, time: .shortened))
                    .swipeActions {
                        Button("Take Back", role: .destructive) { Task { await model.revoke(invite) } }
                    }
                    .contextMenu {
                        Button("Take Back", systemImage: AppSymbol.remove, role: .destructive) { Task { await model.revoke(invite) } }
                    }
            }
            Button("Invite Another Manager…", systemImage: AppSymbol.add) {
                Task { await model.newInvitation(for: detail.household) }
            }
            .disabled(model.isWorking || detail.household.paused)
            .accessibilityIdentifier("household.newInvite")
        } header: {
            Label("Invitations", systemImage: AppSymbol.outside)
        } footer: {
            Text("An invitation lets one device in, as a manager of this household. Use it when they lost theirs.")
        }
    }
}

/// What the owner decides for a guest household: its name and what of the library and the line
/// it may use.
struct HouseholdLimitsSections: View {
    @Binding var draft: HouseholdsModel.Draft
    let groups: CategoryGroups

    var body: some View {
        Section {
            TextField("Name", text: $draft.name, prompt: Text("The neighbours"))
                .accessibilityIdentifier("household.name")
        } header: {
            Text("Household")
        }
        Section {
            Toggle("The Whole Library", isOn: $draft.wholeLibrary)
                .accessibilityIdentifier("household.wholeLibrary")
        } header: {
            Text("What They See")
        } footer: {
            Text(draft.wholeLibrary
                ? "Everything, also what is added later. Their kids viewers see what their own managers allow."
                : "Only what is in the parts chosen below, and no music. Their kids viewers see what both allow.")
        }
        if !draft.wholeLibrary {
            ForEach(groups.groups) { group in
                Section {
                    Toggle(isOn: Binding(
                        get: { draft.groupIDs.contains(group.id) },
                        set: { on in if on { draft.groupIDs.insert(group.id) } else { draft.groupIDs.remove(group.id) } })
                    ) {
                        Label("All of It", systemImage: AppSymbol.existing(group.icon) ?? AppSymbol.group)
                    }
                    .accessibilityIdentifier("household.group.\(group.name ?? "main")")
                    ForEach(CategoryTree(group).rows) { row in
                        Toggle(isOn: Binding(
                            get: { draft.groupIDs.contains(group.id) || draft.categoryIDs.contains(row.category.id) },
                            set: { on in
                                if on { draft.categoryIDs.insert(row.category.id) } else { draft.categoryIDs.remove(row.category.id) }
                            })
                        ) {
                            Label(row.category.name, systemImage: AppSymbol.existing(row.category.icon) ?? AppSymbol.category)
                        }
                        .disabled(draft.groupIDs.contains(group.id))
                        .padding(.leading, row.isInside ? AppTheme.Space.l : 0)
                        .accessibilityIdentifier("household.category.\(row.category.name)")
                    }
                } header: {
                    Text(group.name ?? "Library")
                }
            }
        }
        Section {
            Toggle("From Outside", isOn: $draft.allowOutside)
                .accessibilityIdentifier("household.allowOutside")
            Toggle("New Devices Need Your Approval", isOn: $draft.requiresAdminApproval)
                .accessibilityIdentifier("household.requiresAdminApproval")
            Toggle("Limit the Speed", isOn: Binding(
                get: { draft.maxMbps != nil }, set: { on in draft.maxMbps = on ? (draft.maxMbps ?? 20) : nil }))
                .accessibilityIdentifier("household.capOn")
            if let mbps = draft.maxMbps {
                Stepper(
                    HouseholdsModel.cap(mbps),
                    value: Binding(get: { mbps }, set: { draft.maxMbps = $0 }), in: 2...200, step: 2)
                    .accessibilityIdentifier("household.cap")
            }
            Toggle("Limit the Devices", isOn: Binding(
                get: { draft.maxDevices != nil }, set: { on in draft.maxDevices = on ? (draft.maxDevices ?? 6) : nil }))
                .accessibilityIdentifier("household.devicesOn")
            if let most = draft.maxDevices {
                Stepper(
                    most == 1 ? "1 device" : "\(most) devices",
                    value: Binding(get: { most }, set: { draft.maxDevices = $0 }), in: 1...100)
                    .accessibilityIdentifier("household.maxDevices")
            }
        } header: {
            Text("What They Use")
        } footer: {
            Text("They live elsewhere, so they come in from outside. With approval on, a device their household admin lets in also waits for your yes. The speed is for all their devices together, films and downloads alike.")
        }
    }
}

/// The owner fills in a new household and gets its invitation.
struct InviteHouseholdSheet: View {
    let model: HouseholdsModel
    let groups: CategoryGroups
    @Environment(\.dismiss) private var dismiss
    @State private var draft = HouseholdsModel.Draft()

    var body: some View {
        LobbySheet(
            title: "Invite a Household", width: 560, height: 680,
            confirm: .init(title: "Invite", isEnabled: draft.isValid && !model.isWorking) {
                if await model.invite(draft) { dismiss() }
            }
        ) {
            LobbyForm {
                HouseholdLimitsSections(draft: $draft, groups: groups)
                Section {
                    Picker("Valid For", selection: $draft.inviteHours) {
                        Text("A Day").tag(24)
                        Text("Three Days").tag(72)
                        Text("A Week").tag(168)
                        Text("Two Weeks").tag(336)
                    }
                    .accessibilityIdentifier("household.inviteHours")
                } footer: {
                    Text("The invitation lets one device in, once: it becomes the manager of their household and adds their other devices and viewers. You approve it by comparing six digits with them.")
                }
            }
        }
    }
}

/// A household's invitation, shown once: the code, a QR code of the link, and sending it along.
struct InvitationSection: View {
    let invitation: HouseholdsModel.Invitation

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: AppTheme.Space.l) {
                if let link = invitation.link {
                    QRCodeView(text: link, size: 148, label: "Invitation, for a camera")
                }
                VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                    Text("Code").font(.footnote).foregroundStyle(.lobbySecondary)
                    Text(invitation.code)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .minimumScaleFactor(0.6)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("invitation.code")
                    if let introducer = invitation.invite.introducer {
                        Text("Address").font(.footnote).foregroundStyle(.lobbySecondary)
                        Text(IntroducerAddress(introducer)?.display ?? introducer)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text("Until \(invitation.expires, format: .dateTime.day().month().hour().minute()), for one device.")
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                }
            }
            .padding(.vertical, AppTheme.Space.s)
            if let link = invitation.link {
                ShareLink("Send to \(invitation.householdName)…", item: link)
                    .accessibilityIdentifier("invitation.share")
            }
        } header: {
            Label("For \(invitation.householdName)", systemImage: AppSymbol.households)
        } footer: {
            Text(invitation.link == nil
                ? "The direct connection is not set up on Lobby Server: they come in over the outside entrance with this code."
                : "They open the link, or scan the code, in Lobby on their device and choose “Pair From Outside”. It is shown only now. When they are in, they read six digits to you, which you compare in Access From Outside.")
        }
    }
}

/// Whose server this is and whose household this device is in, for a guest.
struct HouseholdLabelSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            LabeledContent("Server", value: app.connection?.serverName ?? app.serverInfo?.name ?? "")
                .accessibilityIdentifier("household.server")
            LabeledContent("Household", value: app.household?.name ?? "")
                .accessibilityIdentifier("household.label")
        } header: {
            Label("Shared With You", systemImage: AppSymbol.households)
        } footer: {
            Text("The library is the server owner's. You manage your own household's devices and viewers.")
        }
    }
}

/// Inviting someone: into this household, as a viewer or household admin, or (a server admin
/// only) into a new household of their own.
struct InviteSomeoneSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: HouseholdsModel
    @State private var target: Target = .here
    @State private var access: DeviceAccess = .viewer
    @State private var hours = 72
    @State private var draft = HouseholdsModel.Draft()

    enum Target: Hashable { case here, newHousehold }

    var body: some View {
        LobbySheet(
            title: "Invite Someone", width: 560, height: 680,
            confirm: .init(
                title: "Invite", isEnabled: !model.isWorking && (target == .here || draft.isValid)
            ) {
                let done: Bool
                if target == .here {
                    done = await model.inviteHere(access: access, hours: hours)
                } else {
                    draft.inviteHours = hours
                    done = await model.invite(draft)
                }
                if done { dismiss() }
            }
        ) {
            LobbyForm {
                if app.isOwnerManager {
                    Section {
                        Picker("Into", selection: $target) {
                            Text("This Household").tag(Target.here)
                            Text("A New Household").tag(Target.newHousehold)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("invite.target")
                    } footer: {
                        Text(target == .here
                            ? "Someone of your own household, also when they are elsewhere."
                            : "Another household with its own viewers, kids and devices: its first device becomes its household admin.")
                    }
                }
                if target == .here {
                    Section {
                        Picker("As", selection: $access) {
                            Text("Viewer").tag(DeviceAccess.viewer)
                            Text("Household Admin").tag(DeviceAccess.householdAdmin)
                        }
                        .accessibilityIdentifier("invite.access")
                    } footer: {
                        Text("A household admin sets up this household's viewers, kids and devices.")
                    }
                } else {
                    HouseholdLimitsSections(draft: $draft, groups: app.categoryGroups)
                }
                Section {
                    Picker("Valid For", selection: $hours) {
                        Text("A Day").tag(24)
                        Text("Three Days").tag(72)
                        Text("A Week").tag(168)
                        Text("Two Weeks").tag(336)
                    }
                    .accessibilityIdentifier("invite.hours")
                } footer: {
                    Text("It lets one device in, once, from wherever it is. You approve it by comparing six digits with them.")
                }
            }
        }
    }
}
