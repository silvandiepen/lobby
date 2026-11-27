// SPDX-License-Identifier: MPL-2.0
import Foundation
import Observation
import StoreKit

/// What the update check needs from outside: this app's version, where it came from, the
/// storefront, the network and a place to remember. Tests make their own.
struct UpdateSource: Sendable {
    var bundleID: String
    /// `CFBundleShortVersionString`.
    var version: String
    /// `CFBundleVersion`.
    var build: String
    var system: OperatingSystemVersion
    var platform: StoreLink.Platform = StoreLink.current
    /// Where this copy came from. Only the App Store's asks by itself.
    var channel: @Sendable () async -> DistributionChannel
    /// The storefront's country, as the lookup takes it. nil: the lookup's own default.
    var country: @Sendable () async -> String?
    /// Asks the App Store. Answers its body.
    var fetch: @Sendable (URL) async throws -> Data
    var memory: UpdateMemoryStore
    /// `-lobby-updates-always YES`: asks the App Store whatever the channel, to try the notice
    /// in a test build.
    var alwaysChecks = false

    /// Asks nothing and remembers nothing. For tests that are not about updates.
    static let none = UpdateSource(
        bundleID: "mt.sil.lobby", version: "0.0.0", build: "0", system: ProcessInfo.processInfo.operatingSystemVersion,
        channel: { .other }, country: { nil }, fetch: { _ in throw URLError(.notConnectedToInternet) },
        memory: UpdateMemoryStore(suiteName: nil, key: "lobby.updates.none"))

    /// The real app's.
    static func live(suiteName: String?, defaults: UserDefaults = .standard, bundle: Bundle = .main) -> UpdateSource {
        let info = bundle.infoDictionary ?? [:]
        // `-lobby-updates-version 0.0.1` pretends to be an older version, to see the notice.
        // Debug builds only: a released copy always says what it is.
        #if DEBUG
        let pretended = defaults.string(forKey: "lobby-updates-version")
        let alwaysChecks = defaults.bool(forKey: "lobby-updates-always")
        #else
        let pretended: String? = nil
        let alwaysChecks = false
        #endif
        return UpdateSource(
            bundleID: bundle.bundleIdentifier ?? "mt.sil.lobby",
            version: pretended ?? info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            system: ProcessInfo.processInfo.operatingSystemVersion,
            channel: { await Self.channel(bundle: bundle) },
            country: {
                if let storefront = await Storefront.current, let country = StoreLink.country(fromStorefront: storefront.countryCode) {
                    return country
                }
                return Locale.current.region?.identifier.lowercased()
            },
            fetch: { url in
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: UpdateRules.timeout)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                return data
            },
            memory: UpdateMemoryStore(suiteName: suiteName),
            alwaysChecks: alwaysChecks)
    }

    /// Debug builds are development; otherwise StoreKit says whether the App Store or TestFlight
    /// (its sandbox) installed this copy. A Mac copy without an App Store receipt is not asked:
    /// StoreKit would ask the person to sign in for it.
    private static func channel(bundle: Bundle) async -> DistributionChannel {
        #if DEBUG
        return .development
        #else
        #if os(macOS)
        let receipt = bundle.bundleURL.appending(path: "Contents/_MASReceipt/receipt")
        guard FileManager.default.fileExists(atPath: receipt.path) else { return .other }
        #endif
        guard let transaction = try? await AppTransaction.shared else { return .other }
        switch transaction.unsafePayloadValue.environment {
        case .production: return .appStore
        case .sandbox: return .testFlight
        case .xcode: return .development
        default: return .other
        }
        #endif
    }
}

/// `UpdateMemory` in the app's preferences.
struct UpdateMemoryStore: Sendable {
    let suiteName: String?
    var key = "lobby.updates"

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func read() -> UpdateMemory {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(UpdateMemory.self, from: $0) } ?? UpdateMemory()
    }

    func write(_ memory: UpdateMemory) {
        if let data = try? JSONEncoder().encode(memory) { defaults.set(data, forKey: key) }
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// Whether there is a newer Lobby in the App Store, and when to say so.
///
/// It asks Apple's public lookup at most once a day by itself, and at once from Settings. What
/// it found is offered by `notice(in:)`, which the screens show when nothing is playing and a
/// grown-up is there (`NoticeMoment`).
@MainActor
@Observable
final class UpdateModel {
    enum CheckState: Hashable, Sendable {
        case idle
        case checking
        case upToDate
        /// A newer version, which this device can install.
        case available(StoreRelease)
        /// The App Store does not have Lobby (yet), in this storefront.
        case notInStore
        case failed
    }

    let source: UpdateSource
    private let now: @Sendable () -> Date
    private(set) var state = CheckState.idle
    /// The newest release the App Store has, newer than this app, from the last check.
    private(set) var newer: StoreRelease?
    private(set) var memory: UpdateMemory

    init(source: UpdateSource, now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.now = now
        memory = source.memory.read()
    }

    var running: AppVersion { AppVersion(source.version) ?? AppVersion("0")! }

    /// "Version 0.1.0 (1)", for Settings.
    var versionText: String { "Version \(source.version) (\(source.build))" }

    /// "Suggest Updates", on this device. Off: no check by itself and no notice; Check for
    /// Updates still asks.
    var suggestsUpdates: Bool {
        get { memory.suggestsOff != true }
        set { remember { $0.suggestsOff = newValue ? nil : true } }
    }

    /// At launch and when the app comes to the front: asks the App Store when a day went by,
    /// and only in a copy from the App Store.
    func checkIfDue() async {
        guard suggestsUpdates, state != .checking, UpdateRules.isCheckDue(lastCheckedAt: memory.lastCheckedAt, now: now())
        else { return }
        if !source.alwaysChecks {
            guard await source.channel().checksByItself else { return }
        }
        await check(byHand: false)
    }

    /// "Check for Updates": asks now, whatever the time and the channel.
    func checkNow() async {
        guard state != .checking else { return }
        await check(byHand: true)
    }

    private func check(byHand: Bool) async {
        state = .checking
        let url = StoreLink.lookup(bundleID: source.bundleID, country: await source.country(), on: source.platform)
        do {
            let lookup = try StoreRelease.decode(lookup: try await source.fetch(url))
            remember { $0.lastCheckedAt = now() }
            guard let release = lookup.results.first else {
                newer = nil
                state = .notInStore
                return
            }
            let system = AppVersion.of(source.system)
            if !byHand, memory.skipped(release) {
                // Skipped: not even Settings says so, until someone asks.
                newer = nil
                state = .idle
            } else if UpdateRules.isNewer(release, than: running, system: system) {
                newer = release
                state = .available(release)
            } else {
                newer = nil
                state = .upToDate
            }
        } catch {
            // Not remembered as a check: the next launch tries again.
            state = .failed
        }
    }

    /// The release to tell the person about now, if any.
    func notice(in moment: NoticeMoment) -> StoreRelease? {
        guard suggestsUpdates, moment.allowsNotice, let newer else { return nil }
        return UpdateRules.isOffered(newer, running: running, system: AppVersion.of(source.system), memory: memory, now: now())
            ? newer : nil
    }

    /// "Later": the same version again in three days.
    func later(_ release: StoreRelease) {
        remember {
            $0.answeredVersion = release.version
            $0.answer = .later(until: now().addingTimeInterval(UpdateRules.laterInterval))
        }
    }

    /// "Skip This Version": never by itself again. A newer version is offered as usual.
    func skip(_ release: StoreRelease) {
        remember {
            $0.answeredVersion = release.version
            $0.answer = .skipped
        }
    }

    /// "Update", or the notice was closed: not again for this version. Answers the App Store
    /// page to open.
    @discardableResult
    func done(_ release: StoreRelease) -> URL? {
        remember {
            $0.answeredVersion = release.version
            $0.answer = .done
        }
        return StoreLink.page(of: release, on: source.platform)
    }

    /// What the last check found, for Settings. nil before any check.
    var statusText: String? {
        switch state {
        case .idle: nil
        case .checking: "Checking the App Store…"
        case .upToDate: "Lobby is up to date."
        case .available(let release): "Version \(release.version) is in the App Store."
        case .notInStore: "The App Store has no other version of Lobby."
        case .failed: "The App Store could not be reached. Try again later."
        }
    }

    /// The App Store page of the newer version, for Settings.
    var storePage: URL? { newer.flatMap { StoreLink.page(of: $0, on: source.platform) } }

    // MARK: App and server

    /// What a manager is to be told about this app and its server now, if anything: once per
    /// pair of versions.
    func mismatch(_ compatibility: ServerCompatibility, in moment: NoticeMoment) -> ServerCompatibility? {
        guard moment.allowsNotice, moment.isManager, let key = compatibility.key, memory.toldMismatch != key else { return nil }
        return compatibility
    }

    func told(_ compatibility: ServerCompatibility) {
        remember { $0.toldMismatch = compatibility.key }
    }

    private func remember(_ change: (inout UpdateMemory) -> Void) {
        change(&memory)
        source.memory.write(memory)
    }

    /// Forgets the checks and the answers, with the rest of a namespace that starts clean.
    func forget() {
        source.memory.clear()
        memory = UpdateMemory()
        newer = nil
        state = .idle
    }
}
