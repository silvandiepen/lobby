// SPDX-License-Identifier: MPL-2.0
import CoreGraphics
import Foundation
import LobbyKit
import Observation

/// Editing one title. Words and categories are filled in and saved together; a picture or a
/// match is chosen and takes effect at once. Every change names the state it is based on, so
/// two managers do not overwrite each other.
@MainActor
@Observable
final class ItemEditModel {
    typealias Field = ItemChanges.Field

    let itemID: String
    private(set) var edit: ItemEdit?
    private(set) var isBusy = false
    /// The title left the library.
    private(set) var isGone = false
    var problem: String?

    // What is filled in.
    var title = ""
    var sortTitle = ""
    var year = ""
    var overview = ""
    /// Separated by commas.
    var genres = ""
    var categoryIDs: Set<String> = []
    /// Fields the person put back to what Lobby finds by itself.
    private(set) var putBack: Set<Field> = []

    private let app: AppModel

    init(app: AppModel, itemID: String) {
        self.app = app
        self.itemID = itemID
    }

    func load() async {
        guard edit == nil else { return }
        do {
            let id = itemID
            let loaded = try await app.asManager { try await $0.itemEdit(id: id) }
            edit = loaded
            for field in Field.allCases { fill(field, from: loaded, automatic: false) }
        } catch LobbyError.notFound {
            isGone = true
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    // MARK: Fields

    func has(_ field: Field) -> Bool {
        guard let fields = edit?.fields else { return false }
        return switch field {
        case .title: fields.title != nil
        case .sortTitle: fields.sortTitle != nil
        case .year: fields.year != nil
        case .overview: fields.overview != nil
        case .genres: fields.genres != nil
        case .categories: edit?.categories.isEmpty == false
        }
    }

    /// A manager changed it, now or before: it can be put back.
    func canPutBack(_ field: Field) -> Bool {
        guard let edit, has(field) else { return false }
        if putBack.contains(field), shows(field, of: edit, automatic: true) { return false }
        return isOverridden(field, in: edit) || isChanged(field)
    }

    /// Shows what Lobby finds by itself. Saved with the rest.
    func putBack(_ field: Field) {
        guard let edit else { return }
        putBack.insert(field)
        fill(field, from: edit, automatic: true)
    }

    /// The number typed is one the server takes. Empty: no year.
    var yearIsValid: Bool {
        let typed = year.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty || Int(typed).map { (1850...2200).contains($0) } == true
    }

    var canSave: Bool {
        guard edit != nil, !isBusy else { return false }
        let hasWords = !trimmed(title).isEmpty && (!has(.sortTitle) || !trimmed(sortTitle).isEmpty)
        return hasWords && yearIsValid && (!has(.categories) || !categoryIDs.isEmpty)
    }

    /// Only what differs from what the server has.
    var changes: ItemChanges {
        guard let edit else { return ItemChanges() }
        var changes = ItemChanges()
        for field in Field.allCases where has(field) {
            if putBack.contains(field), shows(field, of: edit, automatic: true) {
                if isOverridden(field, in: edit) { changes.reset.insert(field) }
                continue
            }
            guard isChanged(field) else { continue }
            switch field {
            case .title: changes.title = trimmed(title)
            case .sortTitle: changes.sortTitle = trimmed(sortTitle)
            case .year: changes.year = .some(Int(trimmed(year)))
            case .overview: changes.overview = .some(trimmed(overview).isEmpty ? nil : trimmed(overview))
            case .genres: changes.genres = Self.list(genres)
            case .categories: changes.categoryIds = edit.categories.map(\.id).filter(categoryIDs.contains)
            }
        }
        return changes
    }

    /// - Returns: whether everything is saved. When not, what was filled in stays.
    func save() async -> Bool {
        let changes = changes
        guard !changes.isEmpty else { return true }
        let id = itemID
        let done = await change { try await $0.updateItem(id: id, changes: changes, revision: $1) }
        if done { putBack = [] }
        return done
    }

    // MARK: Pictures

    func artworkOptions(for kind: ArtworkKind) async -> ArtworkOptions? {
        let id = itemID
        do {
            return try await app.asManager { try await $0.artworkOptions(itemID: id, kind: kind) }
        } catch {
            problem = await app.managerProblem(error)
            return nil
        }
    }

    @discardableResult
    func choose(_ option: ArtworkOption, for kind: ArtworkKind) async -> Bool {
        let id = itemID
        return await change { try await $0.chooseArtwork(itemID: id, kind: kind, option: option, revision: $1) }
    }

    @discardableResult
    func chooseFrame(atMs position: Int, for kind: ArtworkKind) async -> Bool {
        let id = itemID
        return await change { try await $0.chooseFrame(itemID: id, kind: kind, positionMs: position, revision: $1) }
    }

    /// A picture from this device, sent as a JPEG whatever it was; a logo as a PNG, which keeps
    /// its transparency.
    @discardableResult
    func upload(_ picture: Data?, for kind: ArtworkKind) async -> Bool {
        guard let encoded = picture.flatMap({ kind == .logo ? PictureEncoder.png(from: $0) : PictureEncoder.jpeg(from: $0) }) else {
            problem = "That picture could not be read."
            return false
        }
        let id = itemID
        return await change { try await $0.uploadArtwork(itemID: id, kind: kind, picture: encoded, revision: $1) }
    }

    /// The title is written, also when Lobby finds a logo.
    @discardableResult
    func chooseNoLogo() async -> Bool {
        let id = itemID
        return await change { try await $0.chooseNoLogo(itemID: id, revision: $1) }
    }

    @discardableResult
    func putBackArtwork(_ kind: ArtworkKind) async -> Bool {
        let id = itemID
        return await change { try await $0.resetArtwork(itemID: id, kind: kind, revision: $1) }
    }

    func hasChosenArtwork(_ kind: ArtworkKind) -> Bool {
        if kind == .logo, edit?.withoutLogo == true { return true }
        return edit?.options(for: kind).contains { $0.selected && $0.chosen } == true
    }

    /// How long the film is that a frame can be taken from: its own, or a show's first
    /// episode's. nil when there is none.
    var frameDurationMs: Int? {
        guard let item = app.wholeCatalogue.item(itemID) else { return nil }
        switch item.kind {
        case .show: return EpisodeOrder.episodes(ofShow: item.id, in: app.wholeCatalogue).first?.displayDurationMs
        case .season: return nil
        default: return item.displayDurationMs
        }
    }

    // MARK: Match

    func searchMatch(_ query: String, year: String) async -> [MatchResult]? {
        let id = itemID, query = trimmed(query), year = Int(trimmed(year))
        guard !query.isEmpty else { return [] }
        do {
            return try await app.asManager { try await $0.searchMatch(itemID: id, query: query, year: year) }
        } catch {
            problem = await app.managerProblem(error)
            return nil
        }
    }

    @discardableResult
    func setMatch(_ tmdb: TMDBReference) async -> Bool {
        let id = itemID
        return await change { try await $0.setMatch(itemID: id, to: tmdb, revision: $1) }
    }

    @discardableResult
    func removeMatch() async -> Bool {
        let id = itemID
        return await change { try await $0.removeMatch(itemID: id, revision: $1) }
    }

    @discardableResult
    func automaticMatch() async -> Bool {
        let id = itemID
        return await change { try await $0.automaticMatch(itemID: id, revision: $1) }
    }

    /// The match in a sentence.
    var matchText: String {
        guard let match = edit?.match else { return "" }
        if match.chosen { return match.tmdb == nil ? "A manager said there is no match." : "Chosen by a manager." }
        switch match.status {
        case .matched: return "Found by Lobby."
        case .needsReview: return match.reason ?? "Lobby is not sure."
        case .unmatched: return match.reason ?? "Not found yet."
        default: return match.reason ?? ""
        }
    }

    // MARK: Putting it together

    private func change(_ call: (LobbyClient, Int) async throws -> ItemEdit) async -> Bool {
        guard let revision = edit?.revision, !isBusy else { return false }
        isBusy = true
        problem = nil
        defer { isBusy = false }
        do {
            take(try await app.asManager { try await call($0, revision) })
            await app.refresh()
            return true
        } catch let conflict as EditConflict<ItemEdit> {
            take(conflict.current)
            problem = "Someone else changed this meanwhile. What you did not touch shows their change; save again if you still want yours."
            return false
        } catch LobbyError.notFound(let message) {
            problem = message
            return false
        } catch {
            problem = await app.managerProblem(error)
            return false
        }
    }

    /// The newer state: what the person did not touch follows it, what they filled in stays.
    private func take(_ newer: ItemEdit) {
        guard let older = edit else { return }
        let untouched = Field.allCases.filter { !putBack.contains($0) && shows($0, of: older, automatic: false) }
        edit = newer
        for field in untouched { fill(field, from: newer, automatic: false) }
    }

    private func isChanged(_ field: Field) -> Bool {
        guard let edit else { return false }
        return !shows(field, of: edit, automatic: false)
    }

    private func isOverridden(_ field: Field, in edit: ItemEdit) -> Bool {
        switch field {
        case .title: edit.fields.title?.overridden == true
        case .sortTitle: edit.fields.sortTitle?.overridden == true
        case .year: edit.fields.year?.overridden == true
        case .overview: edit.fields.overview?.overridden == true
        case .genres: edit.fields.genres?.overridden == true
        case .categories: edit.categoryIds.overridden
        }
    }

    private static func value<Value>(_ field: ItemEdit.Field<Value>?, automatic: Bool) -> Value? {
        automatic ? field?.automatic : field?.effective
    }

    /// Whether what is filled in is what `edit` has.
    private func shows(_ field: Field, of edit: ItemEdit, automatic: Bool) -> Bool {
        switch field {
        case .title: trimmed(title) == Self.value(edit.fields.title, automatic: automatic) ?? ""
        case .sortTitle: trimmed(sortTitle) == Self.value(edit.fields.sortTitle, automatic: automatic) ?? ""
        case .year: trimmed(year) == Self.value(edit.fields.year, automatic: automatic).map(String.init) ?? ""
        case .overview: trimmed(overview) == trimmed(Self.value(edit.fields.overview, automatic: automatic) ?? "")
        case .genres: Self.list(genres) == Self.value(edit.fields.genres, automatic: automatic) ?? []
        case .categories: categoryIDs == Set(automatic ? edit.categoryIds.automatic : edit.categoryIds.effective)
        }
    }

    private func fill(_ field: Field, from edit: ItemEdit, automatic: Bool) {
        switch field {
        case .title: title = Self.value(edit.fields.title, automatic: automatic) ?? ""
        case .sortTitle: sortTitle = Self.value(edit.fields.sortTitle, automatic: automatic) ?? ""
        case .year: year = Self.value(edit.fields.year, automatic: automatic).map(String.init) ?? ""
        case .overview: overview = Self.value(edit.fields.overview, automatic: automatic) ?? ""
        case .genres: genres = (Self.value(edit.fields.genres, automatic: automatic) ?? []).joined(separator: ", ")
        case .categories: categoryIDs = Set(automatic ? edit.categoryIds.automatic : edit.categoryIds.effective)
        }
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
