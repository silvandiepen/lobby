// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A picture a viewer can have. The pictures are in `Avatars.xcassets` by id; the server keeps
/// only the id.
struct Avatar: Hashable, Identifiable, Sendable {
    enum Group: Hashable, Sendable, CaseIterable, Identifiable {
        case characters, animals

        var id: Self { self }

        var name: String {
            switch self {
            case .characters: String(localized: "Characters")
            case .animals: String(localized: "Animals")
            }
        }

        var avatars: [Avatar] {
            switch self {
            case .characters: Avatar.characters
            case .animals: Avatar.animals
            }
        }
    }

    let id: String
    private let title: LocalizedStringResource

    /// What it shows, in words.
    var name: String { String(localized: title) }

    /// Its picture in the asset catalogue.
    var assetName: String { "Avatar/\(id)" }

    static func == (one: Avatar, other: Avatar) -> Bool { one.id == other.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The avatar a viewer has. nil: none, or one only a newer app has a picture for.
    init?(id: String?) {
        guard let id, let known = Self.byID[id] else { return nil }
        self = known
    }

    private init(_ id: String, _ title: LocalizedStringResource) {
        self.id = id
        self.title = title
    }

    static let characters: [Avatar] = [
        Avatar("viking-man", "Viking man"),
        Avatar("viking-woman", "Viking woman"),
        Avatar("princess", "Princess"),
        Avatar("prince", "Prince"),
        Avatar("knight", "Knight"),
        Avatar("pirate", "Pirate"),
        Avatar("wizard", "Wizard"),
        Avatar("fairy", "Fairy"),
        Avatar("mermaid", "Mermaid"),
        Avatar("superhero", "Superhero"),
        Avatar("ninja", "Ninja"),
        Avatar("astronaut", "Astronaut"),
        Avatar("robot", "Robot"),
        Avatar("explorer", "Explorer"),
        Avatar("desert-queen", "Desert queen"),
        Avatar("chef", "Chef"),
    ]

    static let animals: [Avatar] = [
        Avatar("panda", "Panda"),
        Avatar("lion", "Lion"),
        Avatar("tiger", "Tiger"),
        Avatar("fox", "Fox"),
        Avatar("dog", "Dog"),
        Avatar("cat", "Cat"),
        Avatar("rabbit", "Rabbit"),
        Avatar("bear", "Bear"),
        Avatar("elephant", "Elephant"),
        Avatar("penguin", "Penguin"),
        Avatar("owl", "Owl"),
        Avatar("frog", "Frog"),
        Avatar("octopus", "Octopus"),
        Avatar("triceratops", "Triceratops"),
        Avatar("dragon", "Dragon"),
        Avatar("unicorn", "Unicorn"),
    ]

    private static let byID = Dictionary(
        uniqueKeysWithValues: (characters + animals).map { ($0.id, $0) })
}

/// Moving through the pictures with the arrow keys: "No picture" on top, then each group in
/// rows of its own.
enum AvatarKeys {
    enum Step: Sendable { case up, down, left, right }

    /// - Parameter columns: How many pictures stand beside each other.
    /// - Returns: The id to go to; nil for "No picture".
    static func step(_ step: Step, from id: String?, columns: Int) -> String? {
        let columns = max(1, columns)
        let groups: [[String?]] = [[nil]] + Avatar.Group.allCases.map { $0.avatars.map(\.id) }
        let rows = groups.flatMap { group in
            stride(from: 0, to: group.count, by: columns).map { Array(group[$0..<min($0 + columns, group.count)]) }
        }
        let all = rows.flatMap(\.self)
        guard let row = rows.firstIndex(where: { $0.contains(id) }), let column = rows[row].firstIndex(of: id),
            let index = all.firstIndex(of: id)
        else { return nil }
        switch step {
        case .left: return all[max(0, index - 1)]
        case .right: return all[min(all.count - 1, index + 1)]
        case .up: return row == 0 ? id : rows[row - 1][min(column, rows[row - 1].count - 1)]
        case .down: return row == rows.count - 1 ? id : rows[row + 1][min(column, rows[row + 1].count - 1)]
        }
    }
}

/// The server does not know avatars.
struct AvatarsUnsupported: LocalizedError {
    var errorDescription: String? {
        String(localized: "This Lobby Server does not know pictures yet. Update it first.")
    }
}
