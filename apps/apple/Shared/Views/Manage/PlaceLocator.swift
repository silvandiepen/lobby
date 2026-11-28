// SPDX-License-Identifier: MPL-2.0
import CoreLocation
import MapKit

/// Where the grown-up's own device is, once, to start a new place there. Nothing of it is kept
/// or sent: it only moves the map, and the place is what the grown-up saves.
@MainActor
final class PlaceLocator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    private var timeout: Task<Void, Never>?
    private var seconds: Double = 8

    /// Asks for permission when it was never asked, then for one fix. nil: denied, off, or no
    /// fix within `seconds` of asking for it.
    func locate(within seconds: Double = 8) async -> CLLocationCoordinate2D? {
        finish(nil)
        self.seconds = seconds
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting = continuation
                manager.delegate = self
                manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                switch manager.authorizationStatus {
                case .notDetermined:
                    // The answer comes to `locationManagerDidChangeAuthorization`; no clock runs
                    // while the grown-up reads the question.
                    manager.requestWhenInUseAuthorization()
                case let status where KidsPlaceWatcher.isAllowed(status, servicesOn: true):
                    request()
                default:
                    finish(nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil) }
        }
    }

    private func request() {
        manager.requestLocation()
        timeout?.cancel()
        let seconds = seconds
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.finish(nil)
        }
    }

    private func finish(_ coordinate: CLLocationCoordinate2D?) {
        timeout?.cancel()
        timeout = nil
        guard let waiting else { return }
        self.waiting = nil
        waiting.resume(returning: coordinate)
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        guard waiting != nil, timeout == nil else { return }
        if KidsPlaceWatcher.isAllowed(status, servicesOn: true) {
            request()
        } else if status != .notDetermined {
            finish(nil)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in self?.authorizationChanged(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let latitude = last.coordinate.latitude
        let longitude = last.coordinate.longitude
        Task { @MainActor [weak self] in self?.finish(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor [weak self] in self?.finish(nil) }
    }

    /// Roughly the country this device's region settings name, to look at when the device cannot
    /// say where it is. nil: no region, or the map does not know it.
    static func homeRegion(locale: Locale = .current) async -> MKCoordinateRegion? {
        guard let code = locale.region?.identifier, let country = locale.localizedString(forRegionCode: code) else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = country
        request.resultTypes = .address
        guard let response = try? await MKLocalSearch(request: request).start(), !response.mapItems.isEmpty else { return nil }
        return response.boundingRegion
    }
}
