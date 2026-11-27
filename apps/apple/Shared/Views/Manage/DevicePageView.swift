// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A device's page for a manager: what it should hold, how far it is and what is in the way.
struct DevicePageView: View {
    let deviceID: String
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var model: DevicePageModel
    @State private var isAdding = false
    @State private var rowToRemove: WantedRow?
    @State private var confirmsRemoval = false

    init(app: AppModel, deviceID: String) {
        self.deviceID = deviceID
        _model = State(initialValue: DevicePageModel(app: app, deviceID: deviceID))
    }

    var body: some View {
        LobbyForm {
            if let detail = model.detail {
                deviceSection(detail)
                if model.canChangeAccess { accessSection }
                if model.canBeBound { kidsSection }
                if model.offersOutside, detail.device.platform != .cli { outsideSection }
                wantedSection(detail)
                if !model.own.isEmpty {
                    ownSection
                }
                if detail.device.id != app.device?.id {
                    Section {
                        Button("Remove Device", systemImage: AppSymbol.remove, role: .destructive) { confirmsRemoval = true }
                            .accessibilityIdentifier("device.remove")
                    } footer: {
                        Text("It can no longer reach the library until it is paired again. What it downloaded stays on it.")
                    }
                }
            }
        }
        .overlay {
            if model.isGone {
                ContentUnavailableView("This device was removed", systemImage: AppSymbol.devices)
            } else if model.detail == nil {
                ProgressView()
            }
        }
        .navigationTitle(model.detail?.device.name ?? "Device")
        .task { await model.watch() }
        .sheet(isPresented: $isAdding, onDismiss: { Task { await model.refresh() } }) {
            AddToDeviceView(deviceID: deviceID, deviceName: model.detail?.device.name ?? "the device")
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
            rowToRemove.map { "Take “\($0.title)” off \(model.detail?.device.name ?? "this device")?" } ?? "",
            isPresented: Binding(get: { rowToRemove != nil }, set: { if !$0 { rowToRemove = nil } }),
            titleVisibility: .visible, presenting: rowToRemove
        ) { row in
            Button("Take Off", role: .destructive) {
                Task { await model.remove(row) }
            }
            .accessibilityIdentifier("device.confirmTakeOff")
        } message: { _ in
            Text("The device removes its copies the next time it talks to Lobby Server. What the person downloaded themselves stays.")
        }
        .confirmationDialog(
            "Remove “\(model.detail?.device.name ?? "")”?", isPresented: $confirmsRemoval, titleVisibility: .visible
        ) {
            Button("Remove Device", role: .destructive) {
                Task {
                    if await app.manager().remove(deviceID: deviceID) { dismiss() } else { model.problem = app.manager().takeProblem() }
                }
            }
            .accessibilityIdentifier("manage.confirmRemoveDevice")
        }
    }

    // MARK: The device

    private func deviceSection(_ detail: DeviceWantedDetail) -> some View {
        Section {
            LabeledContent {
                Text("\(ManagerModel.name(detail.device.platform)) · \(ManagerModel.name(model.device?.level ?? (detail.device.role == .manager ? .admin : .viewer)))")
            } label: {
                Label("Device", systemImage: ManagerModel.symbol(detail.device.platform))
            }
            LabeledContent {
                Text(DeviceProgress.seen(detail.device.lastSeenAt, now: Date()))
            } label: {
                Label("Last Seen", systemImage: AppSymbol.seen)
            }
            LabeledContent {
                Text(DeviceProgress.space(detail.storage) ?? "Not reported yet")
            } label: {
                Label("Space", systemImage: AppSymbol.space)
            }
            if detail.bytesToFetch > 0 {
                LabeledContent {
                    Text(MediaFormat.size(bytes: detail.bytesToFetch))
                } label: {
                    Label("Still to Fetch", systemImage: AppSymbol.underway)
                }
            }
            if detail.fits == false {
                Label("This does not fit in the free space. What fits is fetched, in order; nothing is deleted to make room.", systemImage: AppSymbol.problem)
                    .foregroundStyle(Color.lobbyWarning)
                    .accessibilityIdentifier("device.doesNotFit")
            }
            if detail.leftOut > 0 {
                Label("\(detail.leftOut) files are beyond what a device takes at once and are left out.", systemImage: AppSymbol.problem)
                    .foregroundStyle(Color.lobbyWarning)
            }
        }
    }

    // MARK: What it may do

    private var accessSection: some View {
        Section {
            Picker(selection: Binding(
                get: { model.device?.level ?? .viewer },
                set: { access in Task { await model.setAccess(access) } })
            ) {
                ForEach(model.grantable, id: \.self) { access in
                    Text(ManagerModel.name(access)).tag(access)
                }
            } label: {
                Label("Role", systemImage: AppSymbol.approveAsManager)
            }
            .accessibilityIdentifier("device.access")
        } footer: {
            Text("A viewer watches. A household admin sets up this household's viewers, kids and devices, and invites others to it. A server admin can do everything, the server's settings and other households too.")
        }
    }

    // MARK: Whose it is

    private var kidsSection: some View {
        Section {
            Picker(selection: Binding(get: { model.device?.kidsProfileId }, set: { id in Task { await model.bind(to: id) } })) {
                Text("Everyone").tag(String?.none)
                ForEach(model.kidsViewers) { profile in
                    Text(profile.name).tag(String?.some(profile.id))
                }
                // Bound to a viewer that is gone, or no kids viewer any more.
                if let bound = model.device?.kidsProfileId, !model.kidsViewers.contains(where: { $0.id == bound }) {
                    Text("A removed viewer").tag(String?.some(bound))
                }
            } label: {
                Label("This Device Is For", systemImage: AppSymbol.kids)
            }
            .disabled(model.isBinding || (model.kidsViewers.isEmpty && model.device?.kidsProfileId == nil))
            .accessibilityIdentifier("device.kids")
        } footer: {
            Text(model.kidsViewers.isEmpty
                ? "Make a viewer a kids viewer first, to give it this device."
                : "A device for a kids viewer shows that viewer and nothing else. Only a manager can change it, from here.")
        }
    }

    // MARK: From outside

    private var outsideSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.device?.allowOutside ?? false }, set: { allowed in Task { await model.allowOutside(allowed) } })
            ) {
                Label("Access From Outside", systemImage: AppSymbol.outside)
            }
            .disabled(model.isAllowing)
            .accessibilityIdentifier("device.outside")
        } footer: {
            Text("Lets this device reach Lobby Server when it is neither at home nor on Tailscale. Open Lobby on it at home once, so that it can get ready. Turning it off ends its connections at once.")
        }
    }

    // MARK: Its list

    private func wantedSection(_ detail: DeviceWantedDetail) -> some View {
        Section {
            if model.rows.isEmpty {
                Text("Nothing yet. Add films and series here, or choose Send to Device on their own pages.")
                    .foregroundStyle(.lobbySecondary)
            }
            ForEach(model.rows) { row in
                WantedRowView(row: row) { rowToRemove = row }
            }
            Button("Add Films and Series…", systemImage: AppSymbol.add) { isAdding = true }
                .accessibilityIdentifier("device.add")
        } header: {
            Label("Sent to This Device", systemImage: AppSymbol.sendToDevice)
        } footer: {
            Text("The device fetches these by itself while Lobby is open on it, and in the background as far as the system allows.")
        }
    }

    private var ownSection: some View {
        Section {
            ForEach(model.own) { row in
                LabeledContent {
                    Text(row.caption)
                } label: {
                    Text(row.title)
                }
            }
        } header: {
            Label("Downloaded on the Device Itself", systemImage: AppSymbol.downloads)
        } footer: {
            Text("Chosen by the person on the device. Your list never touches these.")
        }
    }
}

/// One thing on a device's list, with its files under it.
private struct WantedRowView: View {
    let row: WantedRow
    let remove: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isOpen = false

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            ForEach(row.files) { file in
                WantedFileView(file: file)
            }
        } label: {
            HStack(spacing: AppTheme.Space.m) {
                ArtworkView(artwork: row.artwork, width: 40) {
                    Color.lobbySurfaceRaised(scheme)
                }
                .frame(width: 40, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                    Text(row.what)
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.xs) {
                        Image(systemName: symbol)
                            .accessibilityHidden(true)
                        Text(summary)
                    }
                        .font(.footnote)
                        .foregroundStyle(row.problems > 0 ? Color.lobbyWarning : .secondary)
                    if !row.isComplete, row.fraction > 0 {
                        ProgressBar(fraction: row.fraction, track: Color.lobbySurfaceRaised(scheme), fill: Color.lobbyAccent(scheme))
                    }
                }
                Spacer(minLength: 0)
                Button("Take Off", systemImage: AppSymbol.remove, role: .destructive, action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.lobbyIcon)
                    .accessibilityLabel("Take \(row.title) off this device")
                    .accessibilityIdentifier("device.takeOff.\(row.title)")
            }
        }
        .accessibilityIdentifier("device.wanted.\(row.title)")
    }

    private var summary: String {
        row.problems > 0 ? "\(row.summary), \(row.problems) cannot be done" : row.summary
    }

    private var symbol: String {
        if row.problems > 0 { return AppSymbol.problem }
        return row.isComplete ? AppSymbol.done : AppSymbol.underway
    }
}

private struct WantedFileView: View {
    let file: WantedFileRow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.title)
                    .font(.subheadline)
                Text([file.state, file.percent, MediaFormat.size(bytes: file.bytes)].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
                if let fraction = file.fraction {
                    ProgressBar(fraction: fraction, track: Color.lobbySurfaceRaised(scheme), fill: Color.lobbyAccent(scheme))
                }
                if let reason = file.reason {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                }
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(file.accessibilityLabel)
    }

    private var symbol: String {
        switch file.kind {
        case .onDevice: AppSymbol.done
        case .moving: AppSymbol.underway
        case .waiting: AppSymbol.waiting
        case .problem: AppSymbol.problem
        }
    }

    private var tint: Color {
        switch file.kind {
        case .onDevice, .moving: .lobbyAccent(scheme)
        case .waiting: .secondary
        case .problem: .lobbyWarning
        }
    }
}

/// Find a film or series for one device.
private struct AddToDeviceView: View {
    let deviceID: String
    let deviceName: String

    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var chosen: Item?

    var body: some View {
        let found = Self.results(query, in: app.wholeCatalogue)
        LobbySheet(title: "Add to \(deviceName)", width: 520, height: 560) {
            List(found) { item in
                Button {
                    chosen = item
                } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .foregroundStyle(.primary)
                                Text([item.kind == .show ? "Series" : "Film", item.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.footnote)
                                    .foregroundStyle(.lobbySecondary)
                            }
                        } icon: {
                            Image(systemName: item.kind == .show ? AppSymbol.series : AppSymbol.movies)
                                .foregroundStyle(.lobbySecondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.lobbyRow)
                .accessibilityIdentifier("device.add.\(item.title)")
                .lobbyPanelRow(isFirst: item.id == found.first?.id, isLast: item.id == found.last?.id)
            }
            .searchable(text: $query, placement: Self.placement, prompt: "Films and series")
            .sheet(item: $chosen) { item in
                SendToDeviceView(model: SendToDeviceModel(app: app, item: item, deviceID: deviceID))
            }
        }
    }

    private static var placement: SearchFieldPlacement {
        #if os(macOS)
        .automatic
        #else
        .navigationBarDrawer(displayMode: .always)
        #endif
    }

    /// Everything that can be sent, by title, while nothing is typed.
    static func results(_ query: String, in catalogue: Catalogue) -> [Item] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty {
            return Shelves.search(typed, in: catalogue)
        }
        return catalogue.items
            .filter { $0.kind == .movie || $0.kind == .show || $0.kind == .personal }
            .sorted { $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending }
    }
}
