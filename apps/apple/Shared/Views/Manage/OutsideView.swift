// SPDX-License-Identifier: MPL-2.0
import LobbyDirect
import LobbyKit
import SwiftUI

/// Access from outside, for a manager: on or off, a new device, and who was there.
struct OutsideView: View {
    @Environment(AppModel.self) private var app
    @State private var model: OutsideModel
    @State private var isScanning = false

    init(app: AppModel) {
        _model = State(initialValue: OutsideModel(app: app))
    }

    var body: some View {
        LobbyForm {
            if model.isGuest {
                // A guest household's manager: the switch and the server are the owner's.
                ForEach(model.requests) { request in
                    OutsideRequestSection(request: request, isWorking: model.isWorking) {
                        Task { await model.approve(request) }
                    } refuse: {
                        Task { await model.refuse(request) }
                    }
                }
                windowSection
                accessSection
            } else if model.status != nil, !model.isUnavailable {
                switchSection
                if model.isOn {
                    ForEach(model.requests) { request in
                        OutsideRequestSection(request: request, isWorking: model.isWorking) {
                            Task { await model.approve(request) }
                        } refuse: {
                            Task { await model.refuse(request) }
                        }
                    }
                    windowSection
                }
                accessSection
            }
        }
        .overlay {
            if model.isUnavailable, !model.isGuest {
                ContentUnavailableView(
                    "Not set up on the server", systemImage: AppSymbol.outside,
                    description: Text("Access from outside is turned on in Lobby Server's own configuration first."))
            } else if model.status == nil, model.problem == nil, !model.isGuest {
                ProgressView()
            }
        }
        .navigationTitle(model.isGuest ? "Add a Device" : "Access From Outside")
        .task { await model.watch() }
        .alert(
            "That did not work",
            isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
        #if os(iOS)
        .sheet(isPresented: $isScanning) {
            QRScannerSheet(title: "Scan the Apple TV's Code") { scanned in
                isScanning = false
                Task { await model.send(to: scanned) }
            }
        }
        #endif
    }

    private var switchSection: some View {
        Section {
            Toggle("Access From Outside", isOn: Binding(get: { model.isOn }, set: { on in Task { await model.setOn(on) } }))
                .disabled(model.isWorking)
                .accessibilityIdentifier("outside.enabled")
            Text(model.summary)
                .foregroundStyle(.lobbySecondary)
                .accessibilityIdentifier("outside.status")
        } footer: {
            Text("Films go straight from Lobby Server to the device, encrypted, and through no one else's service. Which devices may is on each device's own page. Turning this off ends every connection at once.")
        }
    }

    @ViewBuilder
    private var windowSection: some View {
        Section {
            if let invitation = model.invitation, let window = model.window {
                HStack(alignment: .center, spacing: AppTheme.Space.l) {
                    QRCodeView(text: invitation.link, size: 148, label: "Code to pair with, for a camera")
                    VStack(alignment: .leading, spacing: AppTheme.Space.s) {
                        Text("Code").font(.footnote).foregroundStyle(.lobbySecondary)
                        Text(PairingCode.grouped(invitation.code))
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .minimumScaleFactor(0.6)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("outside.code")
                        Text("Address").font(.footnote).foregroundStyle(.lobbySecondary)
                        Text(invitation.introducer.display)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("outside.introducer")
                        Text("Until \(window.expiresAt, format: .dateTime.hour().minute()), for one device.")
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                    }
                }
                .padding(.vertical, AppTheme.Space.s)
                #if os(iOS)
                Button("Send to an Apple TV Here…", systemImage: AppSymbol.scan) { isScanning = true }
                    .accessibilityIdentifier("outside.sendToTV")
                handOverNote
                #endif
                ShareLink("Send to Someone…", item: invitation.link)
                Button("Close", systemImage: AppSymbol.remove, role: .destructive) { Task { await model.closeWindow() } }
                    .accessibilityIdentifier("outside.closeWindow")
            } else {
                Button("Pair a Device From Outside…", systemImage: AppSymbol.add) { Task { await model.openWindow() } }
                    .disabled(model.isWorking || (!model.isGuest && model.status?.direct?.introducer != true))
                    .accessibilityIdentifier("outside.openWindow")
            }
            if let approval = model.lastApproval {
                Label(approval, systemImage: "checkmark.circle.fill").foregroundStyle(.lobbySecondary)
            }
        } header: {
            Label("New Device", systemImage: AppSymbol.add)
        } footer: {
            Text(
                model.isGuest
                    ? "On the new device choose “Pair From Outside” and enter the code and the address, or scan the code with an iPhone or iPad. It joins your household as a viewer; it shows six digits that you compare here."
                    : "On the new device choose “Pair From Outside” and enter the code and the address, or scan the code with an iPhone or iPad. A new device is a viewer; it shows six digits that you compare here.")
        }
    }

    @ViewBuilder
    private var handOverNote: some View {
        switch model.handOver {
        case .none: EmptyView()
        case .sending: Label("Sending…", systemImage: AppSymbol.underway).foregroundStyle(.lobbySecondary)
        case .sent: Label("The Apple TV has the code. It shows six digits in a moment.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.lobbySecondary)
        case .failed(let text): Label(text, systemImage: AppSymbol.problem).foregroundStyle(Color.lobbyWarning)
        }
    }

    private var accessSection: some View {
        Section {
            if model.access.isEmpty {
                Text("Nobody yet.").foregroundStyle(.lobbySecondary)
            }
            ForEach(model.access) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                    Text(row.caption)
                        .font(.footnote)
                        .foregroundStyle(row.isRefusal ? Color.lobbyWarning : .secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Label("Recently", systemImage: AppSymbol.seen)
        }
    }
}

/// A device that waits: the digits, large, and the question that matters. Or, once its household
/// admin compared them, the server admin's yes; or what a server admin said.
private struct OutsideRequestSection: View {
    @Environment(AppModel.self) private var app
    let request: OutsideStatus.Request
    let isWorking: Bool
    let approve: () -> Void
    let refuse: () -> Void

    var body: some View {
        Section {
            LabeledContent("Device", value: "\(request.deviceName) · \(ManagerModel.name(request.platform))")
            if let household = request.householdName, request.householdId != HouseholdSummary.ownerID {
                LabeledContent("Household", value: household)
                    .accessibilityIdentifier("outside.household")
            }
            if let address = request.address {
                LabeledContent("From", value: address)
            }
            if request.invited == true {
                Label(
                    "Invited: it becomes \(ManagerModel.article(request.access ?? .householdAdmin))",
                    systemImage: AppSymbol.households
                )
                .foregroundStyle(.lobbySecondary)
                .accessibilityIdentifier("outside.invited")
            }
            if request.isRefused {
                Label("The server owner turned it away.", systemImage: AppSymbol.problem)
                    .foregroundStyle(Color.lobbyWarning)
                    .accessibilityIdentifier("outside.refused")
            } else if request.awaitsAdmin {
                if app.isOwnerManager {
                    Text("Its household admin compared the digits. Let it in to your server?")
                    Button("Let It In", systemImage: AppSymbol.approve, action: approve)
                        .disabled(isWorking)
                        .accessibilityIdentifier("outside.approve")
                    Button("Refuse", systemImage: AppSymbol.remove, role: .destructive, action: refuse)
                        .disabled(isWorking)
                        .accessibilityIdentifier("outside.refuse")
                } else {
                    Label("Waiting for the server owner to approve.", systemImage: AppSymbol.waiting)
                        .foregroundStyle(.lobbySecondary)
                        .accessibilityIdentifier("outside.awaitingAdmin")
                }
            } else {
                Text(ManagerModel.spaced(request.comparison))
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Digits to compare")
                    .accessibilityValue(request.comparison.map(String.init).joined(separator: " "))
                    .accessibilityIdentifier("outside.comparison")
                Button("The Digits Are the Same: Let It In", systemImage: AppSymbol.approve, action: approve)
                    .disabled(isWorking)
                    .accessibilityIdentifier("outside.approve")
                Button("They Differ: Refuse", systemImage: AppSymbol.remove, role: .destructive, action: refuse)
                    .disabled(isWorking)
                    .accessibilityIdentifier("outside.refuse")
            }
        } header: {
            Label("Waiting to Connect", systemImage: AppSymbol.waiting)
        } footer: {
            if !request.awaitsAdmin && !request.isRefused {
                Text("Look at the new device's own screen, or ask who is in front of it. If the digits differ, someone is in between.")
            }
        }
    }
}
