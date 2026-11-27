// SPDX-License-Identifier: MPL-2.0
/// A viewer: one person's progress and Continue Watching.
public struct Profile: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// A colour name from the app's palette ("red", "orange", "yellow", "green", "teal", "blue",
    /// "purple", "pink"). Kept as a string: the palette belongs to the app.
    public var color: String
    /// What a kids viewer may watch. nil: not a kids viewer, or the server did not say
    /// (`saysKids`).
    public var kids: KidsSettings?
    /// Whether the server said anything about kids at all. A server from before kids viewers
    /// leaves the field out, which must not be read as "not a kids viewer any more".
    public private(set) var saysKids: Bool
    /// The id of a picture the app carries ("viking-man"). nil: the letter, or the server did
    /// not say (`saysAvatar`). It may be one that only a newer app has.
    public var avatar: String?
    /// Whether the server said anything about avatars at all: one from before them leaves the
    /// field out, which must not be read as "no picture any more".
    public private(set) var saysAvatar: Bool
    /// How this viewer wants subtitles. nil: the server did not say (one from before them);
    /// `subtitlePreferences` gives the defaults then.
    public var subtitles: SubtitlePreferences?

    /// What happens when something ends, for this viewer. nil: the server did not say (one
    /// from before them); `playbackPreferences` gives the defaults then.
    public var playback: PlaybackPreferences?

    /// What the player goes by: the viewer's own, or off with forced subtitles on.
    public var subtitlePreferences: SubtitlePreferences { subtitles ?? .defaults }
    /// What this viewer wants at intros and credits. nil: the server did not say.
    public var skipping: SkipPreferences?

    /// What the player goes by: the viewer's own, or the buttons.
    public var skipPreferences: SkipPreferences { skipping ?? .defaults }

    /// What the player does at the end: the viewer's own, or the defaults of their kind.
    public var playbackPreferences: PlaybackPreferences { playback ?? (kids != nil ? .kidsDefaults : .defaults) }

    /// - Parameters:
    ///   - saysKids: nil: only when there are kids settings.
    ///   - saysAvatar: nil: only when there is an avatar.
    public init(
        id: String, name: String, color: String, avatar: String? = nil, saysAvatar: Bool? = nil,
        kids: KidsSettings? = nil, saysKids: Bool? = nil, subtitles: SubtitlePreferences? = nil,
        playback: PlaybackPreferences? = nil, skipping: SkipPreferences? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.avatar = avatar
        self.saysAvatar = saysAvatar ?? (avatar != nil)
        self.kids = kids
        self.saysKids = saysKids ?? (kids != nil)
        self.subtitles = subtitles
        self.playback = playback
        self.skipping = skipping
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, avatar, kids, subtitles, playback, skipping
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decode(String.self, forKey: .color)
        saysAvatar = container.contains(.avatar)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        saysKids = container.contains(.kids)
        kids = try container.decodeIfPresent(KidsSettings.self, forKey: .kids)
        // One that cannot be read is as good as none said: the defaults, not a broken viewer.
        subtitles = try? container.decodeIfPresent(SubtitlePreferences.self, forKey: .subtitles)
        playback = try? container.decodeIfPresent(PlaybackPreferences.self, forKey: .playback)
        skipping = try? container.decodeIfPresent(SkipPreferences.self, forKey: .skipping)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(color, forKey: .color)
        if saysAvatar { try container.encode(avatar, forKey: .avatar) }
        // An explicit null: "not a kids viewer" is an answer too.
        if saysKids { try container.encode(kids, forKey: .kids) }
        try container.encodeIfPresent(subtitles, forKey: .subtitles)
        try container.encodeIfPresent(playback, forKey: .playback)
        try container.encodeIfPresent(skipping, forKey: .skipping)
    }

    /// The same viewer with what was known before of what this answer left out.
    public func keepingUnsaid(of known: Profile?) -> Profile {
        guard let known, known.id == id else { return self }
        var kept = self
        if !saysKids, known.saysKids {
            kept.kids = known.kids
            kept.saysKids = true
        }
        if !saysAvatar, known.saysAvatar {
            kept.avatar = known.avatar
            kept.saysAvatar = true
        }
        if subtitles == nil { kept.subtitles = known.subtitles }
        if playback == nil { kept.playback = known.playback }
        if skipping == nil { kept.skipping = known.skipping }
        return kept
    }
}

/// How a viewer wants subtitles (`docs/api.md`, Profiles). The player chooses the tracks from
/// this when a film starts; its menu still lets the viewer pick another for that time.
public struct SubtitlePreferences: Codable, Hashable, Sendable {
    public enum Size: String, Codable, Hashable, Sendable, CaseIterable {
        case small, medium, large
    }

    /// Language codes ("nl", "eng") in order of preference. Empty: subtitles off.
    public var languages: [String]
    /// Forced subtitles: the lines for speech in another language, when a film has them.
    public var forced: Bool
    public var size: Size
    /// A dark box behind the lines.
    public var background: Bool

    /// Off, forced subtitles on: every viewer's, kids viewers' too, until they choose.
    public static let defaults = SubtitlePreferences(languages: [], forced: true, size: .medium, background: true)

    public init(languages: [String], forced: Bool, size: Size, background: Bool) {
        self.languages = languages
        self.forced = forced
        self.size = size
        self.background = background
    }

    public var isOff: Bool { languages.isEmpty }

    private enum CodingKeys: String, CodingKey { case languages, forced, size, background }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        languages = try container.decodeIfPresent([String].self, forKey: .languages) ?? defaults.languages
        forced = try container.decodeIfPresent(Bool.self, forKey: .forced) ?? defaults.forced
        // A size a newer server knows and this app does not: the middle one.
        size = (try? container.decodeIfPresent(Size.self, forKey: .size)) ?? defaults.size
        background = try container.decodeIfPresent(Bool.self, forKey: .background) ?? defaults.background
    }
}

/// What happens when something ends, for one viewer (`docs/api.md`, Profiles; `docs/playback.md`,
/// "When something ends"). Kept per viewer on the server, not per device: a TV that plays as a
/// viewer goes by that viewer's choice.
public struct PlaybackPreferences: Codable, Hashable, Sendable {
    /// At the end of a film, and of a series' last episode: what goes with it, to pick from.
    public var filmSuggestions: Bool
    /// The first suggestion starts by itself after the countdown. Off unless the viewer turns it on.
    public var filmAutoplay: Bool
    /// At the end of an episode the next one starts by itself after the countdown.
    public var episodeAutoplay: Bool
    /// How long Up Next counts down: 5, 10 or 15. 0: no countdown, only the Play Now button.
    public var countdownSeconds: Int
    /// Up Next comes at the credits, where the server knows them; at the end otherwise.
    public var startAtCredits: Bool
    /// "Still watching?" after this many episodes in a row without a touch: 2 to 5. 0: never.
    public var stillWatchingEpisodes: Int
    /// "Still watching?" after this many hours without a touch: 1 to 4. 0: never.
    public var stillWatchingHours: Int

    public static let countdownChoices = [0, 5, 10, 15]
    public static let stillWatchingEpisodeChoices = [0, 2, 3, 4, 5]
    public static let stillWatchingHourChoices = [0, 1, 2, 3, 4]

    /// Every viewer's, until they choose.
    public static let defaults = PlaybackPreferences(
        filmSuggestions: true, filmAutoplay: false, episodeAutoplay: true, countdownSeconds: 10,
        startAtCredits: true, stillWatchingEpisodes: 3, stillWatchingHours: 0)
    /// A kids viewer's: asked sooner whether anyone still watches.
    public static let kidsDefaults: PlaybackPreferences = {
        var kids = defaults
        kids.stillWatchingEpisodes = 2
        return kids
    }()

    public init(
        filmSuggestions: Bool, filmAutoplay: Bool, episodeAutoplay: Bool, countdownSeconds: Int,
        startAtCredits: Bool, stillWatchingEpisodes: Int, stillWatchingHours: Int
    ) {
        self.filmSuggestions = filmSuggestions
        self.filmAutoplay = filmAutoplay
        self.episodeAutoplay = episodeAutoplay
        self.countdownSeconds = countdownSeconds
        self.startAtCredits = startAtCredits
        self.stillWatchingEpisodes = stillWatchingEpisodes
        self.stillWatchingHours = stillWatchingHours
    }

    private enum CodingKeys: String, CodingKey {
        case filmSuggestions, filmAutoplay, episodeAutoplay, countdownSeconds, startAtCredits
        case stillWatchingEpisodes, stillWatchingHours
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        func flag(_ key: CodingKeys, _ fallback: Bool) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? fallback }
        // A value a newer server allows and this app does not know: the nearest it knows.
        func choice(_ key: CodingKeys, _ choices: [Int], _ fallback: Int) -> Int {
            guard let value = (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil else { return fallback }
            return choices.contains(value) ? value : choices.min { abs($0 - value) < abs($1 - value) } ?? fallback
        }
        filmSuggestions = flag(.filmSuggestions, d.filmSuggestions)
        filmAutoplay = flag(.filmAutoplay, d.filmAutoplay)
        episodeAutoplay = flag(.episodeAutoplay, d.episodeAutoplay)
        countdownSeconds = choice(.countdownSeconds, Self.countdownChoices, d.countdownSeconds)
        startAtCredits = flag(.startAtCredits, d.startAtCredits)
        stillWatchingEpisodes = choice(.stillWatchingEpisodes, Self.stillWatchingEpisodeChoices, d.stillWatchingEpisodes)
        stillWatchingHours = choice(.stillWatchingHours, Self.stillWatchingHourChoices, d.stillWatchingHours)
    }
}

/// What a viewer wants at intros and credits (`docs/api.md`, Profiles). Kids viewers have the
/// same, chosen for them by a grown-up.
public struct SkipPreferences: Codable, Hashable, Sendable {
    public enum Intro: String, Codable, Hashable, Sendable, CaseIterable {
        /// A Skip Intro button while the intro plays.
        case show
        /// The intro is jumped over by itself.
        case skip
        case off
    }

    public enum Credits: String, Codable, Hashable, Sendable, CaseIterable {
        /// Next Episode from where the credits start.
        case show
        case off
    }

    public var intro: Intro
    public var credits: Credits

    /// The buttons: for every viewer until they choose.
    public static let defaults = SkipPreferences(intro: .show, credits: .show)

    public init(intro: Intro, credits: Credits) {
        self.intro = intro
        self.credits = credits
    }

    private enum CodingKeys: String, CodingKey { case intro, credits }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A choice a newer server knows and this app does not: the buttons.
        intro = (try? container.decodeIfPresent(Intro.self, forKey: .intro)).flatMap { $0 } ?? Self.defaults.intro
        credits = (try? container.decodeIfPresent(Credits.self, forKey: .credits)).flatMap { $0 } ?? Self.defaults.credits
    }
}
