// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Observation

/// The household's categories for a manager: what there is, and every change to it. Each
/// change names the state it is based on; when someone else was first, the newer state is
/// shown and nothing of theirs is overwritten.
@MainActor
@Observable
final class CategoriesModel {
    private(set) var edit: CategoriesEdit?
    private(set) var isBusy = false
    var problem: String?
    /// A change that would let a kids viewer see more, waiting for the manager's word.
    var question: KidsQuestion?
    /// Studios that could be a category. Empty from a server from before them.
    private(set) var suggestions: [CategorySuggestions.Suggestion] = []
    /// What studios are called, as far as suggestions told: for "Follows …".
    private(set) var studioNames: [String: String] = [:]

    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    var groups: [CategoryGroup] { edit?.setup.groups ?? [] }
    var namedGroups: [CategoryGroup] { groups.filter { $0.name != nil } }
    var folders: [CategoriesEdit.Folder] { edit?.folders ?? [] }
    var colors: [String] { edit?.colors ?? [] }

    nonisolated static func name(of group: CategoryGroup) -> String {
        group.name ?? "Main Library"
    }

    func folders(of categoryID: String) -> [CategoriesEdit.Folder] {
        folders.filter { $0.categoryId == categoryID }
    }

    func group(ofCategory id: String) -> CategoryGroup? {
        groups.first { $0.entries.contains { $0.id == id } }
    }

    /// - Parameter suggestions: Whether to read the studio suggestions too; the sidebar needs none.
    func load(suggestions: Bool = true) async {
        do {
            edit = try await app.asManager { try await $0.categoriesEdit() }
        } catch {
            problem = await app.managerProblem(error)
            return
        }
        if suggestions { await loadSuggestions() }
    }

    func tree(of group: CategoryGroup) -> CategoryTree { CategoryTree(group) }

    /// The ids of the categories this one is among: those inside the same one, or the
    /// top-level ones of its group.
    private func siblings(of id: String) -> (group: CategoryGroup, parentID: String?, ids: [String])? {
        guard let group = group(ofCategory: id) else { return nil }
        let tree = CategoryTree(group)
        let parent = tree.row(id)?.parentID
        return (group, parent, tree.rows.filter { $0.parentID == parent }.map(\.id))
    }

    // MARK: Order

    /// A row was dragged in a group's list: reordered, put inside a category or taken out.
    func moveCategories(in group: CategoryGroup, from offsets: IndexSet, to destination: Int) async {
        let tree = CategoryTree(group)
        guard let arrangement = tree.moving(from: offsets, to: destination) else { return }
        await arrangeAskingFirst(arrangement)
    }

    /// One place up (-1) or down (1) among those beside it.
    func moveCategory(_ id: String, by step: Int) async {
        guard let (group, parent, ids) = siblings(of: id), let order = Self.stepped(ids, id, by: step) else { return }
        await change { client, revision, token in
            if parent == nil, !CategoryTree(group).rows.contains(where: \.isInside) {
                // As before categories could be inside another: a server from then knows this.
                return try await client.orderCategories(groupID: group.id, ids: order, revision: revision, kidsToken: token)
            }
            return try await client.arrange(
                CategoryArrangement(order: [.init(groupID: group.id, parentID: parent, ids: order)]), revision: revision,
                kidsToken: token)
        }
    }

    func moveGroup(_ id: String, by step: Int) async {
        guard let ids = Self.stepped(namedGroups.map(\.id), id, by: step) else { return }
        await change { try await $0.orderGroups(ids, revision: $1, kidsToken: $2) }
    }

    func canMoveCategory(_ id: String, by step: Int) -> Bool {
        siblings(of: id).flatMap { Self.stepped($0.ids, id, by: step) } != nil
    }

    // MARK: Dragging

    /// The ids being dragged, while a drag from this screen or the sidebar is under way. A drop
    /// target needs them before the drop: what is dragged decides whether it may land there.
    var dragging: [String]?

    /// The categories a manager chose, to drag or merge together.
    var selection: Set<String> = []

    /// What a drag of `id` carries: the chosen ones when it is one of them, in the household's order.
    func dragged(startingAt id: String) -> [String] {
        guard selection.contains(id) else { return [id] }
        return (edit?.setup.categories ?? []).map(\.id).filter(selection.contains)
    }

    /// Why the dragged categories cannot land there; nil when they can, or nothing would change.
    func refusal(dropping ids: [String], on target: CategoryDropTarget) -> CategoryDropRefusal? {
        CategoryDrop(setup: edit?.setup ?? .none).refusal(moving: ids, to: target)
    }

    /// A drop: one arrangement, asked about first.
    @discardableResult
    func drop(_ ids: [String], on target: CategoryDropTarget) async -> Bool {
        dragging = nil
        guard case .success(let arrangement?) = CategoryDrop(setup: edit?.setup ?? .none).arrangement(moving: ids, to: target) else {
            return false
        }
        let done = await arrangeAskingFirst(arrangement)
        if done { selection.subtract(ids) }
        return done
    }

    /// A dry run first: when a kids viewer would see more, the manager is asked with what the
    /// server said, and only Allow sends it. Otherwise it is sent with the dry run's token, so
    /// that what changed meanwhile is asked about too.
    @discardableResult
    func arrangeAskingFirst(_ arrangement: CategoryArrangement) async -> Bool {
        guard !arrangement.isEmpty else { return false }
        return await askingFirst { try await $0.arrange(arrangement, revision: $1, dryRun: $2, kidsToken: $3) }
    }

    // MARK: Merging

    /// The categories among the chosen ones that others can be merged into: all of them, but
    /// not one inside another that is chosen too.
    func mergeTargets(of ids: Set<String>) -> [LibraryCategory] {
        let chosen = (edit?.setup.categories ?? []).filter { ids.contains($0.id) }
        guard chosen.count > 1 else { return [] }
        return chosen.filter { one in !(one.parentId.map(ids.contains) ?? false) }
    }

    /// The chosen ones become one: folders, chosen titles, studios and those inside them go to it.
    @discardableResult
    func merge(_ ids: Set<String>, into target: String) async -> Bool {
        let going = (edit?.setup.categories ?? []).map(\.id).filter { ids.contains($0) && $0 != target }
        guard !going.isEmpty else { return false }
        let done = await askingFirst { try await $0.mergeCategories(going, into: target, revision: $1, dryRun: $2, kidsToken: $3) }
        if done { selection = [] }
        return done
    }

    // MARK: Inside another

    /// Several changes as one, which the undo takes back.
    @discardableResult
    func arrange(_ arrangement: CategoryArrangement) async -> Bool {
        await arrangeAskingFirst(arrangement)
    }

    func putCategory(_ id: String, inside parent: String) async {
        guard let group = group(ofCategory: id), let arrangement = CategoryTree(group).putting(id, inside: parent) else { return }
        await arrangeAskingFirst(arrangement)
    }

    func takeOut(_ id: String) async {
        guard let group = group(ofCategory: id), let arrangement = CategoryTree(group).takingOut(id) else { return }
        await arrangeAskingFirst(arrangement)
    }

    /// Whether the last arrangement can still be taken back.
    var canUndo: Bool { edit?.undo != nil }

    func undo() async {
        guard let token = edit?.undo else { return }
        await change { try await $0.undoArrangement(token: token, revision: $1, kidsToken: $2) }
    }

    // MARK: Kids viewers

    /// The manager allows what the waiting change shows the children: it is sent again with
    /// the token that names exactly that.
    func allow(_ question: KidsQuestion) async {
        if self.question?.token == question.token { self.question = nil }
        await change(asked: question.token, question.retry)
    }

    // MARK: Studios

    func loadSuggestions() async {
        do {
            let found = try await app.asManager { try await $0.categorySuggestions() }
            take(found)
        } catch {
            // A server from before studios has no suggestions; that is no problem.
            suggestions = []
        }
    }

    private func take(_ found: CategorySuggestions) {
        suggestions = found.suggestions
        for studio in found.suggestions.flatMap(\.studios) { studioNames[studio.id] = studio.name }
    }

    /// Suggestions where the manager said: never anywhere by themselves.
    @discardableResult
    func place(_ ids: [String], _ placement: SuggestionPlacement) async -> Bool {
        guard !ids.isEmpty else { return false }
        let saved = await askingFirst { try await $0.acceptSuggestions(ids, placement: placement, revision: $1, dryRun: $2, kidsToken: $3) }
        if saved { await loadSuggestions() }
        return saved
    }

    func dismiss(_ suggestion: CategorySuggestions.Suggestion) async {
        do {
            let found = try await app.asManager { try await $0.dismissSuggestion(id: suggestion.id) }
            take(found)
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    /// "Follows …" for a category with a studio rule; nil for one without.
    func follows(_ category: LibraryCategory) -> String? {
        guard let rule = category.rule, !rule.studioIds.isEmpty else { return nil }
        let names = rule.studioIds.compactMap { studioNames[$0] }
        let words = names.count == rule.studioIds.count
            ? ListFormatter.localizedString(byJoining: Array(Set(names)).sorted())
            : rule.studioIds.count == 1 ? "a studio" : "\(rule.studioIds.count) studios"
        let titles = app.wholeCatalogue.items.filter { $0.ruleCategoryIds?.contains(category.id) == true }.count
        return "Follows \(words)" + (titles > 0 ? " · \(titles) \(titles == 1 ? "title" : "titles")" : "")
    }

    func canMoveGroup(_ id: String, by step: Int) -> Bool {
        Self.stepped(namedGroups.map(\.id), id, by: step) != nil
    }

    func moveCategory(_ id: String, toGroup groupID: String) async {
        guard group(ofCategory: id)?.id != groupID else { return }
        await change { try await $0.moveCategory(id: id, toGroup: groupID, revision: $1, kidsToken: $2) }
    }

    nonisolated static func moved(_ ids: [String], from offsets: IndexSet, to destination: Int) -> [String] {
        let taken = offsets.map { ids[$0] }
        var kept = ids
        for offset in offsets.reversed() { kept.remove(at: offset) }
        kept.insert(contentsOf: taken, at: destination - offsets.count { $0 < destination })
        return kept
    }

    nonisolated static func stepped(_ ids: [String], _ id: String, by step: Int) -> [String]? {
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + step) else { return nil }
        var ids = ids
        ids.swapAt(index, index + step)
        return ids
    }

    // MARK: Folders and removing

    func assign(folder id: String, to categoryID: String?) async {
        await change { try await $0.assignFolder(id: id, to: categoryID, revision: $1, kidsToken: $2) }
    }

    /// The server asks where the folders go when there are any.
    @discardableResult
    func deleteCategory(_ id: String, foldersTo target: FoldersTarget?) async -> Bool {
        await change { try await $0.deleteCategory(id: id, foldersTo: target, revision: $1, kidsToken: $2) }
    }

    @discardableResult
    func deleteGroup(_ id: String, movingCategoriesTo target: String?) async -> Bool {
        await change { try await $0.deleteGroup(id: id, movingCategoriesTo: target, revision: $1, kidsToken: $2) }
    }

    // MARK: Saving a category or group

    /// Makes or changes a category or group as it was filled in. What was filled in stays
    /// when it is refused.
    ///
    /// - Returns: whether everything was saved.
    func save(_ draft: CategoryDraft) async -> Bool {
        let name = draft.trimmedName
        let owner: CategoryOwner
        switch draft.subject {
        case .newCategory(let groupID):
            let before = Set(edit?.setup.categories.map(\.id) ?? [])
            let target = draft.groupID ?? groupID
            guard await change({
                try await $0.createCategory(
                    groupID: target, parentID: draft.parentID, name: name, icon: draft.icon, color: draft.color, revision: $1,
                    kidsToken: $2)
            }), let made = edit?.setup.categories.first(where: { !before.contains($0.id) }) else { return false }
            owner = .category(made.id)
        case .newGroup:
            let before = Set(groups.map(\.id))
            guard await change({
                try await $0.createGroup(name: name, icon: draft.icon, color: draft.color, revision: $1, kidsToken: $2)
            }), let made = groups.first(where: { !before.contains($0.id) }) else { return false }
            owner = .group(made.id)
        case .category(let id):
            guard await change({
                try await $0.updateLook(
                    of: .category(id), name: name, icon: draft.icon, color: draft.color, revision: $1, kidsToken: $2)
            }) else { return false }
            if let target = draft.groupID, group(ofCategory: id)?.id != target {
                guard await change({ try await $0.moveCategory(id: id, toGroup: target, revision: $1, kidsToken: $2) }) else {
                    return false
                }
            }
            owner = .category(id)
        case .group(let id, let isMain):
            guard await change({
                try await $0.updateLook(
                    of: .group(id), name: isMain ? nil : name, icon: draft.icon, color: draft.color, revision: $1,
                    kidsToken: $2)
            }) else { return false }
            owner = .group(id)
        }

        switch draft.logo {
        case .keep:
            return true
        case .none:
            return await change { try await $0.removeLogo(of: owner, revision: $1, kidsToken: $2) }
        case .found(let result):
            return await change { try await $0.setLogo(of: owner, path: result.path, revision: $1, kidsToken: $2) }
        case .picture(let png):
            return await change {
                try await $0.uploadLogo(of: owner, picture: png, contentType: "image/png", revision: $1, kidsToken: $2)
            }
        }
    }

    /// nil when the search could not be made; the reason is in `problem`.
    func searchLogos(_ query: String) async -> [LogoSearchResult]? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        do {
            return try await app.asManager { try await $0.searchLogos(query) }
        } catch {
            problem = await app.managerProblem(error)
            return nil
        }
    }

    /// Sends one change, based on the setup on screen. One the server will not make without the
    /// manager's word about kids viewers waits in `question`, with what to send again.
    @discardableResult
    private func change(asked token: String? = nil, _ call: @escaping Change) async -> Bool {
        guard let revision = edit?.revision, !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            edit = try await app.asManager { try await call($0, revision, token) }
            await app.refresh()
            return true
        } catch {
            await failed(error, retry: call)
            return false
        }
    }

    /// A dry run of the change, then the change itself; see `arrangeAskingFirst`. Fails closed:
    /// what the dry run says would let a kids viewer see more is never sent without Allow.
    @discardableResult
    private func askingFirst(_ call: @escaping AskedChange) async -> Bool {
        guard let revision = edit?.revision, !isBusy else { return false }
        let real: Change = { try await call($0, $1, false, $2) }
        isBusy = true
        let tried: CategoriesEdit
        do {
            tried = try await app.asManager { try await call($0, revision, true, nil) }
        } catch {
            isBusy = false
            await failed(error, retry: real)
            return false
        }
        isBusy = false
        guard tried.dryRun else {
            // A server from before dry runs made the change at once (and asked as it does).
            edit = tried
            await app.refresh()
            return true
        }
        if tried.needsConfirmation {
            guard let token = tried.kidsToken else {
                problem = "The server did not say what kids viewers would see, so nothing was changed."
                return false
            }
            question = KidsQuestion(
                message: "This lets kids viewers see more than now.", changes: tried.kidsChanges, token: token, retry: real)
            return false
        }
        return await change(asked: tried.kidsToken, real)
    }

    private func failed(_ error: any Error, retry call: @escaping Change) async {
        switch error {
        case let asking as KidsConfirmationNeeded<CategoriesEdit>:
            edit = asking.current
            question = KidsQuestion(message: asking.message, changes: asking.changes, token: asking.token, retry: call)
        case let conflict as EditConflict<CategoriesEdit>:
            // Theirs stays; the person sees it and decides again.
            edit = conflict.current
            problem = "Someone else changed the categories meanwhile. This is how they are now; try again if you still want your change."
        default:
            problem = await app.managerProblem(error)
        }
    }
}

/// A change that can be tried first: with the client, the revision, whether it is a dry run,
/// and the token of what kids viewers would see.
typealias AskedChange = @MainActor (LobbyClient, Int, Bool, String?) async throws -> CategoriesEdit

/// One change of the categories: with the client, the revision it is based on and, when the
/// manager was asked, the token of what they allowed.
typealias Change = @MainActor (LobbyClient, Int, String?) async throws -> CategoriesEdit

/// A change that waits until the manager allows what kids viewers would see by it.
struct KidsQuestion: Identifiable {
    var message: String
    /// Only the viewers who would see more, and those who see less.
    var changes: [KidsChange]
    var token: String
    var retry: Change

    var id: String { token }

    var appearing: [KidsChange] { changes.filter { $0.appearing.count > 0 } }
}

/// What a manager filled in for a category or group.
struct CategoryDraft: Hashable, Sendable, Identifiable {
    enum Subject: Hashable, Sendable {
        case newCategory(groupID: String)
        case newGroup
        case category(String)
        case group(String, isMain: Bool)
    }

    enum Logo: Hashable, Sendable {
        case keep
        case none
        case found(LogoSearchResult)
        /// A PNG the person chose.
        case picture(Data)
    }

    var subject: Subject
    var name = ""
    var icon: String?
    var color: String?
    /// The group a category is in.
    var groupID: String?
    /// A new category inside this one.
    var parentID: String?
    /// What it has now.
    var currentLogo: CategoryLogo?
    var logo = Logo.keep

    var id: Subject { subject }

    init(newCategoryIn group: CategoryGroup, inside parent: String? = nil) {
        subject = .newCategory(groupID: group.id)
        groupID = group.id
        parentID = parent
    }

    init(newGroup: Void) {
        subject = .newGroup
    }

    init(_ category: LibraryCategory, in group: CategoryGroup) {
        subject = .category(category.id)
        name = category.name
        icon = category.icon
        color = category.color
        groupID = group.id
        currentLogo = category.logo
    }

    init(_ group: CategoryGroup) {
        subject = .group(group.id, isMain: group.name == nil)
        name = group.name ?? ""
        icon = group.icon
        color = group.color
        currentLogo = group.logo
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The main part of the library has no name to change.
    var hasName: Bool {
        if case .group(_, isMain: true) = subject { return false }
        return true
    }

    var canSave: Bool { !hasName || (1...60).contains(trimmedName.count) }

    var title: String {
        switch subject {
        case .newCategory: "New Category"
        case .newGroup: "New Group"
        case .category: "Category"
        case .group: "Group"
        }
    }

    var isGroup: Bool {
        switch subject {
        case .newGroup, .group: true
        case .newCategory, .category: false
        }
    }
}
