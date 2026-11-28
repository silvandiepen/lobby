// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// One page of the server's settings, for a server admin at home or over Tailscale: the few
/// settings of one subject, in plain words, changed here and explained before they are made.
/// Each page reviews and saves its own changes (docs/decisions.md, "Settings, one page per
/// subject").
struct ServerSettingsPage: View {
    let page: SettingsPage
    @State private var model: ServerSettingsModel
    /// The folder being picked. Held here, outside the list: a sheet on a section or a row of
    /// the lazy list closed again at once, and took Settings with it.
    @State private var picking: FolderPick?
    @Environment(AppModel.self) private var app

    init(app: AppModel, page: SettingsPage) {
        self.page = page
        _model = State(initialValue: app.serverSettings())
    }

    var body: some View {
        LobbyForm {
            if model.settings != nil {
                RestartNotice(model: model)
                content
                SettingsPageNote(page: page)
            }
        }
        .serverSettingsChanges(model: model, page: page)
        .navigationTitle(page.title)
        .sheet(item: $picking) { pick in
            FolderPickerSheet(app: model.appForPicker, purpose: pick.purpose) { path, hint, kids in
                switch pick {
                case .library: model.addFolder(path: path, hint: hint, forKids: kids)
                case .importFolder: model.addImportFolder(path: path, mode: hint)
                case .setting(let key): model.set(key, .string(path))
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .libraryFolders:
            FoldersSection(model: model) { picking = .library }
            ServerSettingRows(model: model, page: page) { picking = $0 }
        case .imports:
            ImportFoldersSection(model: model) { picking = .importFolder }
            ServerSettingRows(model: model, page: page) { picking = $0 }
            if app.uploads().isAvailable {
                Section {
                    NavigationLink(value: Route.uploads) {
                        Label("Upload", systemImage: AppSymbol.upload)
                    }
                    .accessibilityIdentifier("manage.uploads")
                } footer: {
                    Text("Films and episodes from this device.")
                }
            }
        case .matching:
            TMDBKeySection(model: model)
        case .away:
            ServerSettingRows(model: model, page: page) { picking = $0 }
            Section {
                NavigationLink(value: Route.outside) {
                    Label("Access From Outside", systemImage: AppSymbol.outside)
                }
                .accessibilityIdentifier("manage.outside")
            } footer: {
                Text("For devices that are neither at home nor on Tailscale.")
            }
        case .statistics:
            Section {
                NavigationLink(value: Route.serverStats) {
                    Label("What Is Watched", systemImage: "chart.bar.xaxis")
                }
                .accessibilityIdentifier("serverSettings.statistics")
            }
            ServerSettingRows(model: model, page: page) { picking = $0 }
        case .advanced:
            ServerSettingRows(model: model, page: page) { picking = $0 }
            Section {
                NavigationLink("All Settings, as Stored") { RawSettingsView(model: model) }
                    .accessibilityIdentifier("serverSettings.raw")
                NavigationLink("Earlier Versions") { SettingsHistoryView(model: model) }
                    .accessibilityIdentifier("serverSettings.history")
            } footer: {
                Text("Where the server listens, its data folder and the programs it runs are set in its own file, lobby.config.json, on the server.")
            }
        default:
            ServerSettingRows(model: model, page: page) { picking = $0 }
        }
    }
}

/// The settings of a page that pages of their own (the Apple TVs) show below their controls:
/// what the restart is doing, then the rows.
struct ServerSettingsExtra: View {
    let model: ServerSettingsModel
    let page: SettingsPage

    var body: some View {
        if model.settings != nil {
            RestartNotice(model: model)
            ServerSettingRows(model: model, page: page) { _ in }
        }
    }
}

/// The one line under a page that says what it is for.
struct SettingsPageNote: View {
    let page: SettingsPage

    var body: some View {
        Section {
        } footer: {
            Text(page.summary)
                .accessibilityIdentifier("settings.note.\(page.rawValue)")
        }
    }
}

extension View {
    /// The changes of a page of server settings: the bar to undo or review them, the review,
    /// loading, and what went wrong. `waits`: shows that the settings are loading.
    func serverSettingsChanges(model: ServerSettingsModel, page: SettingsPage, waits: Bool = true) -> some View {
        modifier(ServerSettingsChanges(model: model, page: page, waits: waits))
    }
}

private struct ServerSettingsChanges: ViewModifier {
    let model: ServerSettingsModel
    let page: SettingsPage
    let waits: Bool
    @State private var showsReview = false
    @Environment(\.motion) private var motion

    private var keys: Set<String> { page.draftKeys(among: model.settings?.settings.map(\.key) ?? []) }

    func body(content: Content) -> some View {
        let changed = model.hasChanges(in: keys)
        content
            .overlay {
                if waits, model.settings == nil {
                    if let problem = model.problem {
                        ContentUnavailableView(
                            "The settings cannot be shown", systemImage: AppSymbol.server, description: Text(problem))
                    } else {
                        ProgressView()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if changed {
                    ChangesBar(model: model, keys: keys) { showsReview = true }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(motion.animation(.change), value: changed)
            .task { await model.load() }
            .refreshable { await model.load() }
            .sheet(isPresented: $showsReview, onDismiss: { if model.review != nil { model.cancelReview() } }) {
                ReviewSheet(model: model)
            }
            .alert(
                "That did not work",
                isPresented: Binding(get: { model.problem != nil && model.settings != nil }, set: { if !$0 { model.problem = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.problem ?? "")
            }
    }
}

/// Which folder Settings → Server is picking.
enum FolderPick: Identifiable, Hashable {
    /// A library folder to add.
    case library
    /// An import folder to add.
    case importFolder
    /// The folder of a setting, by its key.
    case setting(String)

    var id: Self { self }

    var purpose: FolderPickerSheet.Purpose {
        switch self {
        case .library: .library
        case .importFolder: .importFolder
        case .setting: .lobbyFolder
        }
    }
}

/// The changes of a page that are not sent yet, and the way to look at what they do.
private struct ChangesBar: View {
    let model: ServerSettingsModel
    let keys: Set<String>
    let review: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Space.m) {
            Button("Undo Changes") { model.discard(keys) }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("serverSettings.discard")
            Button {
                Task {
                    await model.prepareReview(of: keys)
                    if model.review != nil { review() }
                }
            } label: {
                Text(model.changesRestart(in: keys) ? "Review and Restart…" : "Review…")
            }
            .buttonStyle(ProminentButtonStyle())
            .busy(model.isWorking)
            .accessibilityIdentifier("serverSettings.review")
        }
        .padding(AppTheme.Space.page)
        .background(.bar)
    }
}

/// What the server said the change will do, and the button that makes it.
struct ReviewSheet: View {
    let model: ServerSettingsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LobbySheet(
            title: model.restoring.map { "Back to Version \($0)" } ?? "Review Changes",
            confirm: .init(title: model.review?.restart == true ? "Save and Restart" : "Save", isEnabled: model.review != nil) {
                if await model.apply() { dismiss() }
            }
        ) {
            LobbyForm {
                if let review = model.review {
                    Section {
                        if review.effects.isEmpty {
                            Text("Nothing changes.")
                        }
                        ForEach(Array(review.effects.enumerated()), id: \.offset) { _, effect in
                            Label {
                                VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                                    if !effect.title.isEmpty { Text(effect.title).font(.headline) }
                                    Text(effect.message)
                                }
                            } icon: {
                                Image(systemName: effect.apply == "restart" ? AppSymbol.refresh : AppSymbol.done)
                                    .foregroundStyle(effect.apply == "restart" ? Color.lobbyWarning : Color.lobbySuccess)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("What happens")
                    } footer: {
                        Text(review.restart
                            ? "Lobby Server restarts by itself. Playing stops for a few seconds; devices reconnect without help."
                            : "Lobby Server takes this at once. Nothing restarts.")
                    }
                }
            }
            .accessibilityIdentifier("serverSettings.reviewSheet")
        }
    }
}

/// While the server restarts, and when it is back.
private struct RestartNotice: View {
    let model: ServerSettingsModel

    var body: some View {
        switch model.restart {
        case .none:
            if let saved = model.saved {
                Section {
                    Label(saved, systemImage: AppSymbol.done).foregroundStyle(Color.lobbySuccess)
                }
            }
        case .waiting:
            Section {
                HStack(spacing: AppTheme.Space.m) {
                    ProgressView()
                    Text("Lobby Server is restarting to take the new settings…")
                }
                .accessibilityIdentifier("serverSettings.restarting")
            }
        case .back:
            Section {
                Label("Lobby Server restarted with the new settings.", systemImage: AppSymbol.done)
                    .foregroundStyle(Color.lobbySuccess)
                Button("OK") { model.endRestartNotice() }.buttonStyle(.lobbyText)
            }
        case .late:
            Section {
                Label(
                    "Lobby Server is not back yet. It may still be starting; if it stays away, look at it on the machine itself.",
                    systemImage: AppSymbol.problem
                )
                .foregroundStyle(Color.lobbyWarning)
                Button("Look Again") { Task { await model.load(); model.endRestartNotice() } }.buttonStyle(.lobbyText)
            }
        }
    }
}

/// The plain settings of a page, one row each.
private struct ServerSettingRows: View {
    let model: ServerSettingsModel
    let page: SettingsPage
    let pick: (FolderPick) -> Void

    var body: some View {
        let keys = page.rowKeys(among: model.settings?.settings.map(\.key) ?? [])
        let rows = keys.compactMap { model.descriptor($0) }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { descriptor in
                    SettingRow(model: model, descriptor: descriptor) { pick(.setting(descriptor.key)) }
                }
            }
        }
    }
}

/// One setting: the control for its kind, what it does, and whether it restarts the server.
private struct SettingRow: View {
    let model: ServerSettingsModel
    let descriptor: SettingDescriptor
    let pickFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            control
                .disabled(!descriptor.available || model.isWorking)
            Text(descriptor.available ? descriptor.help : (descriptor.unavailableReason ?? descriptor.help))
                .font(.footnote)
                .foregroundStyle(.lobbySecondary)
            if descriptor.restarts {
                Label("Lobby Server restarts to take this.", systemImage: AppSymbol.refresh)
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
            }
        }
        .accessibilityIdentifier("setting.\(descriptor.key)")
    }

    private var value: SettingValue { model.value(descriptor.key) }

    @ViewBuilder
    private var control: some View {
        switch descriptor.type {
        case "toggle":
            Toggle(descriptor.title, isOn: Binding(get: { value.bool ?? false }, set: { model.set(descriptor.key, .bool($0)) }))
        case "integer", "number":
            NumberField(descriptor: descriptor, value: value) { model.set(descriptor.key, $0) }
        case "hours":
            HoursField(title: descriptor.title, value: value) { model.set(descriptor.key, $0) }
        case "folder":
            LabeledContent(descriptor.title) {
                VStack(alignment: .trailing, spacing: AppTheme.Space.xs) {
                    Text(value.string ?? "None")
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.lobbySecondary)
                    HStack {
                        if descriptor.nullable, !value.isNull {
                            Button("None") { model.set(descriptor.key, .null) }.buttonStyle(.lobbyText)
                        }
                        Button("Choose…") { pickFolder() }.buttonStyle(.lobbyText)
                    }
                }
            }
        case "addresses":
            AddressesField(title: descriptor.title, value: value) { model.set(descriptor.key, $0) }
        default:
            TextField(
                descriptor.title,
                text: Binding(get: { value.string ?? "" }, set: { model.set(descriptor.key, .string($0)) }),
                prompt: Text(ServerSettingsModel.describe(descriptor.default)))
            #if os(iOS)
            .textInputAutocapitalization(descriptor.type == "language" ? .never : .words)
            #endif
            .autocorrectionDisabled()
        }
    }
}

extension ServerSettingsModel {
    /// The app, for the sheets that look through the server's folders.
    var appForPicker: AppModel { appModel }
}

/// A whole number or an amount, with "none" where the setting allows it.
private struct NumberField: View {
    let descriptor: SettingDescriptor
    let value: SettingValue
    let change: (SettingValue) -> Void
    @State private var text = ""

    var body: some View {
        LabeledContent(descriptor.title) {
            TextField(descriptor.nullable ? "None" : ServerSettingsModel.describe(descriptor.default), text: $text)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(descriptor.type == "integer" ? .numberPad : .decimalPad)
                #endif
                .frame(maxWidth: 140)
                .onChange(of: text) { _, typed in
                    let trimmed = typed.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        if descriptor.nullable { change(.null) }
                    } else if let number = Double(trimmed.replacingOccurrences(of: ",", with: ".")) {
                        change(.number(number))
                    }
                }
        }
        .onAppear { text = value.isNull ? "" : ServerSettingsModel.describe(value) }
        .onChange(of: value) { _, now in
            let shown = now.isNull ? "" : ServerSettingsModel.describe(now)
            if Double(text.replacingOccurrences(of: ",", with: ".")) != now.number { text = shown }
        }
    }
}

/// "From 01:00 to 07:00", or any hour.
private struct HoursField: View {
    let title: String
    let value: SettingValue
    let change: (SettingValue) -> Void

    var body: some View {
        let hours = ServerSettingsModel.hours(value)
        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
            Toggle("At Any Hour", isOn: Binding(
                get: { hours == nil },
                set: { any in change(any ? .null : ServerSettingsModel.hoursValue(from: 60, to: 7 * 60)) }))
            if let hours {
                DatePicker("From", selection: time(hours.from) { change(ServerSettingsModel.hoursValue(from: $0, to: hours.to)) }, displayedComponents: .hourAndMinute)
                DatePicker("To", selection: time(hours.to) { change(ServerSettingsModel.hoursValue(from: hours.from, to: $0)) }, displayedComponents: .hourAndMinute)
            }
        }
        .accessibilityLabel(title)
    }

    private func time(_ minutes: Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date())
        return Binding(
            get: { midnight.addingTimeInterval(TimeInterval(minutes * 60)) },
            set: { date in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                set((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            })
    }
}

/// A list of addresses, one per line.
private struct AddressesField: View {
    let title: String
    let value: SettingValue
    let change: (SettingValue) -> Void
    @State private var adding = ""

    var body: some View {
        let addresses = value.array?.compactMap(\.string) ?? []
        VStack(alignment: .leading, spacing: AppTheme.Space.s) {
            Text(title)
            ForEach(addresses, id: \.self) { address in
                HStack {
                    Text(address).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") {
                        change(.array(addresses.filter { $0 != address }.map(SettingValue.string)))
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.lobbyIcon)
                }
            }
            HStack {
                TextField("https://lobby.example.ts.net", text: $adding)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Button("Add") {
                    let new = adding.trimmingCharacters(in: .whitespaces)
                    guard !new.isEmpty else { return }
                    change(.array((addresses + [new]).map(SettingValue.string)))
                    adding = ""
                }
                .buttonStyle(.lobbyText)
                .disabled(adding.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// The library folders: what is in each, whether it is for the children, and adding one.
private struct FoldersSection: View {
    let model: ServerSettingsModel
    let add: () -> Void

    var body: some View {
        Section {
            FolderList(model: model)
            Button("Add a Folder…", systemImage: "plus") { add() }
                .accessibilityIdentifier("serverSettings.addFolder")
        } header: {
            Text("Library Folders")
        } footer: {
            Text("Lobby only reads these folders; nothing in them is changed. A folder that is taken away leaves the library, and its watch history comes back when it is added again.")
        }
    }
}

/// The folders as rows, for Settings and for the first setup.
struct FolderList: View {
    let model: ServerSettingsModel

    var body: some View {
        if model.folders.isEmpty {
            Text("No folders yet.")
                .foregroundStyle(.lobbySecondary)
        }
        ForEach(model.folders) { folder in
            VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                HStack {
                    Label(folder.displayName, systemImage: AppSymbol.folder)
                        .font(.headline)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle", role: .destructive) { model.removeFolder(folder) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.lobbyIcon)
                        .accessibilityIdentifier("folder.remove")
                }
                Text(folder.path)
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Picker("What Is in It", selection: Binding(
                    get: { folder.hint },
                    set: { hint in replace(folder) { $0.hint = hint } })
                ) {
                    ForEach(ServerSettingsModel.kinds, id: \.self) { Text(ServerSettingsModel.kindName($0)).tag($0) }
                }
                Toggle("For the Children", isOn: Binding(
                    get: { folder.isForKids },
                    set: { kids in replace(folder) { $0.group = kids ? LibraryFolder.kidsGroup : nil } }))
                    .disabled(folder.hint == "music" || folder.hint == "audiobooks")
            }
            .padding(.vertical, AppTheme.Space.xs)
        }
    }

    private func replace(_ folder: LibraryFolder, _ change: (inout LibraryFolder) -> Void) {
        var list = model.folders
        guard let index = list.firstIndex(where: { $0.path == folder.path }) else { return }
        change(&list[index])
        model.setFolders(list)
    }
}

/// The TMDB key: whether there is one, replacing it, removing it.
struct TMDBKeySection: View {
    let model: ServerSettingsModel
    @State private var key = ""
    @State private var problem: String?
    @State private var confirmsRemoval = false

    var body: some View {
        Section {
            LabeledContent("TMDB Key", value: model.tmdbKey.set ? "Set" : "Not set")
                .accessibilityIdentifier("serverSettings.tmdbStatus")
            if model.tmdbKey.source == "environment" {
                Text("This key is set where Lobby Server is started, so it is changed there.")
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
            } else {
                TMDBKeyField(key: $key)
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(Color.lobbyFailure)
                }
                Button(model.tmdbKey.set ? "Check and Replace" : "Check and Save") {
                    Task {
                        problem = await model.setTMDBKey(key)
                        if problem == nil { key = "" }
                    }
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
                .accessibilityIdentifier("serverSettings.tmdbSave")
                if model.tmdbKey.set {
                    Button("Remove the Key", role: .destructive) { confirmsRemoval = true }
                }
            }
        } header: {
            Text("Matching")
        } footer: {
            Text("With a free TMDB key, Lobby finds posters, summaries and genres for films and series. Without one, titles come from the file names and pictures from the films themselves. The key is never shown again.")
        }
        .confirmationDialog("Remove the TMDB key?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await model.removeTMDBKey() } }
        } message: {
            Text("What was looked up stays. New titles get their names from the files.")
        }
    }
}

/// Where a TMDB key is pasted, with the way to get one.
struct TMDBKeyField: View {
    @Binding var key: String

    var body: some View {
        SecureField("API key or read access token", text: $key)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .accessibilityIdentifier("tmdb.key")
        if let link = URL(string: "https://www.themoviedb.org/settings/api") {
            Link("Get a free key at themoviedb.org", destination: link)
                .font(.footnote)
        }
    }
}

/// Every setting as the server keeps it, and what only its file sets. Read only.
private struct RawSettingsView: View {
    let model: ServerSettingsModel

    var body: some View {
        LobbyForm {
            if let settings = model.settings {
                Section("Kept by Lobby Server, version \(settings.version)") {
                    ForEach(settings.settings) { setting in
                        LabeledContent(setting.key) {
                            Text(Self.json(setting.value))
                                .font(.footnote.monospaced())
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
                Section("In lobby.config.json") {
                    LabeledContent("File", value: settings.fixed.configFile)
                    LabeledContent("Data folder", value: settings.fixed.dataDir)
                    LabeledContent("Listens on", value: "\(settings.fixed.host):\(settings.fixed.port)")
                    LabeledContent("First manager", value: settings.fixed.claim == "open" ? "The first device" : "With the setup secret")
                    LabeledContent("Outside entrance", value: settings.fixed.outside?.name ?? "Not set up")
                }
            }
        }
        .navigationTitle("All Settings")
    }

    static func json(_ value: SettingValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The versions before this one, going back to one, and who changed what.
private struct SettingsHistoryView: View {
    let model: ServerSettingsModel
    @State private var showsReview = false

    var body: some View {
        LobbyForm {
            Section("Versions") {
                ForEach(model.history) { version in
                    HStack {
                        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                            Text("Version \(version.version)\(version.current ? ", in use" : "")").font(.headline)
                            Text("\(version.at.formatted(date: .abbreviated, time: .shortened)) · \(version.by?.name ?? "From lobby.config.json")")
                                .font(.footnote)
                                .foregroundStyle(.lobbySecondary)
                            if !version.changed.isEmpty {
                                Text(version.changed.joined(separator: ", "))
                                    .font(.footnote)
                                    .foregroundStyle(.lobbySecondary)
                            }
                        }
                        Spacer()
                        if !version.current {
                            Button("Go Back…") {
                                Task {
                                    await model.prepareRestore(version.version)
                                    if model.review != nil { showsReview = true }
                                }
                            }
                            .buttonStyle(.lobbyText)
                        }
                    }
                }
            }
            Section("What Happened") {
                ForEach(model.audit) { entry in
                    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                        Text(ServerSettingsModel.auditLine(entry))
                        Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                    }
                }
            }
        }
        .navigationTitle("Earlier Versions")
        .task { await model.loadHistory() }
        .sheet(isPresented: $showsReview, onDismiss: { model.cancelReview() }) {
            ReviewSheet(model: model)
        }
    }
}
