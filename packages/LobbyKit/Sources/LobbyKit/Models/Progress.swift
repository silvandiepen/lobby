// SPDX-License-Identifier: MPL-2.0
import Foundation

/// `Progress` in `docs/api.md`. Named apart from Foundation's `Progress`, which every app file imports.
public struct PlaybackProgress: Codable, Hashable, Sendable {
    public var itemId: String
    public var positionMs: Int
    public var durationMs: Int?
    /// True once the viewer finished it. Continue Watching leaves it out.
    public var completed: Bool
    /// Increases with every accepted change on the server. 0 for a change the server has not
    /// accepted yet.
    public var revision: Int
    /// When the viewer did it, by their device's clock.
    public var updatedAt: Date

    public init(
        itemId: String, positionMs: Int, durationMs: Int?, completed: Bool, revision: Int, updatedAt: Date
    ) {
        self.itemId = itemId
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.completed = completed
        self.revision = revision
        self.updatedAt = updatedAt
    }

    /// Started and not finished: what Continue Watching resumes.
    public var isInProgress: Bool { !completed && positionMs > 0 }
}

/// `GET /v1/profiles/{profileId}/progress`.
public struct ProgressList: Codable, Hashable, Sendable {
    public var progress: [PlaybackProgress]
    /// Pass as `since` next time.
    public var revision: Int
}

/// The body of `PUT /v1/profiles/{profileId}/progress/{itemId}`.
public struct ProgressUpdate: Codable, Hashable, Sendable {
    /// A fresh UUID per change, reused on every retry of that change.
    public var opId: String
    /// The revision of the progress the device last saw for this item, or nil if it never saw one.
    public var baseRevision: Int?
    public var positionMs: Int
    public var durationMs: Int?
    public var completed: Bool
    public var updatedAt: Date

    public init(
        opId: String, baseRevision: Int?, positionMs: Int, durationMs: Int?, completed: Bool, updatedAt: Date
    ) {
        self.opId = opId
        self.baseRevision = baseRevision
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.completed = completed
        self.updatedAt = updatedAt
    }

    // The API never omits a field: a missing value is written as null.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(opId, forKey: .opId)
        try container.encode(baseRevision, forKey: .baseRevision)
        try container.encode(positionMs, forKey: .positionMs)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(completed, forKey: .completed)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
