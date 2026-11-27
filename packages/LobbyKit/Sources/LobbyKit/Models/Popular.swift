// SPDX-License-Identifier: MPL-2.0
/// What the household watched lately: `GET /v1/popular`. Only counts of all viewers together.
public struct Popular: Codable, Hashable, Sendable {
    public struct Title: Codable, Hashable, Sendable {
        /// A film, home video or show.
        public var itemId: String
        /// One viewer and one title on one day is one play.
        public var plays: Int

        public init(itemId: String, plays: Int) {
            self.itemId = itemId
            self.plays = plays
        }
    }

    /// Most plays first. Only titles with a play.
    public var titles: [Title]

    public init(titles: [Title] = []) {
        self.titles = titles
    }

    /// An older server, or nothing watched yet.
    public static let none = Popular()
}
