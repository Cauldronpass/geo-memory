import CoreLocation
import Observation

@Observable
class LocationManager: NSObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    var location: CLLocation?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        manager.startUpdatingLocation()
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            startUpdating()
        }
    }

    func distance(to place: Place) -> CLLocationDistance? {
        guard let location else { return nil }
        let placeLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
        return location.distance(from: placeLocation)
    }

    func formattedDistance(to place: Place) -> String? {
        guard let distance = distance(to: place) else { return nil }
        let miles = distance / 1609.34
        if miles < 0.1 {
            return "\(Int(distance))ft"
        } else {
            return String(format: "%.1f mi", miles)
        }
      }
}
