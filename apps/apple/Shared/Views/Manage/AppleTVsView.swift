// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Settings → Server → Apple TVs: the Apple TVs Lobby Server can turn on for Play On.
struct AppleTVsView: View {
    @State private var model: AppleTVsModel
    @State private var toDisconnect: Television?

    init(app: AppModel) {
        _model = State(initialValue: AppleTVsModel(app: app))
    }

    var body: some View {
        LobbyForm {
            if model.status != nil, !model.isUnavailable {
                switchSection
                if model.isConfigured {
                    if let pairing = model.pairing {
                        pinSection(pairing)
                    }
                    televisionsSection
                }
            }
        }
        .overlay {
            if model.isUnavailable {
                ContentUnavailableView(
                    "Not on this server", systemImage: AppSymbol.television,
                    description: Text("This Lobby Server cannot wake Apple TVs yet. Update it first."))
            } else if model.status == nil, model.problem == nil {
                ProgressView()
            }
        }
        .navigationTitle("Apple TVs")
        .task { await model.watch() }
        .refreshable { await model.load() }
        .alert(
            "That did not work",
            isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
        .confirmationDialog(
            "Disconnect \(toDisconnect?.name ?? "")?",
            isPresented: Binding(get: { toDisconnect != nil }, set: { if !$0 { toDisconnect = nil } }),
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                if let tv = toDisconnect { Task { await model.disconnect(tv) } }
                toDisconnect = nil
            }
        } message: {
            Text("Play On no longer turns it on. On the Apple TV, “Lobby” stays under Settings → Remotes and Devices until it is removed there.")
        }
    }

    private var switchSection: some View {
        Section {
            Toggle(
                "Wake Apple TVs",
                isOn: Binding(get: { model.isEnabled }, set: { on in Task { await model.setEnabled(on) } })
            )
            .disabled(model.isWorking || !model.isConfigured)
            .accessibilityIdentifier("appleTVs.enabled")
            Toggle(
                "Kids can turn on the TV",
                isOn: Binding(get: { model.kidsMayWake }, set: { on in Task { await model.setKidsMayWake(on) } })
            )
            .disabled(model.isWorking || !model.isConfigured || !model.isEnabled)
            .accessibilityIdentifier("appleTVs.kids")
            Text(model.summary)
                .foregroundStyle(.lobbySecondary)
                .accessibilityIdentifier("appleTVs.status")
        } footer: {
            Text("Play On turns a connected Apple TV on and opens Lobby there, then plays. In kids mode only when kids can turn on the TV: otherwise kids see only TVs that are on with Lobby open. It uses the protocol of Apple’s own remote, which Apple does not offer to other apps: a tvOS update can stop it working, and then Play On offers AirPlay as before.")
        }
    }

    private func pinSection(_ pairing: TelevisionPairing) -> some View {
        let name = model.television(pairing.televisionId)?.name ?? "The Apple TV"
        return Section {
            Text("\(name) shows a code now. Type it here.")
            TextField("Code", text: $model.pin)
                .font(.system(.title3, design: .monospaced))
                #if os(iOS)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                #endif
                .onSubmit { Task { await model.submitPin() } }
                .accessibilityIdentifier("appleTVs.pin")
            HStack(spacing: AppTheme.Space.m) {
                Button("Connect") { Task { await model.submitPin() } }
                    .buttonStyle(ProminentButtonStyle())
                    .busy(model.isWorking)
                    .disabled(model.pin.filter(\.isNumber).count != 4)
                    .accessibilityIdentifier("appleTVs.submitPin")
                Button("Cancel") { Task { await model.cancelPairing() } }
                    .buttonStyle(QuietButtonStyle())
            }
        } header: {
            Label("Connect \(name)", systemImage: AppSymbol.television)
        } footer: {
            Text("Within a minute, until \(pairing.expiresAt, format: .dateTime.hour().minute().second()).")
        }
    }

    private var televisionsSection: some View {
        Section {
            ForEach(model.status?.televisions ?? []) { tv in
                row(tv)
            }
            Button {
                Task { await model.scan() }
            } label: {
                Label(model.isScanning ? "Looking…" : "Look for Apple TVs", systemImage: AppSymbol.refresh)
            }
            .disabled(model.isScanning || model.status?.running != true)
            .accessibilityIdentifier("appleTVs.scan")
        } header: {
            Label("On This Network", systemImage: AppSymbol.television)
        } footer: {
            Text("Connect each Apple TV once, then say which Lobby device it is: Apple TVs do not tell apps who they are, so Lobby goes by the name.")
        }
    }

    private func row(_ tv: Television) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
            HStack(spacing: AppTheme.Space.m) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tv.name)
                        Text(AppleTVsModel.state(of: tv, devices: model.devices, looked: model.status?.scannedAt != nil))
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                    }
                } icon: {
                    Image(systemName: AppSymbol.television)
                        .foregroundStyle(.lobbySecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("appleTVs.tv.\(tv.name)")
                Spacer(minLength: 0)
                if tv.paired {
                    Button("Disconnect", role: .destructive) { toDisconnect = tv }
                        .buttonStyle(.lobbyText)
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("appleTVs.disconnect.\(tv.name)")
                } else if tv.found {
                    Button("Connect") { Task { await model.connect(tv) } }
                        .buttonStyle(.lobbyText)
                        .disabled(model.isWorking || model.pairing != nil)
                        .accessibilityIdentifier("appleTVs.connect.\(tv.name)")
                }
            }
            if tv.paired {
                if let suggested = model.suggestion(for: tv) {
                    HStack {
                        Text("Is it “\(suggested.name)” in Lobby?")
                            .font(.footnote)
                        Spacer(minLength: 0)
                        Button("Yes") { Task { await model.link(tv, to: suggested.id) } }
                            .buttonStyle(.lobbyText)
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("appleTVs.confirm.\(tv.name)")
                    }
                }
                Picker(
                    "Lobby Device",
                    selection: Binding(get: { tv.deviceId }, set: { id in Task { await model.link(tv, to: id) } })
                ) {
                    Text("None").tag(String?.none)
                    ForEach(model.devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("appleTVs.device.\(tv.name)")
            }
        }
    }
}
