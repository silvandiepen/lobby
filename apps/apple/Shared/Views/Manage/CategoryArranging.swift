// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A studio the household has enough of, offered as a category. Nothing happens by itself:
/// "Add to…" asks where it goes.
struct SuggestionCard: View {
    let model: CategoriesModel
    let suggestion: CategorySuggestions.Suggestion
    /// Chosen to go somewhere together with others.
    @Binding var isChosen: Bool
    let place: () -> Void

    @Environment(AppModel.self) private var app
    @State private var logo: CGImage?

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Space.m) {
            Toggle(isOn: $isChosen) {
                Text("Choose \(suggestion.name)")
            }
            .toggleStyle(ChooseStyle())
            .accessibilityLabel("Choose \(suggestion.name)")
            .accessibilityIdentifier("suggestion.choose.\(suggestion.name)")
            Group {
                if let logo {
                    Image(decorative: logo, scale: 1)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                } else {
                    Image(systemName: AppSymbol.studio)
                        .font(.title2)
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 64, height: 36)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                Text("You have \(suggestion.count) \(suggestion.count == 1 ? "title" : "titles") from \(suggestion.name).")
                    .fixedSize(horizontal: false, vertical: true)
                if !suggestion.titles.isEmpty {
                    Text(ListFormatter.localizedString(byJoining: suggestion.titles.prefix(3).map(\.title)))
                        .font(.footnote)
                        .foregroundStyle(.lobbySecondary)
                        .lineLimit(2)
                }
                HStack(spacing: AppTheme.Space.m) {
                    Button("Add to…", action: place)
                        .buttonStyle(.lobbyText)
                        .accessibilityIdentifier("suggestion.accept.\(suggestion.name)")
                    Button("Dismiss") { Task { await model.dismiss(suggestion) } }
                        .buttonStyle(.lobbyText)
                        .accessibilityIdentifier("suggestion.dismiss.\(suggestion.name)")
                }
                .padding(.top, AppTheme.Space.xs)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppTheme.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("suggestion.\(suggestion.name)")
        .task(id: suggestion.logoPreviewPath) {
            guard let path = suggestion.logoPreviewPath else { return }
            logo = await app.preview(atPath: path)
        }
    }

    /// A round mark that chooses, as in a list one picks from.
    private struct ChooseStyle: ToggleStyle {
        func makeBody(configuration: Configuration) -> some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isOn ? "Chosen" : "")
        }
    }
}

/// Where studio suggestions go: inside a category there is, joined to one, or new in a group.
/// The manager says; nothing is put at the top of a group by itself.
struct SuggestionPlacementSheet: View {
    let model: CategoriesModel
    let suggestions: [CategorySuggestions.Suggestion]
    /// After they were placed.
    let done: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choice: SuggestionChoice

    init(model: CategoriesModel, suggestions: [CategorySuggestions.Suggestion], done: @escaping () -> Void) {
        self.model = model
        self.suggestions = suggestions
        self.done = done
        _choice = State(initialValue: SuggestionChoice(suggestions))
    }

    private var setup: CategoryGroups { model.edit?.setup ?? .none }
    private var title: String {
        suggestions.count == 1 ? "Add \(suggestions[0].name)" : "Add \(suggestions.count) Studios"
    }

    var body: some View {
        LobbySheet(
            title: title, width: 560, height: 620,
            confirm: .init(title: "Add", isEnabled: choice.placement != nil && !model.isBusy) {
                guard let placement = choice.placement else { return }
                if await model.place(choice.ids, placement) {
                    done()
                    dismiss()
                } else if model.question != nil {
                    // Kids viewers would see more: the question is shown over the list.
                    done()
                    dismiss()
                }
            }
        ) {
            LobbyForm {
                Section {
                    Text(ListFormatter.localizedString(byJoining: suggestions.map(\.name)))
                        .foregroundStyle(.lobbySecondary)
                }
                Section {
                    Picker("Where", selection: $choice.destination) {
                        Text("Choose…").tag(SuggestionChoice.Destination?.none)
                        ForEach(SuggestionChoice.parents(in: setup), id: \.group.id) { entry in
                            Section("Inside a category of \(CategoriesModel.name(of: entry.group))") {
                                ForEach(entry.categories) { category in
                                    Text("Inside \(category.name)").tag(Optional(SuggestionChoice.Destination.inside(categoryID: category.id)))
                                }
                            }
                        }
                        Section("Join a category") {
                            ForEach(setup.categories) { category in
                                Text(category.rule == nil ? "Into \(category.name)" : "Into \(category.name) (follows studios)")
                                    .tag(Optional(SuggestionChoice.Destination.join(categoryID: category.id)))
                            }
                        }
                        Section("A new category at the top") {
                            ForEach(setup.groups) { group in
                                Text("New in \(CategoriesModel.name(of: group))")
                                    .tag(Optional(SuggestionChoice.Destination.newCategory(groupID: group.id)))
                            }
                        }
                    }
                    .accessibilityIdentifier("placement.where")
                    if suggestions.count > 1, choice.destination.map({ if case .join = $0 { false } else { true } }) == true {
                        Toggle("One Category for All", isOn: $choice.together)
                            .accessibilityIdentifier("placement.together")
                    }
                    if choice.makesOne {
                        TextField("Name", text: $choice.name, prompt: Text(suggestions[0].name))
                            .accessibilityIdentifier("placement.name")
                    }
                } footer: {
                    if let summary = choice.summary(in: setup) {
                        Text(summary)
                    } else {
                        Text("Inside a category keeps the sidebar short: it is a section of that category's page.")
                    }
                }
                if let problem = model.problem {
                    Section {
                        Label(problem, systemImage: AppSymbol.problem)
                            .foregroundStyle(Color.lobbyFailure)
                    }
                }
            }
        }
        .onAppear { model.problem = nil }
    }
}

/// One new category with some of a group's categories inside it: a studio with its classics,
/// sequels and the rest. Those keep their folders, titles, logos and kids limits.
struct CategoryGroupingSheet: View {
    let model: CategoriesModel
    let group: CategoryGroup
    @State var chosen: Set<String>

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var names: [String: String] = [:]
    @State private var logoFrom: String?

    private var tree: CategoryTree { model.tree(of: group) }
    /// Top-level ones without others inside them: only those can go in.
    private var candidates: [CategoryTree.Row] { tree.topLevel.filter { !$0.hasChildren } }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        LobbySheet(
            title: "New Category of Several", width: 560, height: 640,
            confirm: .init(title: "Make", isEnabled: (1...60).contains(trimmed.count) && !chosen.isEmpty && !model.isBusy) {
                let ordered = candidates.map(\.id).filter(chosen.contains)
                guard let arrangement = tree.makingParent(named: trimmed, of: ordered, renaming: names, logoFrom: logoFrom) else { return }
                await model.arrange(arrangement)
                if model.problem == nil { dismiss() }
            }
        ) {
            LobbyForm {
                Section {
                    TextField("Name", text: $name, prompt: Text("Category name"))
                        .accessibilityIdentifier("grouping.name")
                    Picker("Logo and Colour", selection: $logoFrom) {
                        Text("None").tag(String?.none)
                        ForEach(candidates.filter { chosen.contains($0.id) }) { row in
                            Text("Of \(row.category.name)").tag(Optional(row.id))
                        }
                    }
                    .accessibilityIdentifier("grouping.logoFrom")
                } footer: {
                    Text("It takes the logo of the one chosen here; that one keeps its own.")
                }
                Section {
                    ForEach(candidates) { row in
                        VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
                            Toggle(row.category.name, isOn: Binding(
                                get: { chosen.contains(row.id) },
                                set: { on in
                                    if on { chosen.insert(row.id) } else { chosen.remove(row.id); names[row.id] = nil }
                                    if let logo = logoFrom, !chosen.contains(logo) { logoFrom = nil }
                                }))
                            .accessibilityIdentifier("grouping.choose.\(row.category.name)")
                            if chosen.contains(row.id) {
                                TextField(
                                    "Name inside", text: Binding(get: { names[row.id] ?? "" }, set: { names[row.id] = $0 }),
                                    prompt: Text("Name inside, or keep \(row.category.name)"))
                                    .font(.callout)
                                    .accessibilityIdentifier("grouping.rename.\(row.category.name)")
                            }
                        }
                    }
                } header: {
                    Text("Inside It")
                } footer: {
                    Text("Folders, chosen titles, logos and kids limits stay with each category. Undo takes all of it back.")
                }
                if let problem = model.problem {
                    Section {
                        Label(problem, systemImage: AppSymbol.problem)
                            .foregroundStyle(Color.lobbyFailure)
                    }
                }
            }
        }
        .onAppear { model.problem = nil }
    }
}

/// What a change would let children see, before it is made: per child how many titles and a
/// few of them. Allow sends it again with exactly that; Cancel leaves everything as it is.
struct KidsQuestionSheet: View {
    let model: CategoriesModel
    let question: KidsQuestion

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LobbySheet(
            title: "Children Would See More", width: 520, height: 560,
            confirm: .init(title: "Allow", isEnabled: !model.isBusy) {
                dismiss()
                await model.allow(question)
            }
        ) {
            LobbyForm {
                Section {
                    Text("This change lets these kids viewers see titles they do not see now. Nothing changes until you allow it.")
                        .foregroundStyle(.lobbySecondary)
                }
                ForEach(question.changes) { change in
                    Section {
                        if change.appearing.count > 0 {
                            Text(Self.count(change.appearing.count, "would appear"))
                                .font(.headline)
                            ForEach(change.appearing.titles.prefix(5)) { title in
                                Text(title.title)
                            }
                            if change.appearing.count > 5 {
                                Text("and \(change.appearing.count - 5) more")
                                    .foregroundStyle(.lobbySecondary)
                            }
                        }
                        if change.disappearing.count > 0 {
                            Text(Self.count(change.disappearing.count, "would no longer be there"))
                                .foregroundStyle(.lobbySecondary)
                        }
                    } header: {
                        Text(change.name)
                    }
                    .accessibilityIdentifier("kidsQuestion.\(change.name)")
                }
            }
        }
        .onDisappear {
            // Cancel, or swiped away: nothing is sent.
            if model.question?.token == question.token { model.question = nil }
        }
    }

    static func count(_ count: Int, _ words: String) -> String {
        "\(count) \(count == 1 ? "title" : "titles") \(words)"
    }
}
