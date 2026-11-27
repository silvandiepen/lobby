// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A version as people write it: numbers with dots between, `1.10` after `1.9`. What follows a
/// `-` or a space (`1.2-beta`, `1.2 (3)`) is not compared. A missing number counts as 0, so
/// `1.2` and `1.2.0` are the same version.
struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let numbers: [Int]

    init?(_ text: String) {
        let core = text.trimmingCharacters(in: .whitespaces).prefix { $0 != "-" && $0 != " " && $0 != "+" }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        // Trailing zeros say nothing: 1.2.0 is 1.2.
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        self.numbers = numbers
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    var description: String { numbers.map(String.init).joined(separator: ".") }

    /// The system this device runs, as a version.
    static func of(_ system: OperatingSystemVersion) -> AppVersion {
        AppVersion("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")!
    }
}

/// Apple's answer to `https://itunes.apple.com/lookup?bundleId=…`, of which only what the
/// notice needs is read.
struct StoreLookup: Decodable, Sendable {
    let resultCount: Int
    let results: [StoreRelease]
}

/// The version of Lobby the App Store has now.
struct StoreRelease: Decodable, Hashable, Sendable {
    /// The App Store's id of the app, for its page.
    let trackId: Int
    let version: String
    /// The oldest system that can install it. nil: Apple did not say.
    let minimumOsVersion: String?
    /// What is new, as the developer wrote it.
    let releaseNotes: String?
    /// The app's page on the web.
    let trackViewUrl: URL?
    let currentVersionReleaseDate: Date?

    init(
        trackId: Int, version: String, minimumOsVersion: String? = nil, releaseNotes: String? = nil,
        trackViewUrl: URL? = nil, currentVersionReleaseDate: Date? = nil
    ) {
        self.trackId = trackId
        self.version = version
        self.minimumOsVersion = minimumOsVersion
        self.releaseNotes = releaseNotes
        self.trackViewUrl = trackViewUrl
        self.currentVersionReleaseDate = currentVersionReleaseDate
    }

    /// The lookup's JSON, its dates as Apple writes them (`2026-11-20T08:00:00Z`).
    static func decode(lookup data: Data) throws -> StoreLookup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoreLookup.self, from: data)
    }

    /// The first lines of what is new: enough to see what changed, not a page to read.
    var shortNotes: String? {
        guard let notes = releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty else { return nil }
        return Self.trim(notes, limit: 400)
    }

    static func trim(_ text: String, limit: Int) -> String {
        // Blank lines in a row are one.
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var kept: [String] = []
        for line in lines where !(line.isEmpty && (kept.last?.isEmpty ?? true)) { kept.append(line) }
        let joined = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count > limit else { return joined }
        // At the last word that fits.
        let cut = joined.prefix(limit)
        let atWord = cut.lastIndex(where: { $0 == " " || $0 == "\n" }).map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
    }
}

/// How the person answered the notice for a version.
enum UpdateAnswer: Codable, Hashable, Sendable {
    /// Ask again for this version after this moment.
    case later(until: Date)
    /// Update, or the notice was closed: not again for this version.
    case done
    /// "Skip This Version": never offered by itself again. Settings still shows it when asked.
    case skipped
}

/// What the app remembers of the checks and the notices, between launches.
struct UpdateMemory: Codable, Hashable, Sendable {
    var lastCheckedAt: Date?
    /// The version the person last answered the notice for, and how.
    var answeredVersion: String?
    var answer: UpdateAnswer?
    /// The pair of versions (app and server) a manager was last told did not match.
    var toldMismatch: String?
    /// "Suggest Updates" turned off on this device: no check by itself, no notice. nil: on.
    var suggestsOff: Bool?

    /// Whether this version was skipped.
    func skipped(_ release: StoreRelease) -> Bool {
        answer == .skipped && answeredVersion.flatMap(AppVersion.init) == AppVersion(release.version)
    }
}

/// When to ask the App Store and when to offer what it says.
enum UpdateRules {
    /// At most one check a day by itself.
    static let checkInterval: TimeInterval = 24 * 60 * 60
    /// "Later" asks again after three days.
    static let laterInterval: TimeInterval = 3 * 24 * 60 * 60
    /// How long the App Store gets to answer.
    static let timeout: TimeInterval = 10

    /// Whether a check is due now, launching or coming to the front.
    static func isCheckDue(lastCheckedAt: Date?, now: Date) -> Bool {
        guard let lastCheckedAt else { return true }
        // A clock set back does not stop the checks for ever.
        return now.timeIntervalSince(lastCheckedAt) >= checkInterval || now < lastCheckedAt
    }

    /// Whether `release` is a version this device should be told about: newer than what runs,
    /// installable on this system, and not answered for (or "Later" has run out).
    static func isOffered(_ release: StoreRelease, running: AppVersion, system: AppVersion, memory: UpdateMemory, now: Date) -> Bool {
        guard isNewer(release, than: running, system: system) else { return false }
        guard memory.answeredVersion.flatMap(AppVersion.init) == AppVersion(release.version), let answer = memory.answer else {
            return true
        }
        switch answer {
        case .later(let until): return now >= until
        case .done, .skipped: return false
        }
    }

    /// Newer than what runs, and this system can install it.
    static func isNewer(_ release: StoreRelease, than running: AppVersion, system: AppVersion) -> Bool {
        guard let offered = AppVersion(release.version), offered > running else { return false }
        if let minimum = release.minimumOsVersion.flatMap(AppVersion.init), system < minimum { return false }
        return true
    }
}

/// What the screen is doing, for whether a notice may come up now.
struct NoticeMoment: Hashable, Sendable {
    /// The library is on screen (not Connect, not Who is watching).
    var isInLibrary: Bool
    /// Kids mode: notices are for grown-ups.
    var isKidsMode: Bool
    /// A film, an episode or music is playing.
    var isPlaying: Bool
    var isManager: Bool = false

    /// Nothing comes up over a film or the kids screens. It waits for a grown-up in the library.
    var allowsNotice: Bool { isInLibrary && !isKidsMode && !isPlaying }
}

/// Where this copy of the app came from. Only a copy from the App Store asks the App Store by
/// itself: the version of any other is not the store's.
enum DistributionChannel: Hashable, Sendable {
    case appStore
    case testFlight
    /// Built here: a debug build, or one Xcode installed.
    case development
    /// Not from the App Store, or it could not be told.
    case other

    var checksByItself: Bool { self == .appStore }
}

/// Where the App Store's page of the app opens, on this platform.
enum StoreLink {
    enum Platform: Hashable, Sendable { case iOS, macOS, tvOS }

    static var current: Platform {
        #if os(macOS)
        .macOS
        #elseif os(tvOS)
        .tvOS
        #else
        .iOS
        #endif
    }

    /// The App Store app's page, not the web's: the iPhone and iPad open it in the App Store,
    /// the Mac in the Mac App Store, the Apple TV (which has no browser) in its App Store.
    static func page(of release: StoreRelease, on platform: Platform = current) -> URL? {
        switch platform {
        case .iOS: URL(string: "itms-apps://apps.apple.com/app/id\(release.trackId)")
        case .macOS: URL(string: "macappstore://apps.apple.com/app/id\(release.trackId)")
        case .tvOS: URL(string: "com.apple.TVAppStore://itunes.apple.com/app/id\(release.trackId)")
        }
    }

    /// The lookup to ask. The Mac's apps are apart from the others in it.
    static func lookup(bundleID: String, country: String?, on platform: Platform = current) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        var items = [URLQueryItem(name: "bundleId", value: bundleID)]
        if let country { items.append(URLQueryItem(name: "country", value: country.lowercased())) }
        if platform == .macOS { items.append(URLQueryItem(name: "entity", value: "macSoftware")) }
        components.queryItems = items
        return components.url!
    }

    /// A storefront's country (StoreKit gives three letters, `NLD`) as the lookup takes it (`nl`).
    static func country(fromStorefront code: String) -> String? {
        let code = code.trimmingCharacters(in: .whitespaces)
        if code.count == 2 { return code.lowercased() }
        guard code.count == 3, let region = Locale(identifier: "und_\(code.uppercased())").region?.identifier,
            region.count == 2
        else { return nil }
        return region.lowercased()
    }
}

/// Whether this app and the server it is paired with work together.
enum ServerCompatibility: Hashable, Sendable {
    case compatible
    /// The server is older than this app needs: a manager updates the server.
    case serverBehind(server: String, needs: String)
    /// This app is older than the server needs: it is updated from the App Store.
    case appBehind(app: String, needs: String)

    /// The oldest Lobby Server this app works with. Raise it when the app starts to need
    /// something an older server does not have.
    static let minimumServerVersion = "0.1.0"

    init(serverVersion: String, serverNeedsApp: String?, app: AppVersion, minimumServer: String = minimumServerVersion) {
        if let needs = serverNeedsApp.flatMap(AppVersion.init), app < needs {
            self = .appBehind(app: app.description, needs: needs.description)
        } else if let server = AppVersion(serverVersion), let minimum = AppVersion(minimumServer), server < minimum {
            self = .serverBehind(server: server.description, needs: minimum.description)
        } else {
            self = .compatible
        }
    }

    /// A key for "this pair was told": a manager is told once per pair of versions.
    var key: String? {
        switch self {
        case .compatible: nil
        case .serverBehind(let server, let needs): "server \(server) < \(needs)"
        case .appBehind(let app, let needs): "app \(app) < \(needs)"
        }
    }

    var title: String {
        switch self {
        case .compatible: ""
        case .serverBehind: "Lobby Server needs an update"
        case .appBehind: "This app needs an update"
        }
    }

    /// What to do, for a manager.
    var advice: String {
        switch self {
        case .compatible:
            ""
        case .serverBehind(let server, let needs):
            "Lobby Server is version \(server), and this app needs \(needs) or later. On the computer it runs on, run “lobby update”. Settings shows the server's version once it is done."
        case .appBehind(let app, let needs):
            "This app is version \(app), and Lobby Server needs \(needs) or later. Update Lobby from the App Store on this device."
        }
    }
}
