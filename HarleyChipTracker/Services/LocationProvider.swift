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
        let started = Date.now
        task = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self else { return }
                    // Indoors a sharp fix may never come: settle for what there is rather than
                    // keep the GPS running for as long as the app is open.
                    if Date.now.timeIntervalSince(started) > 30 { break }
                    if update.authorizationDenied || update.authorizationDeniedGlobally {
                        self.isDenied = true
                        break
                    }
                    if let location = update.location {
                        self.isDenied = false
                        self.location = location
                        // A fix remembered from before the ride doesn't count as fresh.
                        if location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 1_000
                            && location.timestamp.timeIntervalSinceNow > -120 { break }
                    }
                }
            } catch {
                // Location is optional; the app falls back to the state-by-state list.
            }
            self?.isLocating = false
            self?.task = nil
        }
    }

    /// Takes a fresh fix without ever bringing up the permission prompt.
    func refreshIfAllowed() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: refresh()
        default: break
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
