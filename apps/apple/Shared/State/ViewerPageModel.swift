// SPDX-License-Identifier: MPL-2.0
import Foundation
import LobbyKit
import Observation

/// One viewer's page for a manager: whether it is a kids viewer, and what that viewer may
/// watch. Each change is sent at once; what is on screen goes back when it is refused.
@MainActor
@Observable
final class ViewerPageModel {
    /// What is said about a single title, beside its categories.
    enum Rule: String, CaseIterable, Hashable, Sendable {
        case byCategory, allowed, blocked
    }

    let profileID: String
    private(set) var kids: KidsSettings?
    private(set) var isSaving = false
    var problem: String?
    private let app: AppModel
    private var savedKids: KidsSettings?

    init(app: AppModel, profileID: String) {
        self.app = app
        self.profileID = profileID
        load()
    }

    var profile: Profile? { app.profiles.first { $0.id == profileID } }

    /// The manager watches as this viewer here: making it a kids viewer would close this page
    /// and everything else on it.
    var isWatchingHere: Bool { app.activeProfile?.id == profileID }

    /// The household's groups, with what each is called.
    var groups: [CategoryGroup] { app.categoryGroups.groups }

    /// Takes over what the server says, unless a change is on its way.
    func load() {
        guard !isSaving else { return }
        kids = profile?.kids
        savedKids = kids
    }

    // MARK: Changes

    func setIsKids(_ isKids: Bool) async {
        guard !isWatchingHere, isKids != (kids != nil) else { return }
        // A new kids viewer begins with the household's kids part, when there is one.
        await save(isKids ? KidsSetup.defaultLimits(for: app.categoryGroups) : nil)
    }

    func allows(group id: String) -> Bool { kids?.allowedGroupIds.contains(id) == true }

    func setAllows(_ allows: Bool, group id: String) async {
        await change { $0.allowedGroupIds.set(id, allows) }
    }

    func allows(category id: String) -> Bool { kids?.allowedCategoryIds.contains(id) == true }

    func setAllows(_ allows: Bool, category id: String) async {
        await change { $0.allowedCategoryIds.set(id, allows) }
    }

    /// What is said about one category. Ids of categories this app does not know stay in the
    /// lists and are sent back as they are.
    enum CategoryChoice: String, CaseIterable, Hashable, Sendable {
        /// Nothing of its own: as its group or the category it is inside of says.
        case asAbove, allowed, blocked
    }

    func choice(forCategory id: String) -> CategoryChoice {
        if kids?.blockedCategoryIds.contains(id) == true { return .blocked }
        return allows(category: id) ? .allowed : .asAbove
    }

    func set(_ choice: CategoryChoice, category id: String) async {
        await change {
            $0.allowedCategoryIds.set(id, choice == .allowed)
            $0.blockedCategoryIds.set(id, choice == .blocked)
        }
    }

    /// What a category without a choice of its own comes to, in words: "Allowed with Kids".
    func inherited(category id: String, in group: CategoryGroup) -> String {
        let parent = app.categoryGroups.parent(of: id)
        if let parent, choice(forCategory: parent.id) == .blocked { return "Blocked with \(parent.name)" }
        if let parent, allows(category: parent.id) { return "Allowed with \(parent.name)" }
        if allows(group: group.id) { return "Allowed with all of \(group.name ?? "the library")" }
        return "Not allowed"
    }

    /// Whether the server knows category blocks: one from before does not.
    var offersBlockingCategories: Bool { app.categoryGroups.categories.contains { $0.parentId != nil } || kids?.knowsBlockedCategories == true }

    func rule(for itemID: String) -> Rule {
        if kids?.blockedItemIds.contains(itemID) == true { return .blocked }
        return kids?.allowedItemIds.contains(itemID) == true ? .allowed : .byCategory
    }

    func set(_ rule: Rule, for itemID: String) async {
        await change {
            $0.allowedItemIds.set(itemID, rule == .allowed)
            $0.blockedItemIds.set(itemID, rule == .blocked)
        }
    }

    private func change(_ edit: (inout KidsSettings) -> Void) async {
        guard var kids else { return }
        edit(&kids)
        await save(kids)
    }

    private func save(_ wanted: KidsSettings?) async {
        kids = wanted
        // One at a time, the newest last: the one under way sends what came meanwhile.
        guard !isSaving else { return }
        isSaving = true
        problem = nil
        while kids != savedKids {
            let sending = kids
            do {
                try await app.setKids(sending, profileID: profileID)
                savedKids = sending
            } catch {
                kids = savedKids
                problem = await app.managerProblem(error)
                break
            }
        }
        isSaving = false
    }

    // MARK: Titles

    struct TitleRow: Hashable, Identifiable {
        var item: Item
        var rule: Rule
        /// In words: whether the viewer sees it, and why.
        var caption: String
        var id: String { item.id }
    }

    /// The titles that match what is typed, or (nothing typed) the ones with a rule of their own.
    func titles(_ query: String) -> [TitleRow] {
        guard let kids else { return [] }
        let filter = KidsFilter(kids, groups: app.categoryGroups)
        let typed = query.trimmingCharacters(in: .whitespaces)
        let found: [Item]
        if typed.isEmpty {
            found = (kids.allowedItemIds + kids.blockedItemIds).compactMap { app.wholeCatalogue.item($0) }
                .sorted { $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending }
        } else {
            found = Shelves.search(typed, in: app.wholeCatalogue)
        }
        return found.map { item in
            let rule = rule(for: item.id)
            let caption = switch rule {
            case .allowed: "Always allowed"
            case .blocked: "Blocked"
            case .byCategory:
                filter.allowsCategories(of: item, in: app.wholeCatalogue) ? "Allowed by its category" : "Not allowed"
            }
            return TitleRow(item: item, rule: rule, caption: caption)
        }
    }

    /// How much there is to watch now.
    var summary: String {
        guard let kids else { return "" }
        let left = app.wholeCatalogue.limited(to: kids, groups: app.categoryGroups)
        let films = left.items(ofKind: .movie).count + left.items(ofKind: .personal).count
        let series = left.items(ofKind: .show).count
        if films + series == 0 { return "Nothing is allowed yet, so there is nothing to watch." }
        return "\(films == 1 ? "1 film" : "\(films) films") and \(series == 1 ? "1 series" : "\(series) series") to watch."
    }
}

extension [String] {
    fileprivate mutating func set(_ id: String, _ isIn: Bool) {
        removeAll { $0 == id }
        if isIn { append(id) }
    }
}
