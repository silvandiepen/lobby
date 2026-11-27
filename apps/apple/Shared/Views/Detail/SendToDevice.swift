// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Send to Device on a film's or series' page. Only on a manager's device.
struct SendToDeviceButton: View {
    let item: Item

    @Environment(AppModel.self) private var app
    @State private var isOpen = false

    var body: some View {
        if app.isManager {
            RoundAction(name: "Send") {
                Button {
                    isOpen = true
                } label: {
                    RoundLabel(symbol: AppSymbol.sendToDevice)
                }
                .buttonStyle(.lobbyPill)
                .accessibilityLabel("Send to Device")
                .accessibilityHint("Chooses a device of the household to keep this on")
                .accessibilityIdentifier("detail.sendToDevice")
            }
            .sheet(isPresented: $isOpen) {
                SendToDeviceView(model: SendToDeviceModel(app: app, item: item))
            }
        }
    }
}

/// The same for the season on screen, beside Download Season.
struct SendSeasonButton: View {
    let seasonID: String
    let seasonName: String

    @Environment(AppModel.self) private var app
    @State private var isOpen = false

    var body: some View {
        if app.isManager, let season = app.item(seasonID) {
            Button {
                isOpen = true
            } label: {
                Label("Send \(seasonName)", systemImage: AppSymbol.sendToDevice)
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.lobbyText)
            .accessibilityLabel("Send \(seasonName) to a device")
            .accessibilityIdentifier("show.sendSeason")
            .sheet(isPresented: $isOpen) {
                SendToDeviceView(model: SendToDeviceModel(app: app, item: season))
            }
        }
    }
}

/// What to send, and the household's devices to send it to.
struct SendToDeviceView: View {
    @Environment(AppModel.self) private var app
    @State private var model: SendToDeviceModel

    init(model: @autoclosure @escaping () -> SendToDeviceModel) {
        _model = State(wrappedValue: model())
    }

    var body: some View {
        @Bindable var model = model
        LobbySheet(title: "Send to Device", width: 500, height: 520) {
            LobbyForm {
                Section {
                    if model.choices.count > 1 {
                        Picker("What", selection: $model.what) {
                            ForEach(model.choices) { choice in
                                Text(choice.title).tag(choice.what)
                            }
                        }
                        .accessibilityIdentifier("send.what")
                    } else {
                        LabeledContent("What", value: model.choices.first?.title ?? model.item.title)
                    }
                    if model.what == .nextEpisodes {
                        Picker("Viewer", selection: $model.profileID) {
                            ForEach(model.viewers) { viewer in
                                Text(viewer.name).tag(Optional(viewer.id))
                            }
                        }
                        .accessibilityIdentifier("send.viewer")
                        Stepper(value: $model.count, in: WantedRequest.countLimits) {
                            LabeledContent("Episodes", value: String(model.count))
                        }
                        .accessibilityIdentifier("send.count")
                    }
                } header: {
                    Label(app.wholeCatalogue.show(of: model.item)?.title ?? model.item.title, systemImage: symbol)
                } footer: {
                    if model.what == .nextEpisodes {
                        Text("Keeps the next unwatched episodes on the device: a watched one makes room for the one after it.")
                    }
                }

                Section {
                    if !model.hasLoaded {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(model.targets) { target in
                        row(target)
                    }
                } header: {
                    Label("Devices", systemImage: AppSymbol.devices)
                } footer: {
                    Text("A device fetches what it is sent by itself, when Lobby is open on it and it reaches Lobby Server.")
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
        .task { await model.load() }
    }

    private var symbol: String {
        app.wholeCatalogue.show(of: model.item) == nil ? AppSymbol.movies : AppSymbol.series
    }

    private func row(_ target: SendToDeviceModel.Target) -> some View {
        HStack(spacing: AppTheme.Space.m) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.device.name)
                    Text([
                        target.device.id == app.device?.id ? "This device" : DeviceProgress.seen(target.device.lastSeenAt, now: Date()),
                        DeviceProgress.space(target.device.storage),
                    ].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                    if let entry = target.entry {
                        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.xs) {
                            Image(systemName: AppSymbol.done)
                                .accessibilityHidden(true)
                            Text(entry.kind == .nextUnwatched ? "\(WantedRow.nextEpisodes(entry.count ?? 1)) on its list" : "On its list")
                        }
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                    }
                }
            } icon: {
                Image(systemName: ManagerModel.symbol(target.device.platform))
                    .foregroundStyle(.lobbySecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("send.device.\(target.device.name)")
            Spacer(minLength: 0)
            if model.busy == target.id {
                ProgressView()
                    .controlSize(.small)
            } else if target.entry == nil || model.changesCount(target) {
                Button(target.entry == nil ? "Send" : "Change", systemImage: AppSymbol.sendToDevice) {
                    Task { await model.send(to: target) }
                }
                .buttonStyle(.lobbyText)
                .disabled(model.request == nil || model.busy != nil)
                .accessibilityLabel("Send to \(target.device.name)")
                .accessibilityIdentifier("send.send.\(target.device.name)")
            } else {
                Button("Take Off", systemImage: AppSymbol.remove, role: .destructive) {
                    Task { await model.takeOff(target) }
                }
                .buttonStyle(.lobbyText)
                .disabled(model.busy != nil)
                .accessibilityLabel("Take off \(target.device.name)")
                .accessibilityIdentifier("send.takeOff.\(target.device.name)")
            }
        }
    }
}
