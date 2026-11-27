// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI
import UniformTypeIdentifiers

// Uploading, the Inbox and the import folders, for a manager (docs/imports.md).

/// What can be picked to upload: videos, subtitles, and folders of them.
enum UploadTypes {
    static var allowed: [UTType] {
        var types: [UTType] = [.movie, .folder]
        for ext in UploadQueue.subtitleExtensions.sorted() + ["mkv", "avi", "m4v", "webm", "wmv"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }
}

/// Upload: files and folders from this device into the library, each with its progress.
struct UploadsView: View {
    @State private var model: UploadsModel
    @State private var picks = false
    @State private var isTargeted = false

    init(app: AppModel) {
        _model = State(initialValue: app.uploads())
    }

    var body: some View {
        LobbyForm {
            Section {
                Button(Self.pickTitle, systemImage: AppSymbol.upload) { picks = true }
                    .accessibilityIdentifier("uploads.pick")
            } footer: {
                #if os(macOS)
                Text("Or drop files and folders on this window. They are checked when they arrive, named neatly and put in the library; what Lobby is not sure about waits in the Inbox for you.")
                #else
                Text("From Files, also from a drive that is connected. Uploads go on while Lobby is in the background. They are checked when they arrive, named neatly and put in the library; what Lobby is not sure about waits in the Inbox for you.")
                #endif
            }
            if model.status?.moving == false {
                Section {
                    Label("Uploads need Lobby's folder on the server. Set it in Server Settings, under Converting.", systemImage: AppSymbol.problem)
                        .foregroundStyle(Color.lobbyFailure)
                }
            }
            Section {
                if model.jobs.isEmpty {
                    Text("Nothing uploaded yet.")
                        .foregroundStyle(.lobbySecondary)
                }
                ForEach(model.jobs) { job in
                    UploadRow(model: model, job: job)
                }
                if model.jobs.contains(where: \.isFinished) {
                    Button("Clear Finished") { Task { await model.clearFinished() } }
                        .buttonStyle(.lobbyText)
                        .accessibilityIdentifier("uploads.clearFinished")
                }
            } header: {
                Text("Uploads")
            }
            Section {
                NavigationLink(value: Route.inbox) {
                    Label("Inbox", systemImage: AppSymbol.inbox)
                }
                .accessibilityIdentifier("uploads.inbox")
            } footer: {
                Text("Files Lobby could not place by itself, from uploads and from the server's import folders.")
            }
        }
        .navigationTitle("Upload")
        .fileImporter(isPresented: $picks, allowedContentTypes: UploadTypes.allowed, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.pick(urls) }
        }
        .sheet(isPresented: Binding(get: { !model.picked.isEmpty }, set: { if !$0 { model.picked = [] } })) {
            UploadDestinationSheet(model: model)
        }
        #if os(macOS)
        .dropDestination(for: URL.self) { urls, _ in
            model.pick(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        #endif
        .alert(
            "That did not work",
            isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
        .task {
            await model.connect()
            await model.loadDestinations()
            // The UI tests hand the app a file as if it was picked (`-lobby-ui-upload-file <path>`).
            // Debug builds only, which is what the UI tests run.
            #if DEBUG
            if let path = UserDefaults.standard.string(forKey: "lobby-ui-upload-file"), model.jobs.isEmpty {
                model.pick([URL(fileURLWithPath: path)])
            }
            #endif
        }
    }

    private static var pickTitle: String {
        #if os(macOS)
        "Upload Files…"
        #else
        "Upload from Files…"
        #endif
    }
}

/// One upload: its name, where it goes, how far it is, and pause, go on or stop.
private struct UploadRow: View {
    let model: UploadsModel
    let job: UploadJob

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            HStack {
                Label(job.name, systemImage: job.state == .done ? AppSymbol.done : AppSymbol.upload)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                controls
            }
            if job.state == .sending || job.state == .paused || job.state == .verifying {
                ProgressView(value: job.fraction)
                    .accessibilityIdentifier("upload.progress.\(job.name)")
            }
            Text("\(UploadsModel.describe(job.destination, status: model.status)) · \(UploadsModel.describe(job))")
                .font(.footnote)
                .foregroundStyle(job.state == .failed ? AnyShapeStyle(Color.lobbyFailure) : AnyShapeStyle(.lobbySecondary))
                .accessibilityIdentifier("upload.state.\(job.name)")
        }
        .padding(.vertical, AppTheme.Space.xs)
        .accessibilityIdentifier("upload.row.\(job.name)")
    }

    @ViewBuilder
    private var controls: some View {
        switch job.state {
        case .queued, .sending:
            Button("Pause", systemImage: AppSymbol.pause) { Task { await model.pause(job) } }
                .labelStyle(.iconOnly).buttonStyle(.lobbyIcon)
                .accessibilityIdentifier("upload.pause")
            stop
        case .paused, .failed:
            Button("Resume", systemImage: AppSymbol.resume) { Task { await model.resume(job) } }
                .labelStyle(.iconOnly).buttonStyle(.lobbyIcon)
                .accessibilityIdentifier("upload.resume")
            stop
        default:
            EmptyView()
        }
    }

    private var stop: some View {
        Button("Stop", systemImage: "xmark.circle", role: .destructive) { Task { await model.cancel(job) } }
            .labelStyle(.iconOnly).buttonStyle(.lobbyIcon)
            .accessibilityIdentifier("upload.cancel")
    }
}

/// Where the picked files go: Movies, Series, or one library folder.
private struct UploadDestinationSheet: View {
    let model: UploadsModel
    @State private var choice = 0

    var body: some View {
        let places = model.destinations
        LobbySheet(
            title: model.picked.count == 1 ? "Upload 1 File" : "Upload \(model.picked.count) Files", height: 480,
            confirm: .init(title: "Upload") {
                guard places.indices.contains(choice) else { return }
                await model.send(to: places[choice].destination)
            }
        ) {
            LobbyForm {
                Section {
                    Picker("Where It Goes", selection: $choice) {
                        ForEach(Array(places.enumerated()), id: \.offset) { index, place in
                            Text(place.title).tag(index)
                        }
                    }
                    .accessibilityIdentifier("uploads.destination")
                } footer: {
                    Text("Films get a folder of their own, episodes their show's season folder. Lobby asks you when it is not sure what a file is.")
                }
                Section {
                    ForEach(model.picked.prefix(50), id: \.relPath) { file in
                        LabeledContent(file.relPath, value: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    }
                    if model.picked.count > 50 {
                        Text("And \(model.picked.count - 50) more.").foregroundStyle(.lobbySecondary)
                    }
                } header: {
                    Text("Files")
                }
            }
        }
        .task { if model.status == nil { await model.loadDestinations() } }
    }
}

// MARK: The Inbox

/// What waits for a manager, what is still being written, what was left out and what arrived.
struct InboxView: View {
    @State private var model: ImportsModel
    @State private var chosen: ImportItem?

    init(app: AppModel) {
        _model = State(initialValue: ImportsModel(app: app))
    }

    var body: some View {
        @Bindable var model = model
        LobbyForm {
            Section {
                Picker("Show", selection: $model.view) {
                    ForEach(ImportsModel.View.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("inbox.view")
            }
            Section {
                if model.items.isEmpty, !model.isLoading {
                    Text(model.view.empty).foregroundStyle(.lobbySecondary)
                }
                ForEach(model.items) { item in
                    InboxRow(item: item) { chosen = item }
                }
            }
            Section {
                NavigationLink(value: Route.importActivity) {
                    Label("What Happened", systemImage: AppSymbol.seen)
                }
                .accessibilityIdentifier("inbox.activity")
            }
        }
        .navigationTitle("Inbox")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Look Now", systemImage: AppSymbol.refresh) { Task { await model.scan() } }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("inbox.scan")
            }
        }
        .task(id: model.view) { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $chosen) { item in
            ImportItemSheet(model: model, item: item)
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

/// One file in the Inbox's list.
private struct InboxRow: View {
    let item: ImportItem
    let open: () -> Void

    private var line: String {
        let state = ImportsModel.stateName(item.state)
        guard let reason = item.reason else { return state }
        return "\(state) · \(reason)"
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                Text(ImportsModel.title(of: item)).font(.headline)
                if item.title != nil {
                    Text(item.name).font(.footnote).foregroundStyle(.lobbySecondary).lineLimit(1)
                }
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(item.state == "failed" ? AnyShapeStyle(Color.lobbyFailure) : AnyShapeStyle(.lobbySecondary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lobbyRow)
        .accessibilityIdentifier("inbox.item.\(item.name)")
    }
}

/// One file: what Lobby knows, and what a manager decides about it.
private struct ImportItemSheet: View {
    let model: ImportsModel
    let item: ImportItem
    @State private var kind = "movie"
    @State private var title = ""
    @State private var year = ""
    @State private var season = ""
    @State private var episode = ""
    @State private var episodeTitle = ""
    @State private var destination = ""
    @State private var confirmsCleanUp = false
    @Environment(\.dismiss) private var dismiss

    private var decision: ImportDecision? {
        let name = title.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if kind == "episode", Int(season) == nil || Int(episode) == nil { return nil }
        return ImportDecision(
            action: "move", kind: kind, title: name, year: Int(year),
            season: kind == "episode" ? Int(season) : nil, episode: kind == "episode" ? Int(episode) : nil,
            episodeTitle: kind == "episode" && !episodeTitle.isEmpty ? episodeTitle : nil,
            destination: destination.isEmpty ? nil : destination)
    }

    var body: some View {
        LobbySheet(
            title: item.name, height: 640,
            confirm: item.can("move")
                ? .init(title: "Move into Library", isEnabled: decision != nil) {
                    guard let decision else { return }
                    if await model.confirm(item, decision) { dismiss() }
                }
                : nil
        ) {
            LobbyForm {
                Section {
                    LabeledContent("Now", value: ImportsModel.stateName(item.state))
                    if let reason = item.reason {
                        Text(reason).foregroundStyle(.lobbySecondary)
                    }
                    if let target = item.targetPath {
                        LabeledContent("In the library", value: (target as NSString).lastPathComponent)
                    }
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                    if !item.subtitles.isEmpty {
                        LabeledContent("Subtitles", value: item.subtitles.count == 1 ? "1 goes along" : "\(item.subtitles.count) go along")
                    }
                }
                if item.can("move") {
                    if !item.candidates.isEmpty {
                        Section {
                            ForEach(item.candidates, id: \.tmdbId) { candidate in
                                Button(candidate.year.map { "\(candidate.title) (\($0))" } ?? candidate.title) {
                                    title = candidate.title
                                    year = candidate.year.map(String.init) ?? ""
                                }
                                .buttonStyle(.lobbyText)
                            }
                        } header: {
                            Text("On TMDB")
                        }
                    }
                    Section {
                        Picker("Kind", selection: $kind) {
                            Text("Film").tag("movie")
                            Text("Episode").tag("episode")
                        }
                        .accessibilityIdentifier("importItem.kind")
                        TextField(kind == "episode" ? "Show" : "Title", text: $title)
                            .accessibilityIdentifier("importItem.title")
                        TextField("Year", text: $year)
                            .accessibilityIdentifier("importItem.year")
                        if kind == "episode" {
                            TextField("Season", text: $season)
                            TextField("Episode", text: $episode)
                            TextField("Episode title", text: $episodeTitle)
                        }
                        Picker("Where It Goes", selection: $destination) {
                            Text(kind == "episode" ? "Series" : "Movies").tag("")
                            ForEach(model.status?.destinations ?? []) { place in
                                Text(place.name).tag(place.path)
                            }
                        }
                    } header: {
                        Text("What It Is")
                    } footer: {
                        Text("It gets a neat name from this, and is moved; nothing in the library is ever replaced.")
                    }
                }
                Section {
                    if item.can("list") {
                        Button("List Where It Is") {
                            Task { if await model.confirm(item, ImportDecision(action: "list")) { dismiss() } }
                        }
                        .accessibilityIdentifier("importItem.list")
                    }
                    if item.can("convert") {
                        Button("Convert for Apple Devices") {
                            Task { if await model.convert(item) { dismiss() } }
                        }
                    }
                    if item.can("cleanUp"), let leftovers = item.leftovers {
                        Button("Remove What Was Left…", role: .destructive) { confirmsCleanUp = true }
                            .accessibilityIdentifier("importItem.cleanUp")
                            .confirmationDialog(
                                "Remove what was left of “\(leftovers.dir)”?", isPresented: $confirmsCleanUp, titleVisibility: .visible
                            ) {
                                Button("Remove \(leftovers.files.count) Files", role: .destructive) {
                                    Task { if await model.cleanUp(item) { dismiss() } }
                                }
                            } message: {
                                Text(leftovers.files.prefix(8).joined(separator: "\n"))
                            }
                    }
                    if item.can("dismiss") {
                        Button(item.origin == "upload" ? "Leave Out and Remove the Upload" : "Leave It Alone", role: .destructive) {
                            Task { if await model.dismiss(item) { dismiss() } }
                        }
                        .accessibilityIdentifier("importItem.dismiss")
                    }
                }
            }
        }
        .onAppear {
            kind = item.kind ?? "movie"
            title = item.title ?? ""
            year = item.year.map(String.init) ?? ""
            season = item.season.map(String.init) ?? ""
            episode = item.episode.map(String.init) ?? ""
            episodeTitle = item.episodeTitle ?? ""
            destination = item.destination ?? ""
        }
    }
}

/// What happened to imports, newest first.
struct ImportActivityView: View {
    @State private var model: ImportsModel

    init(app: AppModel) {
        _model = State(initialValue: ImportsModel(app: app))
    }

    var body: some View {
        LobbyForm {
            if model.activity.isEmpty {
                Text("Nothing happened yet.").foregroundStyle(.lobbySecondary)
            }
            ForEach(model.activity) { entry in
                VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                    Text(entry.message)
                    Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                }
            }
        }
        .navigationTitle("What Happened")
        .task { await model.loadActivity() }
        .refreshable { await model.loadActivity() }
    }
}

// MARK: Server Settings

/// The import folders: each with what happens to its files, how it is doing, and adding one.
struct ImportFoldersSection: View {
    let model: ServerSettingsModel
    @State private var picks = false
    @State private var status: ImportsStatus?

    var body: some View {
        Section {
            if model.importFolders.isEmpty {
                Text("No import folders yet.").foregroundStyle(.lobbySecondary)
            }
            ForEach(model.importFolders) { folder in
                VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                    HStack {
                        Label(folder.displayName, systemImage: AppSymbol.importFolder).font(.headline)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle", role: .destructive) { model.removeImportFolder(folder) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.lobbyIcon)
                            .accessibilityIdentifier("importFolder.remove")
                    }
                    Text(folder.path)
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Picker("Finished Files Are", selection: Binding(get: { folder.mode }, set: { model.setImportMode(folder, $0) })) {
                        Text(ImportsModel.modeName("index")).tag("index")
                        Text(ImportsModel.modeName("move")).tag("move")
                    }
                    if let line = Self.statusLine(status?.folders.first { $0.path == folder.path }) {
                        Text(line).font(.footnote).foregroundStyle(.lobbySecondary)
                    }
                    if folder.mode == "move", ImportFolderSetting.looksLikeDownloads(folder.path) {
                        Text("A program that still needs a file there loses it once it is moved.")
                            .font(.footnote)
                            .foregroundStyle(Color.lobbyFailure)
                    }
                }
                .padding(.vertical, AppTheme.Space.xs)
            }
            Button("Add an Import Folder…", systemImage: AppSymbol.importFolder) { picks = true }
                .accessibilityIdentifier("serverSettings.addImportFolder")
            NavigationLink(value: Route.inbox) {
                Label("Inbox", systemImage: AppSymbol.inbox)
            }
            .accessibilityIdentifier("serverSettings.inbox")
        } header: {
            Text("Import Folders")
        } footer: {
            Text("Folders where new films and episodes land. Lobby waits until a file is finished and has not changed for a while, leaves out samples, extras and everything that is not a video, and never replaces anything. What it is not sure about waits in the Inbox.")
        }
        .sheet(isPresented: $picks) {
            FolderPickerSheet(app: model.appForPicker, purpose: .importFolder) { path, mode, _ in
                model.addImportFolder(path: path, mode: mode)
            }
        }
        .task {
            status = try? await model.appForPicker.asManager { try await $0.imports() }
        }
    }

    static func statusLine(_ folder: ImportsStatus.Folder?) -> String? {
        guard let folder else { return nil }
        if let problem = folder.problem { return problem }
        if !folder.connected { return "Not there now. Is its drive connected?" }
        var parts: [String] = []
        let count = { (state: String) in folder.counts[state] ?? 0 }
        if count("inbox") + count("failed") > 0 { parts.append("\(count("inbox") + count("failed")) in the Inbox") }
        if count("waiting") > 0 { parts.append("\(count("waiting")) waiting") }
        if count("listed") > 0 { parts.append("\(count("listed")) listed") }
        if count("imported") > 0 { parts.append("\(count("imported")) imported") }
        return parts.isEmpty ? "Nothing new." : parts.joined(separator: " · ")
    }
}
