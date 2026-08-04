import CoreLocation

// MARK: - OneShotLocationFetcher
//
// A single "where am I right now" read for the Ask-for-Help composer's
// optional one-tap GPS pin — not a live/background tracker. Requests
// when-in-use authorization if needed, then resolves with one location or an
// error. No other feature in the app reads live device location (weather
// uses a fixed resort coordinate), so this is deliberately self-contained
// rather than a general-purpose location service.

@MainActor
final class OneShotLocationFetcher: NSObject, CLLocationManagerDelegate {
    enum FetchError: Error { case denied, unavailable }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D, Error>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func fetch() async throws -> CLLocationCoordinate2D {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let status = manager.authorizationStatus
            switch status {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                cont.resume(throwing: FetchError.denied)
                self.continuation = nil
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            @unknown default:
                cont.resume(throwing: FetchError.unavailable)
                self.continuation = nil
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .denied, .restricted:
                self.continuation?.resume(throwing: FetchError.denied)
                self.continuation = nil
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.continuation?.resume(returning: coordinate)
            self.continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }
}
