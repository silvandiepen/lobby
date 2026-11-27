// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// The household's categories, for managers: which there are, in what order, how they look
/// and which library folders feed them.
struct CategoriesView: View {
    @Environment(AppModel.self) private var app
    @State private var model: CategoriesModel
    @State private var draft: CategoryDraft?
    @State private var removal: Removal?
    /// Making one category of several: the group, and the ones chosen to begin with.
    @State private var grouping: Grouping?
    /// Choosing categories, to drag or merge several at once.
    @State private var isSelecting = false
    /// The studio suggestions chosen to put somewhere together.
    @State private var chosenSuggestions: Set<String> = []
    /// Where suggestions go, while the manager says.
    @State private var placing: Placing?
    @State private var showsAllSuggestions = false
    #if os(iOS)
    @State private var editMode = EditMode.inactive
    private var isEditing: Bool { editMode.isEditing }
    #else
    private var isEditing: Bool { false }
    #endif

    private struct Placing: Identifiable {
        var suggestions: [CategorySuggestions.Suggestion]
        var id: [String] { suggestions.map(\.id) }
    }

    private struct Grouping: Identifiable {
        var group: CategoryGroup
        var chosen: Set<String>
        var id: String { group.id }
    }

    /// What is being removed, and whether the server needs to know where its contents go.
    private enum Removal: Hashable {
        case category(LibraryCategory)
        case group(CategoryGroup)

        var name: String {
            switch self {
            case .category(let category): category.name
            case .group(let group): CategoriesModel.name(of: group)
            }
        }
    }

    init(app: AppModel) {
        _model = State(wrappedValue: CategoriesModel(app: app))
    }

    var body: some View {
        List {
            if model.canUndo {
                Section {
                    Button("Undo the Last Arrangement", systemImage: AppSymbol.undo) {
                        Task { await model.undo() }
                    }
                    .buttonStyle(.lobbyText)
                    .accessibilityIdentifier("categories.undo")
                    .lobbyPanelRow(isFirst: true, isLast: true)
                } footer: {
                    Text("Names, places and order go back to how they were. Categories it made are removed; no title is.")
                        .foregroundStyle(.lobbySecondary)
                        .lobbyPanelHeading()
                }
                .listSectionSeparator(.hidden)
            }
            if !model.suggestions.isEmpty {
                suggestionsSection
            }
            ForEach(model.groups) { group in
                section(group)
            }
            if model.edit != nil {
                Section {
                    Button("Add a Group…", systemImage: AppSymbol.add) {
                        draft = CategoryDraft(newGroup: ())
                    }
                    .buttonStyle(.lobbyText)
                    .accessibilityIdentifier("categories.addGroup")
                    .lobbyPanelRow(isFirst: true, isLast: true)
                } footer: {
                    Text("A group is a part of the library of its own. Its titles are not among Movies and Series.")
                        .foregroundStyle(.lobbySecondary)
                        .lobbyPanelHeading()
                }
                .listSectionSeparator(.hidden)
                foldersSection
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #endif
        .lobbyReadableList()
        .lobbyPage()
        .overlay {
            if model.edit == nil, model.problem == nil { ProgressView() }
        }
        .disabled(model.isBusy)
        #if os(iOS)
        .environment(\.editMode, $editMode)
        #endif
        .toolbar { toolbar }
        .navigationTitle("Categories")
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(item: $draft) { draft in
            CategoryEditor(model: model, draft: draft)
        }
        .sheet(item: $placing) { placing in
            SuggestionPlacementSheet(model: model, suggestions: placing.suggestions) {
                chosenSuggestions.subtract(placing.id)
            }
        }
        .sheet(item: $grouping) { grouping in
            CategoryGroupingSheet(model: model, group: grouping.group, chosen: grouping.chosen)
        }
        .sheet(item: Binding(get: { model.question }, set: { model.question = $0 })) { question in
            KidsQuestionSheet(model: model, question: question)
        }
        .alert(
            "That did not work",
            // While the editor is open it shows the problem itself.
            isPresented: Binding(get: { model.problem != nil && draft == nil }, set: { if !$0 { model.problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
        .confirmationDialog(
            removal.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            titleVisibility: .visible, presenting: removal
        ) { removal in
            removalButtons(removal)
        } message: { removal in
            Text(removalMessage(removal))
        }
    }

    // MARK: A group and its categories

    private func section(_ group: CategoryGroup) -> some View {
        Section {
            #if os(macOS)
            // A heading of a Mac list is a bar across the window. This one is a row.
            heading(group)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            #endif
            let tree = model.tree(of: group)
            ForEach(tree.rows) { row in
                self.row(row.category, in: group, tree: tree)
                    .padding(.leading, row.isInside ? AppTheme.Space.l : 0)
                    .categoryDragging(row.id, canHold: !row.isInside, model: model, isEnabled: !isEditing && !model.isBusy)
                    .lobbyPanelRow(isFirst: row.id == tree.rows.first?.id)
            }
            // iPhone and iPad in edit mode: the system's handles, within the list.
            .onMove(perform: isEditing ? { offsets, destination in
                Task { await model.moveCategories(in: group, from: offsets, to: destination) }
            } : nil)
            Button("Add a Category…", systemImage: AppSymbol.add) {
                draft = CategoryDraft(newCategoryIn: group)
            }
            .buttonStyle(.lobbyText)
            .accessibilityIdentifier("categories.add.\(CategoriesModel.name(of: group))")
            // Dropped here, at the top of this group, last.
            .categoryDropping(atEndOf: group.id, model: model, isEnabled: !isEditing && !model.isBusy)
            .lobbyPanelRow(isFirst: group.entries.isEmpty, isLast: true)
        } header: {
            #if !os(macOS)
            heading(group)
            #endif
        }
        .listSectionSeparator(.hidden)
    }

    private func heading(_ group: CategoryGroup) -> some View {
        HStack(spacing: AppTheme.Space.s) {
            CategoryMark(look: CategoryLook(group: group.id, in: model.edit?.setup ?? .none), fallback: group.name == nil ? AppSymbol.library : AppSymbol.group, area: 700, maxWidth: 80, maxHeight: 24)
            Text(CategoriesModel.name(of: group))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            groupMenu(group)
        }
        #if os(macOS)
        .font(.headline)
        #endif
        .lobbyPanelHeading()
    }

    private func row(_ category: LibraryCategory, in group: CategoryGroup, tree: CategoryTree) -> some View {
        let place = tree.row(category.id)
        let parent = place?.parentID.flatMap(tree.row)
        let isChosen = model.selection.contains(category.id)
        return Button {
            if isSelecting || Self.commandIsDown {
                toggle(category.id)
            } else {
                draft = CategoryDraft(category, in: group)
            }
        } label: {
            HStack(spacing: AppTheme.Space.m) {
                if isSelecting || !model.selection.isEmpty {
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                }
                if place?.isInside == true {
                    Image(systemName: AppSymbol.inside)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                CategoryMark(look: CategoryLook(category: category.id, in: model.edit?.setup ?? .none), area: 900, maxWidth: 64, maxHeight: 28)
                    .foregroundStyle(category.color.map(Color.lobbyProfile) ?? .secondary)
                    .frame(width: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name)
                        .foregroundStyle(.primary)
                    if let folders = folderNames(category) {
                        Text(folders)
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                    }
                    if let follows = model.follows(category) {
                        Label(follows, systemImage: AppSymbol.studio)
                            .font(.footnote)
                            .foregroundStyle(.lobbySecondary)
                            .accessibilityIdentifier("categories.follows.\(category.name)")
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: AppSymbol.reorder)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.lobbyRow)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("categories.row.\(category.name)")
        .accessibilityValue(parent.map { "Inside \($0.category.name)" } ?? "")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .contextMenu {
            Button("Edit…", systemImage: AppSymbol.edit) { draft = CategoryDraft(category, in: group) }
            Button(isChosen ? "Deselect" : "Select", systemImage: isChosen ? "circle" : "checkmark.circle") {
                toggle(category.id)
            }
            let targets = model.mergeTargets(of: model.selection.union([category.id]))
            if model.selection.subtracting([category.id]).count > 0, targets.contains(where: { $0.id == category.id }) {
                Button("Merge Chosen into \(category.name)", systemImage: AppSymbol.inside) {
                    Task { await model.merge(model.selection.union([category.id]), into: category.id) }
                }
            }
            if let parent {
                Button("Take Out of \(parent.category.name)", systemImage: AppSymbol.takeOut) {
                    Task { await model.takeOut(category.id) }
                }
            }
            let parents = tree.parents(for: category.id)
            if !parents.isEmpty {
                Menu("Put Inside", systemImage: AppSymbol.inside) {
                    ForEach(parents) { other in
                        Button(other.category.name) { Task { await model.putCategory(category.id, inside: other.id) } }
                    }
                }
            }
            if place?.isInside == false {
                Button("Add a Category Inside…", systemImage: AppSymbol.add) {
                    draft = CategoryDraft(newCategoryIn: group, inside: category.id)
                }
                if place?.hasChildren == false {
                    Button("Make a Category of This and Others…", systemImage: AppSymbol.group) {
                        grouping = Grouping(group: group, chosen: [category.id])
                    }
                }
            }
            Button("Move Up", systemImage: AppSymbol.moveUp) { Task { await model.moveCategory(category.id, by: -1) } }
                .disabled(!model.canMoveCategory(category.id, by: -1))
            Button("Move Down", systemImage: AppSymbol.moveDown) { Task { await model.moveCategory(category.id, by: 1) } }
                .disabled(!model.canMoveCategory(category.id, by: 1))
            Menu("Move to Group", systemImage: AppSymbol.group) {
                ForEach(model.groups.filter { $0.id != group.id }) { other in
                    Button(CategoriesModel.name(of: other)) { Task { await model.moveCategory(category.id, toGroup: other.id) } }
                }
            }
            Divider()
            Button("Delete…", systemImage: AppSymbol.remove, role: .destructive) { removal = .category(category) }
        }
    }

    private func toggle(_ id: String) {
        if model.selection.remove(id) == nil { model.selection.insert(id) }
    }

    /// On the Mac, a click with ⌘ chooses a row instead of opening it.
    private static var commandIsDown: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.command)
        #else
        false
        #endif
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Undo", systemImage: AppSymbol.undo) {
                Task { await model.undo() }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!model.canUndo || model.isBusy)
            .help("Undo the last arrangement")
            .accessibilityIdentifier("categories.toolbarUndo")
            let targets = model.mergeTargets(of: model.selection)
            if !targets.isEmpty {
                Menu("Merge into…", systemImage: AppSymbol.inside) {
                    ForEach(targets) { target in
                        Button(target.name) { Task { await model.merge(model.selection, into: target.id) } }
                    }
                }
                .accessibilityIdentifier("categories.merge")
            }
            Button(isSelecting ? "Done" : "Select") {
                withAnimation {
                    isSelecting.toggle()
                    if !isSelecting { model.selection = [] }
                }
            }
            .accessibilityIdentifier("categories.select")
            #if os(iOS)
            Button(isEditing ? "Done" : "Reorder") {
                withAnimation { editMode = isEditing ? .inactive : .active }
            }
            .accessibilityIdentifier("categories.reorder")
            #endif
        }
    }

    // MARK: Studios

    private var suggestionsSection: some View {
        let shown = showsAllSuggestions ? model.suggestions : Array(model.suggestions.prefix(3))
        let chosen = model.suggestions.filter { chosenSuggestions.contains($0.id) }
        return Section {
            ForEach(shown) { suggestion in
                SuggestionCard(
                    model: model, suggestion: suggestion,
                    isChosen: Binding(
                        get: { chosenSuggestions.contains(suggestion.id) },
                        set: { if $0 { chosenSuggestions.insert(suggestion.id) } else { chosenSuggestions.remove(suggestion.id) } }),
                    place: { placing = Placing(suggestions: chosen.contains(suggestion) && chosen.count > 1 ? chosen : [suggestion]) })
                    .lobbyPanelRow(isFirst: suggestion.id == shown.first?.id, isLast: suggestion.id == shown.last?.id && chosen.count < 2)
            }
            if chosen.count > 1 {
                Button("Add \(chosen.count) Studios to…", systemImage: AppSymbol.add) {
                    placing = Placing(suggestions: chosen)
                }
                .buttonStyle(.lobbyText)
                .accessibilityIdentifier("suggestions.addChosen")
                .lobbyPanelRow(isLast: true)
            }
        } header: {
            HStack {
                Text("Studios")
                    #if os(macOS)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    #endif
                Spacer()
                if model.suggestions.count > 3 {
                    Button(showsAllSuggestions ? "Show Fewer" : "Show All \(model.suggestions.count)") {
                        withAnimation { showsAllSuggestions.toggle() }
                    }
                    .buttonStyle(.lobbyText)
                    .accessibilityIdentifier("suggestions.showAll")
                }
            }
            .lobbyPanelHeading()
        }
        .listSectionSeparator(.hidden)
    }

    /// nil when its one folder has its name: that says nothing more.
    private func folderNames(_ category: LibraryCategory) -> String? {
        let folders = model.folders(of: category.id).map(\.name)
        if folders == [category.name] { return nil }
        return folders.isEmpty ? "No folder" : folders.joined(separator: ", ")
    }

    private func groupMenu(_ group: CategoryGroup) -> some View {
        Menu {
            Button("Edit…", systemImage: AppSymbol.edit) { draft = CategoryDraft(group) }
            if model.tree(of: group).topLevel.filter({ !$0.hasChildren }).count > 1 {
                Button("Make a Category of Several…", systemImage: AppSymbol.inside) {
                    grouping = Grouping(group: group, chosen: [])
                }
            }
            if group.name != nil {
                Button("Move Up", systemImage: AppSymbol.moveUp) { Task { await model.moveGroup(group.id, by: -1) } }
                    .disabled(!model.canMoveGroup(group.id, by: -1))
                Button("Move Down", systemImage: AppSymbol.moveDown) { Task { await model.moveGroup(group.id, by: 1) } }
                    .disabled(!model.canMoveGroup(group.id, by: 1))
                Divider()
                Button("Delete…", systemImage: AppSymbol.remove, role: .destructive) { removal = .group(group) }
            }
        } label: {
            Image(systemName: AppSymbol.more)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonStyle(.lobbyIcon)
        .accessibilityLabel("More for \(CategoriesModel.name(of: group))")
        .accessibilityIdentifier("categories.group.\(CategoriesModel.name(of: group))")
    }

    // MARK: Folders

    private var foldersSection: some View {
        Section {
            ForEach(model.folders) { folder in
                Picker(selection: Binding(
                    get: { folder.categoryId },
                    set: { chosen in Task { await model.assign(folder: folder.id, to: chosen) } })
                ) {
                    Text("No category").tag(String?.none)
                    ForEach(model.groups) { group in
                        Section(CategoriesModel.name(of: group)) {
                            ForEach(CategoryTree(group).rows) { row in
                                Text(row.isInside ? "    \(row.category.name)" : row.category.name).tag(Optional(row.id))
                            }
                        }
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.name)
                            if !folder.available {
                                Text("Not connected")
                                    .font(.footnote)
                                    .foregroundStyle(.lobbySecondary)
                            }
                        }
                    } icon: {
                        Image(systemName: AppSymbol.folder)
                            .foregroundStyle(.lobbySecondary)
                    }
                }
                .accessibilityIdentifier("categories.folder.\(folder.name)")
                .lobbyPanelRow(isFirst: folder.id == model.folders.first?.id, isLast: folder.id == model.folders.last?.id)
            }
        } header: {
            Text("Library Folders")
                #if os(macOS)
                .font(.headline)
                .foregroundStyle(Color.primary)
                #endif
                .lobbyPanelHeading()
        } footer: {
            Text("What is in a folder is in its category by itself. A single title can be put in other categories on its own page.")
                .foregroundStyle(.lobbySecondary)
                .lobbyPanelHeading()
        }
        .listSectionSeparator(.hidden)
    }

    // MARK: Removing

    @ViewBuilder
    private func removalButtons(_ removal: Removal) -> some View {
        switch removal {
        case .category(let category):
            if model.folders(of: category.id).isEmpty {
                Button("Delete", role: .destructive) {
                    Task { await model.deleteCategory(category.id, foldersTo: nil) }
                }
                .accessibilityIdentifier("categories.confirmDelete")
            } else {
                // Its folders have to feed something, or plainly nothing.
                ForEach(model.edit?.setup.categories.filter { $0.id != category.id } ?? []) { other in
                    Button("Delete, Folders to \(other.name)", role: .destructive) {
                        Task { await model.deleteCategory(category.id, foldersTo: .category(other.id)) }
                    }
                }
                Button("Delete, Folders to No Category", role: .destructive) {
                    Task { await model.deleteCategory(category.id, foldersTo: FoldersTarget.none) }
                }
            }
        case .group(let group):
            if group.entries.isEmpty {
                Button("Delete", role: .destructive) {
                    Task { await model.deleteGroup(group.id, movingCategoriesTo: nil) }
                }
                .accessibilityIdentifier("categories.confirmDelete")
            } else {
                ForEach(model.groups.filter { $0.id != group.id }) { other in
                    Button("Delete, Categories to \(CategoriesModel.name(of: other))", role: .destructive) {
                        Task { await model.deleteGroup(group.id, movingCategoriesTo: other.id) }
                    }
                }
            }
        }
    }

    private func removalMessage(_ removal: Removal) -> String {
        switch removal {
        case .category(let category):
            let folders = model.folders(of: category.id).map(\.name)
            return folders.isEmpty
                ? "No title is deleted. A title that was put in it by hand keeps its other categories, or goes back to its folder's."
                : "No title is deleted. Choose which category \(folders.joined(separator: ", ")) goes to: its titles are shown there."
        case .group(let group):
            return group.entries.isEmpty
                ? "It holds no categories."
                : "Choose where its categories go. No title is deleted. In the main library its titles are among everything else."
        }
    }
}
