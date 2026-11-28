// SPDX-License-Identifier: MPL-2.0
import CoreLocation
import Foundation
import LobbyKit

/// Watches a kids viewer's places on the child's own device and says only inside which one it
/// is (docs/kids-control.md, §7). Never where: a coordinate never leaves this file, and nothing
/// of where the device was is kept.
@MainActor
final class KidsPlaceWatcher {
    /// Follows the places and says what to report, until its task is cancelled. nil: the
    /// device's own Location (CLLocationManager's region monitoring). Tests put their own in.
    typealias Report = @MainActor @Sendable (KidsPlaceReport) async -> Void
    typealias Follow = @MainActor @Sendable ([KidsPlace], _ report: @escaping Report) async -> Void

    private(set) var watching: [KidsPlace] = []
    private var task: Task<Void, Never>?
    private let follow: Follow?
    #if os(iOS) || os(macOS)
    private let manager = CLLocationManager()
    #endif

    init(follow: Follow? = nil) {
        self.follow = follow
    }

    /// Whether places are being watched now.
    var isWatching: Bool { task != nil }

    /// What to tell the server: inside the strictest place the device is in, inside none, or
    /// cannot tell. Without permission, or with Location off, it cannot tell (fail closed).
    nonisolated static func report(isAllowed: Bool, inside: Set<String>, places: [KidsPlace]) -> KidsPlaceReport {
        guard isAllowed else { return .unknown }
        // A place as schedule changes nothing: any place with a mode of its own goes first.
        let rank = { (place: KidsPlace) in place.mode.mode?.strictness ?? -1 }
        let strictest = places.filter { inside.contains($0.id) }.max { rank($0) < rank($1) }
        return strictest.map { .inside(placeID: $0.id) } ?? .outside
    }

    /// Whether Location may be used, as the system says now.
    nonisolated static func isAllowed(_ status: CLAuthorizationStatus, servicesOn: Bool) -> Bool {
        #if os(macOS)
        servicesOn && status == .authorizedAlways
        #else
        servicesOn && (status == .authorizedWhenInUse || status == .authorizedAlways)
        #endif
    }

    /// Places are watched, and Location may not be used (denied, or not asked yet): for the
    /// grown-ups' notice, never for the child.
    var lacksLocation: Bool {
        guard isWatching, follow == nil else { return false }
        #if os(iOS) || os(macOS)
        return !Self.isAllowed(manager.authorizationStatus, servicesOn: true)
        #else
        return false
        #endif
    }

    /// Watches these places, or stops when there are none.
    func watch(_ places: [KidsPlace], for app: AppModel) {
        guard places != watching else { return }
        guard !places.isEmpty else { return stop() }
        end()
        watching = places
        // The app is read again at each report: the watcher never keeps a server's model alive.
        let report: Report = { [weak app] report in await app?.reportKidsPlace(report) }
        if let follow {
            task = Task { await follow(places, report) }
            return
        }
        #if os(iOS) || os(macOS)
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        task = Task { [weak self] in await self?.run(places, report: report) }
        #else
        // A television stays in the house: it is in none of the child's places.
        task = Task { await report(.outside) }
        #endif
    }

    /// Stops watching: on another server, after signing out, out of kids mode. Location no
    /// longer looks at the places (the task's follower stops its regions as it ends).
    func stop() {
        end()
    }

    private func end() {
        watching = []
        task?.cancel()
        task = nil
    }

    #if os(iOS) || os(macOS)
    private func run(_ places: [KidsPlace], report: Report) async {
        let allowed = Self.isAllowed(manager.authorizationStatus, servicesOn: CLLocationManager.locationServicesEnabled())
        guard allowed else {
            await report(.unknown)
            return
        }
        let follower = PlaceFollower(places: places)
        defer { follower.stop() }
        guard follower.start() else {
            // Regions cannot be watched here: it cannot tell.
            await report(.unknown)
            return
        }
        var inside: Set<String> = []
        var known: Set<String> = []
        for await event in follower.events {
            if Task.isCancelled { return }
            switch event.state {
            case .inside:
                known.insert(event.placeID)
                inside.insert(event.placeID)
            case .outside:
                known.insert(event.placeID)
                inside.remove(event.placeID)
            case .unknown:
                known.remove(event.placeID)
                inside.remove(event.placeID)
            }
            let allowed = Self.isAllowed(manager.authorizationStatus, servicesOn: CLLocationManager.locationServicesEnabled())
            // Until every place said, inside one is known; outside all is not.
            let now: KidsPlaceReport =
                !inside.isEmpty || known.count == places.count
                ? Self.report(isAllowed: allowed, inside: inside, places: places) : .unknown
            await report(now)
        }
    }
    #endif
}

#if os(iOS) || os(macOS)
/// Follows whether the device is inside each place, with the system's region monitoring
/// (`CLCircularRegion`). One follower per watch, with its own manager: nothing here is shared
/// between watches and nothing in it can stop the app. (`CLMonitor` did: it stops the process on
/// a failed assertion, and the app's launch in kids mode was where it hit it.)
@MainActor
final class PlaceFollower: NSObject, CLLocationManagerDelegate {
    enum State: Sendable { case inside, outside, unknown }
    struct Event: Sendable {
        var placeID: String
        var state: State
    }

    /// The system watches at most this many regions for an app; further places are never known.
    nonisolated static let maxRegions = 20
    nonisolated private static let prefix = "lobby-kids-place/"

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let manager = CLLocationManager()
    private let regions: [CLCircularRegion]
    private var started = false

    init(places: [KidsPlace]) {
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        self.events = events
        self.continuation = continuation
        // Region identifiers are the app's, not the manager's: this watch's own, so a watch that
        // ends late cannot stop the next one's regions.
        let token = UUID().uuidString
        let limit = manager.maximumRegionMonitoringDistance
        regions = places.prefix(Self.maxRegions).compactMap { place in
            let center = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
            guard CLLocationCoordinate2DIsValid(center), place.radiusMeters > 0 else { return nil }
            let radius = limit > 0 ? min(place.radiusMeters, limit) : place.radiusMeters
            let region = CLCircularRegion(center: center, radius: radius, identifier: "\(Self.prefix)\(token)/\(place.id)")
            region.notifyOnEntry = true
            region.notifyOnExit = true
            return region
        }
        super.init()
        manager.delegate = self
    }

    /// Starts watching. False when this device cannot watch regions.
    func start() -> Bool {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return false }
        // What an earlier launch left: the system keeps regions for the app.
        for region in manager.monitoredRegions where region.identifier.hasPrefix(Self.prefix) {
            manager.stopMonitoring(for: region)
        }
        started = true
        for region in regions {
            manager.startMonitoring(for: region)
            manager.requestState(for: region)
        }
        return true
    }

    func stop() {
        if started {
            for region in regions { manager.stopMonitoring(for: region) }
        }
        started = false
        manager.delegate = nil
        continuation.finish()
    }

    /// The place's id out of a region's identifier.
    nonisolated private static func placeID(of region: CLRegion) -> String? {
        guard region.identifier.hasPrefix(prefix) else { return nil }
        let rest = region.identifier.dropFirst(prefix.count)
        return rest.firstIndex(of: "/").map { String(rest[rest.index(after: $0)...]) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let id = Self.placeID(of: region) else { return }
        let mapped: State = state == .inside ? .inside : state == .outside ? .outside : .unknown
        continuation.yield(Event(placeID: id, state: mapped))
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let id = Self.placeID(of: region) else { return }
        continuation.yield(Event(placeID: id, state: .inside))
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let id = Self.placeID(of: region) else { return }
        continuation.yield(Event(placeID: id, state: .outside))
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: any Error) {
        guard let region, let id = Self.placeID(of: region) else { return }
        continuation.yield(Event(placeID: id, state: .unknown))
    }
}
#endif
