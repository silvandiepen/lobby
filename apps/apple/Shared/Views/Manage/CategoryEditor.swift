// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A category or group: what it is called and how it looks.
struct CategoryEditor: View {
    let model: CategoriesModel
    @State var draft: CategoryDraft

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var isSearchingLogo = false
    @State private var photo: PhotosPickerItem?
    @State private var isChoosingFile = false
    @State private var isChoosingIcon = false
    @State private var genres: [String] = []

    var body: some View {
        LobbySheet(
            title: draft.title, width: 560, height: 640,
            confirm: .init(title: "Save", isEnabled: draft.canSave && !model.isBusy) {
                if await model.save(draft) { dismiss() }
            }
        ) {
            LobbyForm {
                Section {
                    preview
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                if draft.hasName {
                    Section {
                        TextField("Name", text: $draft.name, prompt: Text(draft.isGroup ? "Group name" : "Category name"))
                            .accessibilityIdentifier("category.name")
                        if !draft.isGroup {
                            Picker("Group", selection: $draft.groupID) {
                                ForEach(model.groups) { group in
                                    Text(CategoriesModel.name(of: group)).tag(Optional(group.id))
                                }
                            }
                            .accessibilityIdentifier("category.group")
                        }
                    }
                }
                iconSection
                Section {
                    ColorSwatches(colors: model.colors, selection: $draft.color, allowsNone: true, identifier: "category.color")
                } header: {
                    Text("Colour")
                }
                logoSection
                if let problem = model.problem {
                    Section {
                        Label(problem, systemImage: AppSymbol.problem)
                            .foregroundStyle(Color.lobbyFailure)
                            .accessibilityIdentifier("category.problem")
                    }
                }
            }
        }
        .onAppear {
            model.problem = nil
            genres = titleGenres
        }
        .onDisappear { model.problem = nil }
        .sheet(isPresented: $isChoosingIcon) {
            IconPicker(selection: $draft.icon, suggestions: suggestions)
        }
        .sheet(isPresented: $isSearchingLogo) {
            LogoSearchView(model: model, query: draft.trimmedName) { draft.logo = .found($0) }
        }
        .onChange(of: photo) { _, picked in
            guard let picked else { return }
            Task {
                use(try? await picked.loadTransferable(type: Data.self))
                photo = nil
            }
        }
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let opened = url.startAccessingSecurityScopedResource()
            defer { if opened { url.stopAccessingSecurityScopedResource() } }
            use(try? Data(contentsOf: url))
        }
    }

    private func use(_ data: Data?) {
        if let png = data.flatMap({ PictureEncoder.png(from: $0) }) {
            draft.logo = .picture(png)
        } else {
            model.problem = "That picture could not be read."
        }
    }

    /// What the titles of a category or group that exists are.
    private var titleGenres: [String] {
        switch draft.subject {
        case .category(let id): app.genres(ofCategory: id, in: model.edit?.setup ?? .none)
        case .group(let id, _): app.genres(ofGroup: id)
        case .newCategory, .newGroup: []
        }
    }

    // MARK: Parts

    private var preview: some View {
        VStack(spacing: AppTheme.Space.s) {
            logoPreview
                .font(.title)
                .foregroundStyle(draft.color.map(Color.lobbyProfile) ?? .primary)
            Text(draft.hasName ? (draft.trimmedName.isEmpty ? "Name" : draft.trimmedName) : "Main Library")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .padding(AppTheme.Space.m)
        .frame(width: 180, height: 112)
        .background(Color.lobbySurface(scheme), in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String { AppSymbol.existing(draft.icon) ?? (draft.isGroup ? AppSymbol.group : AppSymbol.category) }

    @ViewBuilder
    private var logoPreview: some View {
        switch draft.logo {
        case .keep:
            CategoryMark(look: CategoryLook(symbol: symbol, logo: draft.currentLogo), area: 3_000, maxWidth: 140, maxHeight: 52)
        case .none:
            Image(systemName: symbol)
        case .found(let result):
            ServerPicture(path: result.previewUrl, isTemplate: true)
                .frame(maxWidth: 140, maxHeight: 52)
        case .picture(let png):
            if let image = PictureEncoder.image(from: png, maxPixels: 600) {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 140, maxHeight: 52)
            }
        }
    }

    private var iconSection: some View {
        Section {
            Button {
                isChoosingIcon = true
            } label: {
                HStack(spacing: AppTheme.Space.m) {
                    Image(systemName: symbol)
                        .font(.title3)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    Text(draft.icon == nil ? "Choose an Icon…" : "Choose Another Icon…")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.lobbyText)
            .accessibilityIdentifier("category.chooseIcon")
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                    Text("Suggestions")
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                    IconGrid(symbols: suggestions, selection: draft.icon, identifier: "category.suggestion") { name in
                        draft.icon = draft.icon == name ? nil : name
                    }
                }
            }
        } header: {
            Text("Icon")
        }
    }

    /// From the name as it is now, and from the titles that are in it.
    private var suggestions: [String] {
        SymbolSearch.suggestions(forName: draft.hasName ? draft.name : "", genres: genres, limit: 10)
    }

    private var hasLogo: Bool {
        switch draft.logo {
        case .keep: draft.currentLogo != nil
        case .none: false
        case .found, .picture: true
        }
    }

    private var logoSection: some View {
        Section {
            Button("Search for a Studio…", systemImage: AppSymbol.search) { isSearchingLogo = true }
                .accessibilityIdentifier("category.searchLogo")
            PhotosPicker(selection: $photo, matching: .images) {
                Label("Choose from Photos…", systemImage: AppSymbol.photos)
            }
            Button("Choose a File…", systemImage: AppSymbol.folder) { isChoosingFile = true }
            if hasLogo {
                Button("No Logo", systemImage: AppSymbol.remove, role: .destructive) { draft.logo = .none }
                    .accessibilityIdentifier("category.noLogo")
            }
        } header: {
            Text("Logo")
        } footer: {
            Text("A logo stands in for the name. A picture with a transparent background is drawn in one colour. Studio logos come from TMDB.")
        }
    }
}

/// Finds a studio's logo at TMDB, through the server.
private struct LogoSearchView: View {
    let model: CategoriesModel
    @State var query: String
    let choose: (LogoSearchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var results: [LogoSearchResult]?
    @State private var isSearching = false

    var body: some View {
        LobbySheet(title: "Studio Logo", width: 560, height: 520) {
            LobbyForm {
                Section {
                    TextField("Studio", text: $query, prompt: Text("A studio's name"))
                        .onSubmit { Task { await search() } }
                        .submitLabel(.search)
                        .accessibilityIdentifier("logo.query")
                    Button("Search", systemImage: AppSymbol.search) { Task { await search() } }
                        .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("logo.search")
                }
                Section {
                    if isSearching {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if let problem = model.problem {
                        Label(problem, systemImage: AppSymbol.problem)
                            .foregroundStyle(Color.lobbyFailure)
                            .accessibilityIdentifier("logo.problem")
                    } else if let results, results.isEmpty {
                        Text("No studio with a logo has that name.")
                            .foregroundStyle(.lobbySecondary)
                    }
                    ForEach(results ?? []) { result in
                        Button {
                            choose(result)
                            dismiss()
                        } label: {
                            HStack(spacing: AppTheme.Space.m) {
                                ServerPicture(path: result.previewUrl, isTemplate: true)
                                    .frame(width: 110, height: 48)
                                VStack(alignment: .leading) {
                                    Text(result.name)
                                    if let country = result.country {
                                        Text(country).font(.footnote).foregroundStyle(.lobbySecondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.lobbyRow)
                    }
                }
            }
        }
        .task {
            model.problem = nil
            if !query.isEmpty { await search() }
        }
        .onDisappear { model.problem = nil }
    }

    private func search() async {
        guard !isSearching else { return }
        isSearching = true
        model.problem = nil
        results = await model.searchLogos(query)
        isSearching = false
    }
}

/// A preview the server has at a path, fetched with the device's credential.
struct ServerPicture: View {
    let path: String
    /// Only its shape matters.
    var isTemplate = false

    @Environment(AppModel.self) private var app
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 2)
                    .renderingMode(isTemplate ? .template : .original)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: path) { image = await app.preview(atPath: path) }
    }
}
