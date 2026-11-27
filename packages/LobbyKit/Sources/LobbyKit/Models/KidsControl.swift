// SPDX-License-Identifier: MPL-2.0
import Foundation

/// When and what a kids viewer may do (docs/api.md, Kids control; docs/kids-control.md).

/// In the order of strictness: each one allows less than the one before. A mode this build does
/// not know is as strict as Nothing.
public enum KidsMode: OpenStringEnum {
    case everything, ask, listening, nothing
    case unknown(String)

    public static let knownCases: [KidsMode] = [.everything, .ask, .listening, .nothing]

    public var rawValue: String {
        switch self {
        case .everything: "everything"
        case .ask: "ask"
        case .listening: "listening"
        case .nothing: "nothing"
        case .unknown(let raw): raw
        }
    }

    /// 0 for Everything, 3 for Nothing and for what this build does not know.
    public var strictness: Int {
        switch self {
        case .everything: 0
        case .ask: 1
        case .listening: 2
        case .nothing, .unknown: 3
        }
    }

    /// The stricter of the two.
    public func stricter(_ other: KidsMode) -> KidsMode {
        other.strictness > strictness ? other : self
    }
}

public enum KidsAnswerMode: String, Codable, Hashable, Sendable {
    case everything, listening
}

public enum KidsAskStyle: String, Codable, Hashable, Sendable {
    /// The app only asks, and opens with what a grown-up answers.
    case open
    /// Browsing and listening are free; video is asked per title.
    case title
}

/// A time of the week with a mode. Days 1 (Monday) to 7; local times "HH:MM".
public struct KidsPlanBlock: Codable, Hashable, Sendable {
    public var days: [Int]
    public var start: String
    /// "24:00" for midnight. At or before `start`: it goes on into the next day.
    public var end: String
    public var mode: KidsMode
    public var label: String?

    public init(days: [Int], start: String, end: String, mode: KidsMode, label: String? = nil) {
        self.days = days
        self.start = start
        self.end = end
        self.mode = mode
        self.label = label
    }
}

/// A place a grown-up drew on a map. Only the child's device looks whether it is inside, and
/// never tells where it is.
public struct KidsPlace: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var radiusMeters: Double
    public var mode: KidsMode

    public init(id: String, name: String, latitude: Double, longitude: Double, radiusMeters: Double, mode: KidsMode) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.mode = mode
    }
}

public struct KidsScreenTime: Codable, Hashable, Sendable {
    /// Video minutes a day, Monday to Friday; nil: no limit.
    public var weekdayMinutes: Int?
    public var weekendMinutes: Int?
    /// `.listening` or `.nothing`.
    public var whenOut: KidsMode

    public init(weekdayMinutes: Int?, weekendMinutes: Int?, whenOut: KidsMode = .listening) {
        self.weekdayMinutes = weekdayMinutes
        self.weekendMinutes = weekendMinutes
        self.whenOut = whenOut
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Null, not left out: the server reads a missing limit as none too, but says so.
        try container.encode(weekdayMinutes, forKey: .weekdayMinutes)
        try container.encode(weekendMinutes, forKey: .weekendMinutes)
        try container.encode(whenOut, forKey: .whenOut)
    }
}

/// A kids viewer's plan. What a server leaves out is as in no plan.
public struct KidsPlan: Codable, Hashable, Sendable {
    public var defaultMode: KidsMode
    public var blocks: [KidsPlanBlock]
    public var askStyle: KidsAskStyle
    /// The household's music and audiobooks, where the mode allows listening.
    public var music: Bool
    public var screenTime: KidsScreenTime?
    /// The mode away from the home network; nil: no rule.
    public var away: KidsMode?
    public var places: [KidsPlace]
    /// When the device cannot tell where it is; nil: the strictest place's mode.
    public var whenPlaceUnknown: KidsMode?
    /// Grown-ups' devices that are asked; empty: all who may decide. The server works it out
    /// from `askers`.
    public var askDevices: [String]
    /// Who gets asked: grown-up viewers and their devices. Empty: every admin device of the
    /// household, named by all its grown-up viewers.
    public var askers: [KidsAsker]
    /// The music libraries the child hears; nil: all of them.
    public var musicSourceIds: [String]?

    /// As before there were plans.
    /// As before there were plans, with music on: everything is on unless a grown-up turns it off.
    public static let none = KidsPlan()

    public init(
        defaultMode: KidsMode = .everything, blocks: [KidsPlanBlock] = [], askStyle: KidsAskStyle = .open,
        music: Bool = true, screenTime: KidsScreenTime? = nil, away: KidsMode? = nil, places: [KidsPlace] = [],
        whenPlaceUnknown: KidsMode? = nil, askDevices: [String] = [], askers: [KidsAsker] = [], musicSourceIds: [String]? = nil
    ) {
        self.defaultMode = defaultMode
        self.blocks = blocks
        self.askStyle = askStyle
        self.music = music
        self.screenTime = screenTime
        self.away = away
        self.places = places
        self.whenPlaceUnknown = whenPlaceUnknown
        self.askDevices = askDevices
        self.askers = askers
        self.musicSourceIds = musicSourceIds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultMode = try c.decodeIfPresent(KidsMode.self, forKey: .defaultMode) ?? .everything
        blocks = try c.decodeIfPresent([KidsPlanBlock].self, forKey: .blocks) ?? []
        askStyle = (try? c.decodeIfPresent(KidsAskStyle.self, forKey: .askStyle)) ?? .open
        music = try c.decodeIfPresent(Bool.self, forKey: .music) ?? true
        screenTime = try c.decodeIfPresent(KidsScreenTime.self, forKey: .screenTime)
        away = try c.decodeIfPresent(KidsMode.self, forKey: .away)
        places = try c.decodeIfPresent([KidsPlace].self, forKey: .places) ?? []
        whenPlaceUnknown = try c.decodeIfPresent(KidsMode.self, forKey: .whenPlaceUnknown)
        askDevices = try c.decodeIfPresent([String].self, forKey: .askDevices) ?? []
        askers = try c.decodeIfPresent([KidsAsker].self, forKey: .askers) ?? []
        musicSourceIds = try c.decodeIfPresent([String].self, forKey: .musicSourceIds)
    }

    /// The strictest mode the plan names anywhere: what holds when nothing more is known.
    public var strictest: KidsMode {
        var mode = defaultMode
        for block in blocks { mode = mode.stricter(block.mode) }
        for place in places { mode = mode.stricter(place.mode) }
        if let away { mode = mode.stricter(away) }
        if let whenPlaceUnknown { mode = mode.stricter(whenPlaceUnknown) }
        if let screenTime { mode = mode.stricter(screenTime.whenOut) }
        return mode
    }
}

/// A grown-up who is asked, and the devices that are theirs.
public struct KidsAsker: Codable, Hashable, Sendable {
    public var profileId: String
    public var deviceIds: [String]

    public init(profileId: String, deviceIds: [String]) {
        self.profileId = profileId
        self.deviceIds = deviceIds
    }
}

/// A music library of the household.
public struct KidsMusicLibrary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var hint: String?

    public init(id: String, name: String, hint: String? = nil) {
        self.id = id
        self.name = name
        self.hint = hint
    }
}

/// A grown-up viewer of the household, who can be asked.
public struct KidsGrownUp: Codable, Hashable, Sendable, Identifiable {
    public var profileId: String
    public var name: String
    public var id: String { profileId }

    public init(profileId: String, name: String) {
        self.profileId = profileId
        self.name = name
    }
}

/// A device that may decide for the child.
public struct KidsAdminDevice: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct KidsOverride: Codable, Hashable, Sendable {
    public var mode: KidsMode
    public var until: Int64
    public var setBy: String
    public var setAt: Int64

    public init(mode: KidsMode, until: Int64, setBy: String = "", setAt: Int64 = 0) {
        self.mode = mode
        self.until = until
        self.setBy = setBy
        self.setAt = setAt
    }
}

/// A grown-up's answer to Ask first, while it runs.
public struct KidsGrant: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var mode: KidsAnswerMode
    /// Only this title; nil: the whole app.
    public var itemId: String?
    public var until: Int64
    public var by: String
    public var at: Int64

    public init(id: String, mode: KidsAnswerMode, itemId: String? = nil, until: Int64, by: String = "", at: Int64 = 0) {
        self.id = id
        self.mode = mode
        self.itemId = itemId
        self.until = until
        self.by = by
        self.at = at
    }
}

public enum KidsReason: OpenStringEnum {
    case `default`, schedule, away, place, placeUnknown, screenTime, override
    /// Worked out on this device without the server: its copy of the plan ran out, or there is
    /// none. Never sent by the server.
    case offline
    case unknown(String)

    public static let knownCases: [KidsReason] = [
        .default, .schedule, .away, .place, .placeUnknown, .screenTime, .override, .offline,
    ]

    public var rawValue: String {
        switch self {
        case .default: "default"
        case .schedule: "schedule"
        case .away: "away"
        case .place: "place"
        case .placeUnknown: "placeUnknown"
        case .screenTime: "screenTime"
        case .override: "override"
        case .offline: "offline"
        case .unknown(let raw): raw
        }
    }
}

public enum KidsVideo: String, Codable, Hashable, Sendable {
    case all, titles, none

    /// One this build does not know is none.
    public init(from decoder: any Decoder) throws {
        self = KidsVideo(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
    }
}

/// What a kids viewer may do at a moment.
public struct KidsModeAt: Codable, Hashable, Sendable {
    public var mode: KidsMode
    public var reason: KidsReason
    /// The block's label or the place's name, when that is the reason.
    public var detail: String?
    public var browse: Bool
    public var video: KidsVideo
    public var titles: [String]
    public var listening: Bool
    /// Ask to open, and no answer runs: the app only asks.
    public var waiting: Bool
    public var grantId: String?

    public init(
        mode: KidsMode, reason: KidsReason, detail: String? = nil, browse: Bool, video: KidsVideo,
        titles: [String] = [], listening: Bool, waiting: Bool = false, grantId: String? = nil
    ) {
        self.mode = mode
        self.reason = reason
        self.detail = detail
        self.browse = browse
        self.video = video
        self.titles = titles
        self.listening = listening
        self.waiting = waiting
        self.grantId = grantId
    }

    /// Nothing at all: the resting screen.
    public static func resting(_ reason: KidsReason) -> KidsModeAt {
        KidsModeAt(mode: .nothing, reason: reason, browse: false, video: .none, listening: false)
    }

    /// Whether two moments allow the same.
    public func allowsSame(as other: KidsModeAt) -> Bool {
        mode == other.mode && browse == other.browse && video == other.video && listening == other.listening
            && waiting == other.waiting && titles == other.titles
    }

    /// Whether video of this title may play: all video, or a title (or what it is inside of)
    /// that an answer allowed.
    public func allowsVideo(of itemIDs: [String]) -> Bool {
        switch video {
        case .all: true
        case .titles: itemIDs.contains { titles.contains($0) }
        case .none: false
        }
    }

    /// Nothing may be done but rest (or ask).
    public var isResting: Bool { !browse && !listening && video == .none }
}

/// What a kids viewer may do now, until when, and what comes then.
public struct KidsNow: Codable, Hashable, Sendable {
    public struct ScreenTimeToday: Codable, Hashable, Sendable {
        public var day: String
        public var limitMinutes: Int?
        public var usedSeconds: Double

        public init(day: String, limitMinutes: Int?, usedSeconds: Double) {
            self.day = day
            self.limitMinutes = limitMinutes
            self.usedSeconds = usedSeconds
        }
    }

    public var at: KidsModeAt
    /// When this changes by the clock, in milliseconds; nil: not within a week.
    public var until: Int64?
    public var next: KidsModeAt?
    public var screenTime: ScreenTimeToday?

    public init(at: KidsModeAt, until: Int64? = nil, next: KidsModeAt? = nil, screenTime: ScreenTimeToday? = nil) {
        self.at = at
        self.until = until
        self.next = next
        self.screenTime = screenTime
    }

    // The server sends one flat object: the moment's fields with `until`, `next`, `screenTime`.
    private enum CodingKeys: String, CodingKey { case until, next, screenTime }

    public init(from decoder: any Decoder) throws {
        at = try KidsModeAt(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        until = try c.decodeIfPresent(Int64.self, forKey: .until)
        next = try c.decodeIfPresent(KidsModeAt.self, forKey: .next)
        screenTime = try c.decodeIfPresent(ScreenTimeToday.self, forKey: .screenTime)
    }

    public func encode(to encoder: any Encoder) throws {
        try at.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(until, forKey: .until)
        try c.encodeIfPresent(next, forKey: .next)
        try c.encodeIfPresent(screenTime, forKey: .screenTime)
    }
}

public enum KidsRequestKind: String, Codable, Hashable, Sendable {
    case open, title
}

public enum KidsRequestState: String, Codable, Hashable, Sendable {
    case waiting, allowed, declined, expired, cancelled

    /// One this build does not know is over.
    public init(from decoder: any Decoder) throws {
        self = KidsRequestState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .cancelled
    }
}

public enum KidsAnswer: String, Codable, Hashable, Sendable {
    case watch, listen, no
}

/// A child's question to its grown-ups.
public struct KidsRequest: Codable, Hashable, Sendable, Identifiable {
    public struct Viewer: Codable, Hashable, Sendable {
        public var name: String
        public var avatar: String?
        public var color: String

        public init(name: String, avatar: String? = nil, color: String) {
            self.name = name
            self.avatar = avatar
            self.color = color
        }
    }

    public struct Title: Codable, Hashable, Sendable {
        public var id: String
        public var title: String
    }

    public var id: String
    public var profileId: String
    public var deviceId: String
    public var kind: KidsRequestKind
    public var itemId: String?
    public var state: KidsRequestState
    public var createdAt: Int64
    public var expiresAt: Int64
    public var answer: KidsAnswer?
    public var answeredBy: String?
    public var answeredAt: Int64?
    public var grantId: String?
    /// For the grown-ups: who asks, and for what.
    public var viewer: Viewer?
    public var title: Title?
    /// Who answered, as the household calls them.
    public var answeredByName: String?
    /// What the answer gave.
    public var grant: Grant?

    public struct Grant: Codable, Hashable, Sendable {
        public var mode: KidsAnswerMode
        public var until: Int64
        public var itemId: String?

        public init(mode: KidsAnswerMode, until: Int64, itemId: String? = nil) {
            self.mode = mode
            self.until = until
            self.itemId = itemId
        }
    }

    public init(
        id: String, profileId: String, deviceId: String, kind: KidsRequestKind, itemId: String? = nil, state: KidsRequestState,
        createdAt: Int64, expiresAt: Int64, answer: KidsAnswer? = nil, answeredBy: String? = nil, answeredAt: Int64? = nil,
        grantId: String? = nil, viewer: Viewer? = nil, title: Title? = nil, answeredByName: String? = nil, grant: Grant? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.deviceId = deviceId
        self.kind = kind
        self.itemId = itemId
        self.state = state
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.answer = answer
        self.answeredBy = answeredBy
        self.answeredAt = answeredAt
        self.grantId = grantId
        self.viewer = viewer
        self.title = title
        self.answeredByName = answeredByName
        self.grant = grant
    }
}

/// The plan as the server signed it for this device, to hold offline.
public struct SignedKidsPlan: Codable, Hashable, Sendable {
    public var payload: String
    public var signature: String

    public init(payload: String, signature: String) {
        self.payload = payload
        self.signature = signature
    }
}

/// What is inside a signed plan.
public struct KidsPlanCopy: Codable, Hashable, Sendable {
    public struct ScreenTime: Codable, Hashable, Sendable {
        public var day: String
        public var seconds: Double
    }

    public var v: Int
    public var profileId: String
    public var deviceId: String
    public var issuedAt: Int64
    public var validUntil: Int64
    public var timeZone: String
    public var plan: KidsPlan
    public var override: KidsOverride?
    public var grants: [KidsGrant]
    public var screenTime: ScreenTime
}

/// `GET /v1/me/kids`.
public struct KidsMe: Codable, Hashable, Sendable {
    public var profileId: String
    public var now: KidsNow
    public var plan: KidsPlan
    public var timeZone: String
    public var request: KidsRequest?
    public var signed: SignedKidsPlan
    public var publicKey: String
    public var serverTime: Int64
    /// Who is asked, by name: "Asking Dad…". Empty from a server from before names.
    public var askNames: [String]
    public var musicLibraries: [KidsMusicLibrary]

    public init(
        profileId: String, now: KidsNow, plan: KidsPlan, timeZone: String, request: KidsRequest?, signed: SignedKidsPlan,
        publicKey: String, serverTime: Int64, askNames: [String] = [], musicLibraries: [KidsMusicLibrary] = []
    ) {
        self.profileId = profileId
        self.now = now
        self.plan = plan
        self.timeZone = timeZone
        self.request = request
        self.signed = signed
        self.publicKey = publicKey
        self.serverTime = serverTime
        self.askNames = askNames
        self.musicLibraries = musicLibraries
    }

    private enum CodingKeys: String, CodingKey {
        case profileId, now, plan, timeZone, request, signed, publicKey, serverTime, askNames, musicLibraries
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileId = try c.decode(String.self, forKey: .profileId)
        now = try c.decode(KidsNow.self, forKey: .now)
        plan = try c.decode(KidsPlan.self, forKey: .plan)
        timeZone = try c.decode(String.self, forKey: .timeZone)
        request = try c.decodeIfPresent(KidsRequest.self, forKey: .request)
        signed = try c.decode(SignedKidsPlan.self, forKey: .signed)
        publicKey = try c.decode(String.self, forKey: .publicKey)
        serverTime = try c.decode(Int64.self, forKey: .serverTime)
        askNames = try c.decodeIfPresent([String].self, forKey: .askNames) ?? []
        musicLibraries = try c.decodeIfPresent([KidsMusicLibrary].self, forKey: .musicLibraries) ?? []
    }
}

/// `GET /v1/profiles/{id}/kids/plan` and the grown-ups' changes.
public struct KidsPlanView: Codable, Hashable, Sendable {
    public var profileId: String
    public var plan: KidsPlan
    /// False: nobody set a plan; `plan` is then as before plans.
    public var planned: Bool
    public var timeZone: String
    public var now: KidsNow
    public var grants: [KidsGrant]
    public var musicLibraries: [KidsMusicLibrary]
    public var grownUps: [KidsGrownUp]
    public var adminDevices: [KidsAdminDevice]

    public init(
        profileId: String, plan: KidsPlan, planned: Bool, timeZone: String, now: KidsNow, grants: [KidsGrant] = [],
        musicLibraries: [KidsMusicLibrary] = [], grownUps: [KidsGrownUp] = [], adminDevices: [KidsAdminDevice] = []
    ) {
        self.profileId = profileId
        self.plan = plan
        self.planned = planned
        self.timeZone = timeZone
        self.now = now
        self.grants = grants
        self.musicLibraries = musicLibraries
        self.grownUps = grownUps
        self.adminDevices = adminDevices
    }

    private enum CodingKeys: String, CodingKey {
        case profileId, plan, planned, timeZone, now, grants, musicLibraries, grownUps, adminDevices
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileId = try c.decode(String.self, forKey: .profileId)
        plan = try c.decode(KidsPlan.self, forKey: .plan)
        planned = try c.decodeIfPresent(Bool.self, forKey: .planned) ?? false
        timeZone = try c.decode(String.self, forKey: .timeZone)
        now = try c.decode(KidsNow.self, forKey: .now)
        grants = try c.decodeIfPresent([KidsGrant].self, forKey: .grants) ?? []
        musicLibraries = try c.decodeIfPresent([KidsMusicLibrary].self, forKey: .musicLibraries) ?? []
        grownUps = try c.decodeIfPresent([KidsGrownUp].self, forKey: .grownUps) ?? []
        adminDevices = try c.decodeIfPresent([KidsAdminDevice].self, forKey: .adminDevices) ?? []
    }
}

/// What a place report says: never where the device is.
public enum KidsPlaceReport: Hashable, Sendable {
    case inside(placeID: String)
    case outside
    case unknown
}

/// How long an answer or override runs.
public enum KidsLength: Hashable, Sendable {
    case minutes(Int)
    case until(Date)
    /// Until the plan's next switch.
    case nextSwitch
}
