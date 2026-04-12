import CoreLocation

@MainActor
final class LocationService: NSObject, ObservableObject {
    private let manager = CLLocationManager()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var lastLocation: CLLocation?

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdatingIfAllowed() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
    }

    var servicesEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    /// Asks Core Location for a one-shot update (works best when already authorized).
    func requestOneShotLocation() {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            break
        }
    }

    /// Waits for a usable GPS fix for hazard reporting (automatic location at submit time).
    func acquireBestEffortLocation(maxWaitSeconds: TimeInterval = 22) async -> CLLocation? {
        requestWhenInUse()
        startUpdatingIfAllowed()

        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        while Date() < deadline {
            switch authorizationStatus {
            case .denied, .restricted:
                return nil
            case .authorizedAlways, .authorizedWhenInUse:
                requestOneShotLocation()
            default:
                break
            }

            if let loc = lastLocation {
                let age = abs(loc.timestamp.timeIntervalSinceNow)
                guard age <= 120, loc.horizontalAccuracy > 0 else {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                if loc.horizontalAccuracy <= 200 || age <= 25 {
                    return loc
                }
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        if let loc = lastLocation, abs(loc.timestamp.timeIntervalSinceNow) <= 180 {
            return loc
        }
        return nil
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            startUpdatingIfAllowed()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            lastLocation = locations.last
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            _ = error
        }
    }
}
