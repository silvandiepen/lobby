// SPDX-License-Identifier: MPL-2.0
/// The order of a show's seasons and episodes, and which episode comes next.
///
/// Episodes run by season, then by episode number. An episode without a number comes after the
/// numbered ones of its season, and a season without a number after the numbered seasons.
/// Specials (season 0) are a chain of their own: the episode after the last one of season 1 is
/// the first of season 2, never a special, and a special is followed only by the next special.
public enum EpisodeOrder {
    /// A show's seasons: 1, 2, 3 …, then Specials, then seasons without a number.
    public static func seasons(ofShow showID: String, in catalogue: Catalogue) -> [Item] {
        catalogue.children(of: showID)
            .filter { $0.kind == .season }
            .sorted { seasonRank($0.seasonNumber, $0) < seasonRank($1.seasonNumber, $1) }
    }

    /// The episodes of one season, in order.
    public static func episodes(ofSeason seasonID: String, in catalogue: Catalogue) -> [Item] {
        catalogue.children(of: seasonID)
            .filter { $0.kind == .episode }
            .sorted { episodeRank($0, in: catalogue) < episodeRank($1, in: catalogue) }
    }

    /// The show's episodes in watch order, without Specials.
    public static func episodes(ofShow showID: String, in catalogue: Catalogue) -> [Item] {
        allEpisodes(ofShow: showID, in: catalogue).filter { seasonNumber(of: $0, in: catalogue) != 0 }
    }

    /// The show's Specials (season 0), in order.
    public static func specials(ofShow showID: String, in catalogue: Catalogue) -> [Item] {
        allEpisodes(ofShow: showID, in: catalogue).filter { seasonNumber(of: $0, in: catalogue) == 0 }
    }

    /// The episode Play Next offers after `episode`, or nil after the last one.
    public static func nextEpisode(after episode: Item, in catalogue: Catalogue) -> Item? {
        let chain = chain(containing: episode, in: catalogue)
        guard let index = chain.firstIndex(where: { $0.id == episode.id }) else { return nil }
        return chain.dropFirst(index + 1).first
    }

    /// The episodes `episode` is ordered among: the show's Specials for a special, its regular
    /// episodes otherwise. Empty when the episode has no show.
    static func chain(containing episode: Item, in catalogue: Catalogue) -> [Item] {
        guard episode.kind == .episode, let show = catalogue.show(of: episode) else { return [] }
        return seasonNumber(of: episode, in: catalogue) == 0
            ? specials(ofShow: show.id, in: catalogue)
            : episodes(ofShow: show.id, in: catalogue)
    }

    /// An episode's season number: its own, or its season's.
    static func seasonNumber(of episode: Item, in catalogue: Catalogue) -> Int? {
        episode.seasonNumber ?? catalogue.parent(of: episode).flatMap { $0.kind == .season ? $0.seasonNumber : nil }
    }

    private static func allEpisodes(ofShow showID: String, in catalogue: Catalogue) -> [Item] {
        catalogue.descendants(of: showID)
            .filter { $0.kind == .episode }
            .sorted { episodeRank($0, in: catalogue) < episodeRank($1, in: catalogue) }
    }

    private struct Rank: Comparable {
        var keys: [Int]
        var sortTitle: String
        var id: String

        static func < (a: Rank, b: Rank) -> Bool {
            if a.keys != b.keys { return a.keys.lexicographicallyPrecedes(b.keys) }
            if a.sortTitle != b.sortTitle { return a.sortTitle < b.sortTitle }
            return a.id < b.id
        }
    }

    /// Numbered seasons first, then Specials, then unnumbered ones.
    private static func seasonRank(_ number: Int?, _ item: Item) -> Rank {
        let keys: [Int] =
            switch number {
            case .some(0): [1, 0]
            case .some(let number): [0, number]
            case .none: [2, 0]
            }
        return Rank(keys: keys, sortTitle: item.sortTitle, id: item.id)
    }

    private static func episodeRank(_ episode: Item, in catalogue: Catalogue) -> Rank {
        let season = seasonNumber(of: episode, in: catalogue)
        let keys = [
            season == nil ? 1 : 0, season ?? 0,
            episode.episodeNumber == nil ? 1 : 0, episode.episodeNumber ?? 0,
        ]
        return Rank(keys: keys, sortTitle: episode.sortTitle, id: episode.id)
    }
}
