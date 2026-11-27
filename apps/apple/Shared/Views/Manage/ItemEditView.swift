// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import PhotosUI
import SwiftUI

/// Edit: what Lobby shows for a film, series, season or episode. For managers.
struct ItemEditView: View {
    @State private var model: ItemEditModel
    @Environment(\.dismiss) private var dismiss
    @State private var artworkKind: ArtworkKind?
    @State private var isMatching = false

    init(app: AppModel, itemID: String) {
        _model = State(wrappedValue: ItemEditModel(app: app, itemID: itemID))
    }

    var body: some View {
        @Bindable var model = model
        LobbySheet(
            title: "Edit", width: 600, height: 680,
            confirm: .init(title: "Save", isEnabled: model.canSave) {
                if await model.save() { dismiss() }
            }
        ) {
            LobbyForm {
                if let problem = model.problem {
                    Section {
                        Label(problem, systemImage: AppSymbol.problem)
                            .foregroundStyle(Color.lobbyFailure)
                            .accessibilityIdentifier("edit.problem")
                    }
                }
                if let edit = model.edit {
                    Section {
                        field("Title", .title) {
                            TextField("Title", text: $model.title, prompt: Text("Title"))
                                .labelsHidden()
                                .accessibilityIdentifier("edit.title")
                        }
                        field("Sorted As", .sortTitle) {
                            TextField("Sorted As", text: $model.sortTitle, prompt: Text("The title, for its place in a list"))
                                .labelsHidden()
                                .accessibilityIdentifier("edit.sortTitle")
                        }
                        if model.has(.year) {
                            field("Year", .year) {
                                TextField("Year", text: $model.year, prompt: Text("None"))
                                    .labelsHidden()
                                    #if !os(macOS)
                                    .keyboardType(.numberPad)
                                    #endif
                                    .accessibilityIdentifier("edit.year")
                                if !model.yearIsValid {
                                    Text("A year between 1850 and 2200, or none.")
                                        .font(.footnote)
                                        .foregroundStyle(Color.lobbyWarning)
                                }
                            }
                        }
                        if model.has(.overview) {
                            field("Summary", .overview) {
                                TextField("Summary", text: $model.overview, prompt: Text("None"), axis: .vertical)
                                    .labelsHidden()
                                    .lineLimit(3...10)
                                    .accessibilityIdentifier("edit.overview")
                            }
                        }
                        if model.has(.genres) {
                            field("Genres", .genres) {
                                TextField("Genres", text: $model.genres, prompt: Text("Separated by commas"))
                                    .labelsHidden()
                                    .accessibilityIdentifier("edit.genres")
                            }
                        }
                    } footer: {
                        Text("The files are not renamed or changed. A field that was put back follows what Lobby finds.")
                    }
                    if model.has(.categories) {
                        categoriesSection(edit)
                    }
                    if !edit.artworkKinds.isEmpty {
                        picturesSection(edit)
                    }
                    if edit.match.canChange {
                        matchSection(edit)
                    }
                } else if model.isGone {
                    Text("This is no longer in the library.")
                } else if model.problem == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .disabled(model.isBusy)
        }
        .task { await model.load() }
        .sheet(item: $artworkKind) { kind in
            ArtworkPickerView(model: model, kind: kind)
        }
        .sheet(isPresented: $isMatching) {
            MatchSearchView(model: model)
        }
    }

    /// A field with its name above it, and Put Back when a manager changed it.
    private func field(_ name: String, _ field: ItemEditModel.Field, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
            HStack {
                Text(name)
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
                Spacer()
                putBackButton(field)
            }
            content()
        }
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }

    @ViewBuilder
    private func putBackButton(_ field: ItemEditModel.Field) -> some View {
        if model.canPutBack(field) {
            Button {
                model.putBack(field)
            } label: {
                // Not a Label: in a form's row its symbol would get a column.
                HStack(spacing: AppTheme.Space.xs) {
                    Image(systemName: AppSymbol.putBack)
                        .accessibilityHidden(true)
                    Text("Put Back")
                }
            }
                .font(.footnote)
                .buttonStyle(.lobbyText)
                .accessibilityHint("Shows what Lobby finds by itself")
                .accessibilityIdentifier("edit.putBack.\(field.rawValue)")
        }
    }

    private func categoriesSection(_ edit: ItemEdit) -> some View {
        Section {
            ForEach(edit.categories) { category in
                Toggle(category.name, isOn: Binding(
                    get: { model.categoryIDs.contains(category.id) },
                    set: { isIn in
                        if isIn { model.categoryIDs.insert(category.id) } else { model.categoryIDs.remove(category.id) }
                    }))
                    .accessibilityIdentifier("edit.category.\(category.name)")
            }
            putBackButton(.categories)
        } header: {
            Text("Categories")
        } footer: {
            if model.categoryIDs.isEmpty {
                Text("It has to be in at least one.").foregroundStyle(Color.lobbyWarning)
            }
        }
    }

    private func picturesSection(_ edit: ItemEdit) -> some View {
        Section {
            ForEach(edit.artworkKinds) { kind in
                Button {
                    artworkKind = kind
                } label: {
                    HStack(spacing: AppTheme.Space.m) {
                        ZStack {
                            Color.gray.opacity(0.2)
                            if let selected = edit.options(for: kind).first(where: \.selected) {
                                ServerPicture(path: selected.previewUrl)
                            }
                        }
                        .frame(width: kind == .poster ? 48 : 96, height: kind == .poster ? 72 : 54)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.name)
                                .foregroundStyle(.primary)
                            Text(model.hasChosenArtwork(kind) ? "Chosen by a manager" : "Chosen by Lobby")
                                .font(.footnote)
                                .foregroundStyle(.lobbySecondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.lobbyRow)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("edit.artwork.\(kind.rawValue)")
            }
        } header: {
            Text("Pictures")
        } footer: {
            Text("A picture you choose takes effect at once.")
        }
    }

    private func matchSection(_ edit: ItemEdit) -> some View {
        Section {
            LabeledContent {
                Text(edit.match.tmdb.map { "TMDB \($0.id)" } ?? "None")
            } label: {
                Text("Match")
                Text(model.matchText)
            }
            if edit.match.available {
                Button("Find the Right Title…", systemImage: AppSymbol.search) { isMatching = true }
                    .accessibilityIdentifier("edit.match")
            } else {
                Text("This server cannot look titles up: it has no TMDB key.")
                    .font(.footnote)
                    .foregroundStyle(.lobbySecondary)
            }
            if !(edit.match.chosen && edit.match.tmdb == nil) {
                Button("There Is No Match", systemImage: AppSymbol.noMatch) { Task { await model.removeMatch() } }
                    .accessibilityIdentifier("edit.noMatch")
            }
            if edit.match.chosen {
                Button("Put Back to Automatic", systemImage: AppSymbol.putBack) { Task { await model.automaticMatch() } }
                    .accessibilityIdentifier("edit.automaticMatch")
            }
        } header: {
            Text("Match")
        } footer: {
            Text("The match gives the summary, genres and pictures. Changing it takes effect at once; what you edited stays.")
        }
    }
}

extension ArtworkKind {
    var name: String {
        switch self {
        case .poster: "Poster"
        case .backdrop: "Background"
        case .still: "Still"
        case .logo: "Title Logo"
        }
    }
}

/// The pictures there are for one place, TMDB's among them, a frame from the film, or one
/// from this device.
private struct ArtworkPickerView: View {
    let model: ItemEditModel
    let kind: ArtworkKind

    @Environment(\.colorScheme) private var scheme
    @State private var found: ArtworkOptions?
    @State private var photo: PhotosPickerItem?
    @State private var isChoosingFile = false
    @State private var frameAt = 0.1

    private var aspect: CGFloat { kind == .poster ? AppTheme.posterAspect : AppTheme.wideAspect }

    /// What the server has now (an upload, a frame), then TMDB's.
    private var options: [ArtworkOption] {
        let own = model.edit?.options(for: kind) ?? []
        let known = Set(own.map(\.id)).union(own.compactMap(\.path))
        return own + (found?.options ?? []).filter { !known.contains($0.id) && !known.contains($0.path ?? "") }
    }

    var body: some View {
        LobbySheet(title: kind.name, width: 620, height: 640) {
            LobbyForm {
                if let problem = model.problem {
                    Section {
                        Label(problem, systemImage: AppSymbol.problem)
                            .foregroundStyle(Color.lobbyFailure)
                            .accessibilityIdentifier("artwork.problem")
                    }
                }
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: kind == .poster ? 96 : 150), spacing: AppTheme.Space.m)], spacing: AppTheme.Space.m) {
                        ForEach(options) { option in
                            optionButton(option)
                        }
                    }
                    if found == nil, model.problem == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if options.isEmpty {
                        Text("There are no pictures yet.")
                            .foregroundStyle(.lobbySecondary)
                    }
                }
                Section {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Choose from Photos…", systemImage: AppSymbol.photos)
                    }
                    .accessibilityIdentifier("artwork.photos")
                    Button("Choose a File…", systemImage: AppSymbol.folder) { isChoosingFile = true }
                    if kind == .logo, model.edit?.withoutLogo == false {
                        Button("No Logo, Write the Title", systemImage: AppSymbol.noMatch) {
                            Task { await model.chooseNoLogo() }
                        }
                        .accessibilityIdentifier("artwork.noLogo")
                    }
                    if model.hasChosenArtwork(kind) {
                        Button("Put Back to Automatic", systemImage: AppSymbol.putBack) {
                            Task { await model.putBackArtwork(kind) }
                        }
                        .accessibilityIdentifier("artwork.putBack")
                    }
                }
                if let duration = model.frameDurationMs, kind != .poster, kind != .logo {
                    Section {
                        Slider(value: $frameAt, in: 0...1) {
                            Text("Moment")
                        }
                        .accessibilityValue(MediaFormat.clock(ms: position(duration)))
                        Button("Use the Frame at \(MediaFormat.clock(ms: position(duration)))", systemImage: AppSymbol.frame) {
                            Task { await model.chooseFrame(atMs: position(duration), for: kind) }
                        }
                        .accessibilityIdentifier("artwork.frame")
                    } header: {
                        Text("From the Film")
                    }
                }
            }
            .disabled(model.isBusy)
            .overlay {
                if model.isBusy { ProgressView() }
            }
        }
        .task {
            model.problem = nil
            found = await model.artworkOptions(for: kind)
        }
        .onDisappear { model.problem = nil }
        .onChange(of: photo) { _, picked in
            guard let picked else { return }
            Task {
                await model.upload(try? await picked.loadTransferable(type: Data.self), for: kind)
                photo = nil
            }
        }
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let opened = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if opened { url.stopAccessingSecurityScopedResource() }
            Task { await model.upload(data, for: kind) }
        }
    }

    private func position(_ duration: Int) -> Int {
        // Not the very last moment: there may be no frame there.
        Int(Double(max(0, duration - 1000)) * frameAt)
    }

    private func optionButton(_ option: ArtworkOption) -> some View {
        Button {
            Task { await model.choose(option, for: kind) }
        } label: {
            ServerPicture(path: option.previewUrl)
                .frame(maxWidth: .infinity)
                .aspectRatio(aspect, contentMode: .fit)
                // A logo is often white: it lies on dark, as on its picture.
                .background(kind == .logo ? Color.lobbyTileFill[1] : Color.lobbySurfaceRaised(scheme))
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if option.selected {
                        Image(systemName: AppSymbol.done)
                            .font(.title2)
                            .foregroundStyle(Color.lobbyOnArtwork, Color.lobbyAccent(scheme))
                            .padding(AppTheme.Space.s)
                    }
                }
        }
        .buttonStyle(.lobbyTile)
        .accessibilityLabel(Self.name(option))
        .accessibilityAddTraits(option.selected ? .isSelected : [])
        .accessibilityIdentifier("artwork.option")
    }

    private static func name(_ option: ArtworkOption) -> String {
        switch option.source {
        case .tmdb: ["Picture from TMDB", option.language].compactMap { $0 }.joined(separator: ", ")
        case .frame: "Frame from the film"
        case .upload: "Own picture"
        case .unknown: "Picture"
        }
    }
}

/// Finds the film or series a title really is.
private struct MatchSearchView: View {
    let model: ItemEditModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var year = ""
    @State private var results: [MatchResult]?
    @State private var isSearching = false

    var body: some View {
        LobbySheet(title: "Find the Right Title", width: 600, height: 620) {
            LobbyForm {
                Section {
                    TextField("Title", text: $query, prompt: Text("Title"))
                        .onSubmit { Task { await search() } }
                        .accessibilityIdentifier("match.query")
                    TextField("Year", text: $year, prompt: Text("Any year"))
                        .onSubmit { Task { await search() } }
                        .accessibilityIdentifier("match.year")
                    Button("Search", systemImage: AppSymbol.search) { Task { await search() } }
                        .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("match.search")
                }
                Section {
                    if isSearching {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if let problem = model.problem {
                        Label(problem, systemImage: AppSymbol.problem)
                            .foregroundStyle(Color.lobbyFailure)
                    } else if let results, results.isEmpty {
                        Text("TMDB has nothing with that title.")
                            .foregroundStyle(.lobbySecondary)
                    }
                    ForEach(results ?? []) { result in
                        Button {
                            Task { if await model.setMatch(result.tmdb) { dismiss() } }
                        } label: {
                            row(result)
                        }
                        .buttonStyle(.lobbyRow)
                    }
                }
            }
            .disabled(model.isBusy)
        }
        .task {
            model.problem = nil
            query = model.title
            year = model.year
            await search()
        }
        .onDisappear { model.problem = nil }
    }

    private func row(_ result: MatchResult) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Space.m) {
            ZStack {
                Color.gray.opacity(0.2)
                if let path = result.previewUrl { ServerPicture(path: path) }
            }
            .frame(width: 48, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text([result.title, result.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                if let original = result.originalTitle, original != result.title {
                    Text(original).font(.footnote).foregroundStyle(.lobbySecondary)
                }
                if let overview = result.overview {
                    Text(overview)
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            if result.tmdb == model.edit?.match.tmdb {
                Image(systemName: AppSymbol.done).foregroundStyle(.lobbySecondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func search() async {
        guard !isSearching else { return }
        isSearching = true
        model.problem = nil
        results = await model.searchMatch(query, year: year)
        isSearching = false
    }
}
