// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// Picking a folder on the server: its drives and its home folder, one level at a time, with how
/// many videos each folder holds.
struct FolderPickerSheet: View {
    enum Purpose {
        /// A library folder: also what is in it, and whether it is for the children.
        case library
        /// Lobby's own folder for converting: any folder on the drive, also one to be made.
        case lobbyFolder
        /// An import folder: also whether its files are moved or listed where they are.
        case importFolder
    }

    let purpose: Purpose
    let pick: (_ path: String, _ hint: String, _ forKids: Bool) -> Void
    @State private var model: FolderBrowserModel
    @State private var hint = "movies"
    @State private var forKids = false
    @State private var newFolder = "Lobby"
    @State private var mode = "move"
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, purpose: Purpose, pick: @escaping (_ path: String, _ hint: String, _ forKids: Bool) -> Void) {
        self.purpose = purpose
        self.pick = pick
        _model = State(initialValue: FolderBrowserModel(app: app))
    }

    private var chosen: String? {
        guard let path = model.listing?.path else { return nil }
        if purpose == .lobbyFolder {
            let name = newFolder.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? path : (path as NSString).appendingPathComponent(name)
        }
        return path
    }

    var body: some View {
        LobbySheet(
            title: purpose == .library ? "Add a Folder" : purpose == .importFolder ? "Add an Import Folder" : "Lobby's Folder",
            height: 620,
            confirm: .init(title: purpose == .lobbyFolder ? "Choose" : "Add", isEnabled: chosen != nil) {
                guard let chosen else { return }
                if purpose == .importFolder {
                    pick(chosen, mode, false)
                } else {
                    pick(chosen, hint, forKids && hint != "music" && hint != "audiobooks")
                }
                dismiss()
            }
        ) {
            LobbyForm {
                Section {
                    if let listing = model.listing, let path = listing.path {
                        Text(path)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.lobbySecondary)
                            .lineLimit(3)
                            .truncationMode(.head)
                        Button("Up", systemImage: "chevron.up") { Task { await model.up() } }
                            .accessibilityIdentifier("browse.up")
                        if listing.videoFiles > 0 {
                            Text(listing.videoFiles == 1 ? "1 video right in this folder" : "\(listing.videoFiles) videos right in this folder")
                                .font(.footnote)
                                .foregroundStyle(.lobbySecondary)
                        }
                    } else {
                        Text("The server's drives and its home folder.")
                            .foregroundStyle(.lobbySecondary)
                    }
                    ForEach(model.listing?.folders ?? []) { folder in
                        Button {
                            Task { await model.open(folder.path) }
                        } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                                        Text(folder.name)
                                        Text(FolderBrowserModel.caption(folder))
                                            .font(.footnote)
                                            .foregroundStyle(.lobbySecondary)
                                    }
                                } icon: {
                                    Image(systemName: AppSymbol.folder)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.lobbySecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.lobbyRow)
                        .accessibilityIdentifier("browse.folder")
                    }
                    if model.listing?.truncated == true {
                        Text("There are more folders than can be shown here.")
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                    }
                } header: {
                    Text(model.listing?.path == nil ? "Places" : "Folders in it")
                } footer: {
                    if let problem = model.problem {
                        Text(problem).foregroundStyle(Color.lobbyFailure)
                    }
                }
                if model.listing?.path != nil {
                    switch purpose {
                    case .library:
                        Section {
                            Picker("What Is in It", selection: $hint) {
                                ForEach(ServerSettingsModel.kinds, id: \.self) { Text(ServerSettingsModel.kindName($0)).tag($0) }
                            }
                            .accessibilityIdentifier("browse.kind")
                            Toggle("For the Children", isOn: $forKids)
                                .disabled(hint == "music" || hint == "audiobooks")
                        } footer: {
                            Text("This folder is added. Lobby only reads it. Folders for the children show in their part of the library.")
                        }
                    case .importFolder:
                        Section {
                            Picker("Finished Files Are", selection: $mode) {
                                Text(ImportsModel.modeName("index")).tag("index")
                                Text(ImportsModel.modeName("move")).tag("move")
                            }
                            .accessibilityIdentifier("browse.importMode")
                        } footer: {
                            Text("Listed where they are: nothing in this folder is moved, which a folder a download program uses needs. Moved: finished files go into the library under a neat name.")
                        }
                        .onChange(of: model.listing?.path, initial: true) { _, path in
                            mode = ImportFolderSetting.looksLikeDownloads(path ?? "") ? "index" : "move"
                        }
                    case .lobbyFolder:
                        Section {
                            TextField("New folder in it", text: $newFolder)
                                .autocorrectionDisabled()
                        } footer: {
                            Text("Pick the drive the library is on, outside the library folders. Lobby makes this folder in it and keeps the originals of converted files there.")
                        }
                    }
                }
            }
            .overlay {
                if model.listing == nil, model.problem == nil { ProgressView() }
            }
            .task { await model.open(nil) }
        }
    }
}

/// The first setup over everything else, while the server still needs it.
struct ServerSetupPresenter: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { app.showsServerSetup }, set: { if !$0 { app.postponesSetup = true } })) {
            ServerSetupView(app: app)
                .interactiveDismissDisabled()
        }
    }
}

extension View {
    /// Offers a fresh server's first setup to its manager.
    func offersServerSetup() -> some View {
        modifier(ServerSetupPresenter())
    }
}

/// Setting a fresh server up: its name, its folders, a TMDB key or none, then the first look
/// through the folders.
struct ServerSetupView: View {
    @State private var model: ServerSetupModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.motion) private var motion
    @Environment(\.colorScheme) private var scheme
    @State private var picks = false
    private let app: AppModel

    init(app: AppModel) {
        self.app = app
        _model = State(initialValue: ServerSetupModel(app: app))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StepDots(step: model.step)
                    .padding(.top, AppTheme.Space.l)
                LobbyForm {
                    switch model.step {
                    case .name: nameStep
                    case .folders: foldersStep
                    case .tmdb: keyStep
                    case .scan: scanStep
                    }
                    if let problem = model.problem {
                        Section {
                            Label(problem, systemImage: AppSymbol.problem)
                                .foregroundStyle(Color.lobbyFailure)
                                .accessibilityIdentifier("setup.problem")
                        }
                    }
                }
                .id(model.step)
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
                buttons
            }
            .animation(motion.animation(.section), value: model.step)
            .background(Color.lobbyBackground(scheme))
            .navigationTitle("Set Up Lobby Server")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if model.step != .scan {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Later") {
                            app.postponesSetup = true
                            dismiss()
                        }
                        .accessibilityIdentifier("setup.later")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 640)
        #endif
        .task { await model.start() }
        .sheet(isPresented: $picks) {
            FolderPickerSheet(app: app, purpose: .library) { path, hint, kids in
                model.settings.addFolder(path: path, hint: hint, forKids: kids)
            }
        }
    }

    private var nameStep: some View {
        Section {
            TextField("Name", text: $model.name)
                .font(.title3)
                .accessibilityIdentifier("setup.name")
        } header: {
            Text("A name for this server")
        } footer: {
            Text("Everyone sees it when their device looks for Lobby, so they know they found the right one. It can be changed later in Settings.")
        }
    }

    @ViewBuilder
    private var foldersStep: some View {
        Section {
            FolderList(model: model.settings)
            Button("Add a Folder…", systemImage: "plus") { picks = true }
                .accessibilityIdentifier("setup.addFolder")
        } header: {
            Text("Where the films and series are")
        } footer: {
            Text("Pick the folders on the server's drives, and say what is in each: films, series, home videos, music or audiobooks. Lobby only reads them. Folders for the children show in their own part.")
        }
    }

    @ViewBuilder
    private var keyStep: some View {
        Section {
            TMDBKeyField(key: $model.key)
        } header: {
            Text("Posters and summaries")
        } footer: {
            Text("With a free key from TMDB, Lobby finds posters, summaries and genres. Make an account at themoviedb.org, open Settings → API, and paste the key here. Without one, titles come from the file names and pictures from the films. A key can be added later.")
        }
    }

    @ViewBuilder
    private var scanStep: some View {
        Section {
            HStack(spacing: AppTheme.Space.m) {
                if model.isFinished {
                    Image(systemName: AppSymbol.done).foregroundStyle(Color.lobbySuccess)
                } else {
                    ProgressView()
                }
                Text(model.isFinished ? "Done. \(model.progressText)" : model.progressText)
                    .accessibilityIdentifier("setup.progress")
            }
        } header: {
            Text("Looking through the folders")
        } footer: {
            Text("A large library takes a while. Lobby reads one file after another, so playing stays smooth; titles appear as they are found.")
        }
    }

    private var buttons: some View {
        HStack(spacing: AppTheme.Space.m) {
            if model.step != .name, model.step != .scan {
                Button("Back") { model.back() }
                    .buttonStyle(QuietButtonStyle())
            }
            switch model.step {
            case .tmdb:
                Button("Skip") { Task { await model.skipKey() } }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("setup.skip")
                Button(model.key.isEmpty ? "Go On Without" : "Check and Go On") { Task { await model.next() } }
                    .buttonStyle(ProminentButtonStyle())
                    .busy(model.isWorking)
                    .accessibilityIdentifier("setup.next")
            case .scan:
                Button(model.isFinished ? "Open the Library" : "Go to the Library") { dismiss() }
                    .buttonStyle(ProminentButtonStyle())
                    .accessibilityIdentifier("setup.done")
            default:
                Button("Go On") { Task { await model.next() } }
                    .buttonStyle(ProminentButtonStyle())
                    .busy(model.isWorking)
                    .disabled(!model.canGoOn)
                    .accessibilityIdentifier("setup.next")
            }
        }
        .padding(AppTheme.Space.page)
    }
}

/// Where in the setup one is: four dots.
private struct StepDots: View {
    let step: ServerSetupModel.Step
    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: AppTheme.Space.s) {
            ForEach(ServerSetupModel.Step.allCases, id: \.self) { one in
                Capsule()
                    .fill(one.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: one == step ? 24 : 8, height: 8)
            }
        }
        .animation(motion.animation(.change), value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(ServerSetupModel.Step.allCases.count)")
    }
}
