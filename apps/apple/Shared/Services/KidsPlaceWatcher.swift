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
    /// device's own Location (CLMonitor). Tests put their own in.
    typealias Report = @MainActor @Sendable (KidsPlaceReport) async -> Void
    typealias Follow = @MainActor @Sendable ([KidsPlace], _ report: @escaping Report) async -> Void

    private(set) var watching: [KidsPlace] = []
    private var task: Task<Void, Never>?
    private let follow: Follow?
    #if os(iOS) || os(macOS)
    private let manager = CLLocationManager()
    private var monitor: CLMonitor?
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
    /// longer looks at the places.
    func stop() {
        end()
        #if os(iOS) || os(macOS)
        if let monitor {
            PlaceMonitor.clearing = Task { for id in await monitor.identifiers { await monitor.remove(id) } }
        }
        #endif
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
        await PlaceMonitor.clearing?.value
        if Task.isCancelled { return }
        let monitor = await PlaceMonitor.shared()
        self.monitor = monitor
        for id in await monitor.identifiers { await monitor.remove(id) }
        for place in places {
            let condition = CLMonitor.CircularGeographicCondition(
                center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), radius: place.radiusMeters)
            await monitor.add(condition, identifier: place.id, assuming: .unknown)
        }
        // Stopped while the places went in: they come out again.
        if Task.isCancelled {
            for id in await monitor.identifiers { await monitor.remove(id) }
            return
        }
        var inside: Set<String> = []
        var known: Set<String> = []
        do {
            for try await event in await monitor.events {
                if Task.isCancelled { return }
                known.insert(event.identifier)
                switch event.state {
                case .satisfied: inside.insert(event.identifier)
                case .unsatisfied: inside.remove(event.identifier)
                default: known.remove(event.identifier)
                }
                let allowed = Self.isAllowed(manager.authorizationStatus, servicesOn: CLLocationManager.locationServicesEnabled())
                // Until every place said, inside one is known; outside all is not.
                let now: KidsPlaceReport =
                    !inside.isEmpty || known.count == places.count
                    ? Self.report(isAllowed: allowed, inside: inside, places: places) : .unknown
                await report(now)
            }
        } catch {
            guard !Task.isCancelled else { return }
            await report(.unknown)
        }
    }
    #endif
}

#if os(iOS) || os(macOS)
/// The one Location monitor of the app. CoreLocation allows a single monitor per name in a
/// process and stops the app on a second, so every watcher (one per server's model) shares it,
/// and a watch that starts while another is still making it waits for that one.
@MainActor
enum PlaceMonitor {
    private static var making: Task<CLMonitor, Never>?
    /// Taking the places out of the monitor after a stop; the next watch, of any server, waits for it.
    static var clearing: Task<Void, Never>?

    static func shared() async -> CLMonitor {
        if let making { return await making.value }
        let task = Task { await CLMonitor("lobby-kids-places") }
        making = task
        return await task.value
    }
}
#endif
