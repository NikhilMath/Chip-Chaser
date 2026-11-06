import CoreLocation
import Observation

/// Gets a one-off location fix for sorting dealers by distance.
@Observable
final class LocationProvider {
    private(set) var location: CLLocation?
    private(set) var isDenied = false
    private(set) var isLocating = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Asks for permission if needed, then takes a fresh fix and stops.
    func refresh() {
        guard task == nil else { return }
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        isLocating = true
        task = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self else { return }
                    if update.authorizationDenied || update.authorizationDeniedGlobally {
                        self.isDenied = true
                        break
                    }
                    if let location = update.location {
                        self.isDenied = false
                        self.location = location
                        if location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 1_000 { break }
                    }
                }
            } catch {
                // Location is optional; the app falls back to the state-by-state list.
            }
            self?.isLocating = false
            self?.task = nil
        }
    }

    func distance(to dealer: Dealer) -> CLLocationDistance? {
        guard let location, let target = dealer.location else { return nil }
        return location.distance(from: target)
    }
}

extension CLLocationDistance {
    /// "12 mi" or "19 km", depending on the user's locale.
    var roadDistanceText: String {
        Measurement(value: self, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}
