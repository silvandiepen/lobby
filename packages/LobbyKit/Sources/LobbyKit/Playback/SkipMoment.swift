// SPDX-License-Identifier: MPL-2.0
/// What the player offers at a moment of a film, from its markers and the viewer's preferences
/// (docs/decisions.md, "Skip Intro"): Skip Intro while the intro plays, Next Episode from where the credits start.
///
/// Times are of the file, as the markers are. The same answer on every platform, and on a phone
/// that controls another device's player.
public enum SkipMoment: Hashable, Sendable {
    case none
    /// In the intro: Skip Intro goes to `endMs`. `automatic` when the viewer wants it skipped.
    case intro(endMs: Int, automatic: Bool)
    /// In the credits, from `startMs` on.
    case credits(startMs: Int)

    /// The last seconds of an intro are not worth a button.
    public static let introTailMs = 2_000

    public static func at(
        fileMs: Int, markers: PlaybackMarkers?, preferences: SkipPreferences
    ) -> SkipMoment {
        if let intro = markers?.intro, preferences.intro != .off, intro.endMs > intro.startMs,
            fileMs >= intro.startMs, fileMs < intro.endMs - introTailMs
        {
            return .intro(endMs: intro.endMs, automatic: preferences.intro == .skip)
        }
        if let credits = markers?.credits, preferences.credits == .show, fileMs >= credits.startMs {
            return .credits(startMs: credits.startMs)
        }
        return .none
    }

    /// Where the credits start, for a countdown to the next episode; nil when the viewer does not
    /// want it or it is not known.
    public static func creditsStartMs(markers: PlaybackMarkers?, preferences: SkipPreferences) -> Int? {
        guard preferences.credits == .show else { return nil }
        return markers?.credits?.startMs
    }

    /// For a device that controls another one's player: where its Skip Intro goes, when it
    /// shows. When the viewer wants intros skipped, the player does that itself; the button
    /// shows only once that should have happened, for a viewer who went back into the intro.
    public static func remoteIntroEnd(
        fileMs: Int, markers: PlaybackMarkers?, preferences: SkipPreferences
    ) -> Int? {
        guard case .intro(let end, let automatic) = at(fileMs: fileMs, markers: markers, preferences: preferences),
            let start = markers?.intro?.startMs
        else { return nil }
        if automatic, fileMs < start + remoteGraceMs { return nil }
        return end
    }

    /// How long the controlling device leaves the player to skip by itself.
    public static let remoteGraceMs = 3_000

    public var isIntro: Bool {
        if case .intro = self { return true }
        return false
    }

    public var isCredits: Bool {
        if case .credits = self { return true }
        return false
    }
}

/// Skips an intro by itself once per film: when the viewer goes back into it afterwards, they
/// want to see it, and get the button instead.
public struct IntroAutoSkip: Hashable, Sendable {
    private var skipped = false

    public init() {}

    /// Where to jump to now, if anywhere.
    public mutating func target(for moment: SkipMoment) -> Int? {
        guard case .intro(let end, let automatic) = moment, automatic, !skipped else { return nil }
        skipped = true
        return end
    }

    /// Whether the button shows for this moment: not while the intro is about to be skipped.
    public func showsButton(for moment: SkipMoment) -> Bool {
        guard case .intro(_, let automatic) = moment else { return false }
        return !automatic || skipped
    }
}
