// SPDX-License-Identifier: MPL-2.0
import LobbyKit

/// Who is looking at Settings, as far as it decides what they see (docs/decisions.md, "Settings,
/// one page per subject"). Plain values, so the choice can be tested without a screen.
struct SettingsAudience: Equatable, Sendable {
    var level: DeviceAccess = .viewer
    /// The device is in someone else's household on this server.
    var isGuest = false
    /// A kids viewer is in front, or the device belongs to one.
    var isKidsMode = false
    /// Paired with a server at all. Settings can open before that, from the viewer picker.
    var isConnected = true
    /// A viewer was chosen on this device.
    var hasViewer = true
    /// What the server keeps per viewer; an older server has some of it not.
    var offersPlayback = true
    var offersSubtitles = true
    var offersSkipping = true
    /// The app's sidebar has Categories itself (the Mac).
    var sidebarHasCategories = false
    /// The server still waits for its first setup.
    var needsSetup = false

    var isServerAdmin: Bool { level == .admin && !isKidsMode }
    var isHouseholdManager: Bool { (level == .admin || level == .householdAdmin) && !isKidsMode }
}

/// One page of Settings: one subject, a few controls.
enum SettingsPage: String, CaseIterable, Hashable, Sendable, Identifiable {
    // You
    case you, playback, subtitles, skipping
    // This device
    case connection, servers, device, downloads, kidsMode
    // Household
    case devices, viewers, kids, categories, householdStats
    // Server
    case serverGeneral, libraryFolders, imports, matching, converting, appleTVs, speakers, away, households,
        statistics, backups, advanced
    // About
    case about

    var id: String { rawValue }

    var group: SettingsGroup {
        switch self {
        case .you, .playback, .subtitles, .skipping: .you
        case .connection, .servers, .device, .downloads, .kidsMode: .device
        case .devices, .viewers, .kids, .categories, .householdStats: .household
        case .serverGeneral, .libraryFolders, .imports, .matching, .converting, .appleTVs, .speakers, .away,
            .households, .statistics, .backups, .advanced:
            .server
        case .about: .about
        }
    }

    var title: String {
        switch self {
        case .you: "You"
        case .playback: "Playback"
        case .subtitles: "Subtitles"
        case .skipping: "Intros and Credits"
        case .connection: "Connection"
        case .servers: "Servers"
        case .device: "This Device"
        case .downloads: "Downloads"
        case .kidsMode: "Kids Mode"
        case .devices: "Devices"
        case .viewers: "Viewers"
        case .kids: "Kids"
        case .categories: "Categories"
        case .householdStats: "Household Statistics"
        case .serverGeneral: "General"
        case .libraryFolders: "Library Folders"
        case .imports: "Imports and Uploads"
        case .matching: "Matching"
        case .converting: "Converting"
        case .appleTVs: "Apple TVs"
        case .speakers: "Speakers"
        case .away: "Away From Home"
        case .households: "Households"
        case .statistics: "Statistics"
        case .backups: "Backups"
        case .advanced: "Advanced"
        case .about: "About Lobby"
        }
    }

    /// The one line under the page that says what it is for.
    var summary: String {
        switch self {
        case .you: "Your picture and what you watched."
        case .playback: "What plays next, and when Lobby asks if you are still watching."
        case .subtitles: "Which subtitles you see, and how they look."
        case .skipping: "Skipping intros and going on at the credits."
        case .connection: "How this device reaches Lobby Server."
        case .servers: "Your own server and others you were invited to."
        case .device: "What this device is to the server, and whether others can play on it."
        case .downloads: "When this device downloads, and what it shows without the server."
        case .kidsMode: "What this device does while a kids viewer is in front."
        case .devices: "New devices to let in, and the devices of your household."
        case .viewers: "One viewer for each person who watches."
        case .kids: "Your kids viewers, and the code that leads out of kids mode on an Apple TV."
        case .categories: "The categories of the library, and their order."
        case .householdStats: "What your household watches."
        case .serverGeneral: "The server's name, and how titles are named."
        case .libraryFolders: "The folders Lobby reads films, series and music from."
        case .imports: "Folders and uploads where new films and episodes arrive."
        case .matching: "Posters, summaries and genres from TMDB."
        case .converting: "When and how the server makes copies that play everywhere."
        case .appleTVs: "The Apple TVs the server turns on for Play On."
        case .speakers: "The HomePods and speakers the server plays music and stories to."
        case .away: "Watching when you are not at home."
        case .households: "Other households you share the library with."
        case .statistics: "What is watched on the server, and how long that is kept."
        case .backups: "How often the server backs up what it keeps."
        case .advanced: "Settings to leave alone unless something needs them."
        case .about: "This app's version, updates, and what it is made with."
        }
    }

    /// Words a search finds the page by, besides its title.
    var keywords: [String] {
        switch self {
        case .you: ["picture", "avatar", "profile", "month in lobby", "history"]
        case .playback: ["next episode", "autoplay", "countdown", "credits", "suggestions", "still watching"]
        case .subtitles: ["language", "forced", "size", "background", "captions"]
        case .skipping: ["skip intro", "intro", "credits", "next episode"]
        case .connection: ["address", "status", "version", "road", "direct connection", "sign out", "tailscale"]
        case .servers: ["switch", "library", "add server"]
        case .device: ["name", "role", "play on", "others can play"]
        case .downloads: ["mobile data", "cellular", "downloaded only", "offline", "wi-fi"]
        case .kidsMode: ["kids icon", "trailers", "children"]
        case .devices: ["pair", "code", "approve", "waiting", "invite", "add a device", "remove device"]
        case .viewers: ["add a viewer", "people", "profile", "remove viewer"]
        case .kids: ["children", "kids viewer", "code for grown-ups", "limits", "screen time"]
        case .categories: ["groups", "order", "icons"]
        case .householdStats: ["statistics", "watched"]
        case .serverGeneral: ["name", "home network", "language", "bonjour"]
        case .libraryFolders: ["folders", "movies", "series", "music", "audiobooks", "rescan", "look through"]
        case .imports: ["import folders", "inbox", "upload", "copy between drives"]
        case .matching: ["tmdb", "key", "posters", "metadata"]
        case .converting: ["conversion", "repackage", "mkv", "hours", "free space", "transcode"]
        case .appleTVs: ["wake", "turn on", "play on", "who is watching"]
        case .speakers: ["homepod", "airplay", "music", "stories"]
        case .away: ["outside", "remote", "addresses", "upload limit", "access from outside"]
        case .households: ["share", "invite a household", "guests"]
        case .statistics: ["history", "keep", "watched"]
        case .backups: ["backup", "keep"]
        case .advanced: ["cache", "copies", "raw", "earlier versions", "history", "lobby.config.json"]
        case .about: ["version", "updates", "app store", "acknowledgements", "tmdb", "licences"]
        }
    }

    /// The server settings this page shows, by key, in this order. Empty for a page that holds
    /// none. Keys the server has that no page names are shown under Advanced.
    var serverKeys: [String] {
        switch self {
        case .serverGeneral: ["serverName", "advertise", "language"]
        case .libraryFolders: ["roots", "rescanMinutes"]
        case .imports: ["import.folders", "import.waitMinutes", "import.copyAcrossDrives", "uploads.maxFileGb", "uploads.quotaGb"]
        case .converting: ["conversion.dir", "conversion.hours", "conversion.server", "conversion.repackage", "conversion.minFreeGb"]
        case .appleTVs: ["remote.wake.enabled", "remote.wake.kids", "remote.wake.pickProfile"]
        case .speakers: ["remote.wake.speakers"]
        case .away: ["addresses.remote", "outside.direct.maxUploadMbit"]
        case .statistics: ["statistics.keepDays"]
        case .backups: ["backup.everyHours", "backup.keep"]
        case .advanced: ["stabilityMs", "probeConcurrency", "playback.maxCacheGb", "playback.maxConcurrent", "music.maxCacheGb"]
        default: []
        }
    }

    /// Keys a page shows with controls of its own (the folder lists, the switches of the Apple
    /// TVs and the speakers), not as plain rows.
    static let customKeys: Set<String> = ["roots", "import.folders", "remote.wake.enabled", "remote.wake.kids", "remote.wake.speakers"]

    /// Every key some page shows.
    static let placedServerKeys: Set<String> = Set(allCases.flatMap(\.serverKeys))

    /// The server settings a page shows as plain rows: its own keys, and on Advanced also those
    /// of a newer server that no page knows yet.
    func rowKeys(among available: [String]) -> [String] {
        let own = serverKeys.filter { available.contains($0) && !Self.customKeys.contains($0) }
        guard self == .advanced else { return own }
        return own + available.filter { !Self.placedServerKeys.contains($0) }
    }

    /// The keys whose changes are reviewed and saved together on this page.
    func draftKeys(among available: [String]) -> Set<String> {
        Set(serverKeys).union(rowKeys(among: available))
    }

    /// Whether this audience sees the page.
    func isVisible(to audience: SettingsAudience) -> Bool {
        // Kids mode: only what the app is. The rest is a grown-up's (docs/kids.md).
        if audience.isKidsMode { return self == .about }
        switch self {
        case .you: return audience.isConnected && audience.hasViewer
        case .playback: return audience.isConnected && audience.hasViewer && audience.offersPlayback
        case .subtitles: return audience.isConnected && audience.hasViewer && audience.offersSubtitles
        case .skipping: return audience.isConnected && audience.hasViewer && audience.offersSkipping
        case .connection, .device, .downloads, .kidsMode: return audience.isConnected
        case .servers: return true
        case .devices, .viewers, .kids: return audience.isConnected && audience.isHouseholdManager
        case .householdStats: return audience.isConnected && audience.isHouseholdManager && audience.level == .householdAdmin
        case .categories: return audience.isConnected && audience.isServerAdmin && !audience.sidebarHasCategories
        case .serverGeneral, .libraryFolders, .imports, .matching, .converting, .appleTVs, .speakers, .away, .households,
            .statistics, .backups, .advanced:
            return audience.isConnected && audience.isServerAdmin
        case .about: return true
        }
    }

    /// Whether a search for `query` finds this page.
    func matches(_ query: String, more: [String] = []) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = ([title, summary] + keywords + more).joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

/// The groups of the root list, in order.
enum SettingsGroup: String, CaseIterable, Hashable, Sendable {
    case you, device, household, server, about

    var title: String {
        switch self {
        case .you: "You"
        case .device: "This Device"
        case .household: "Household"
        case .server: "Server"
        case .about: "About"
        }
    }
}

/// What the root of Settings lists for an audience: the groups that have a page, each with its
/// pages in order.
enum SettingsMap {
    static func groups(for audience: SettingsAudience) -> [(group: SettingsGroup, pages: [SettingsPage])] {
        SettingsGroup.allCases.compactMap { group in
            let pages = SettingsPage.allCases.filter { $0.group == group && $0.isVisible(to: audience) }
            return pages.isEmpty ? nil : (group, pages)
        }
    }

    static func pages(for audience: SettingsAudience) -> [SettingsPage] {
        groups(for: audience).flatMap(\.pages)
    }

    /// The pages a search finds, in the order of the root. `more` adds words per page, such as
    /// the titles of the server's own settings on it.
    static func search(_ query: String, for audience: SettingsAudience, more: (SettingsPage) -> [String] = { _ in [] }) -> [SettingsPage] {
        pages(for: audience).filter { $0.matches(query, more: more($0)) }
    }
}
