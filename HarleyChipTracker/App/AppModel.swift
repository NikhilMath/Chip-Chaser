import Foundation
import Observation

/// App-wide state: the bundled dealer list, what the collector chooses to track, and location.
@Observable
final class AppModel {
    let directory: DealerDirectory
    let location: LocationProvider

    var includeCanada: Bool {
        didSet { defaults.set(includeCanada, forKey: Keys.includeCanada) }
    }

    var includeSatellites: Bool {
        didSet { defaults.set(includeSatellites, forKey: Keys.includeSatellites) }
    }

    var includeShops: Bool {
        didSet { defaults.set(includeShops, forKey: Keys.includeShops) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let includeCanada = "track.includeCanada"
        static let includeSatellites = "track.includeSatellites"
        static let includeShops = "track.includeShops"
    }

    init(directory: DealerDirectory = .shared, defaults: UserDefaults = .standard, location: LocationProvider = LocationProvider()) {
        self.directory = directory
        self.defaults = defaults
        self.location = location
        defaults.register(defaults: [
            Keys.includeCanada: true,
            Keys.includeSatellites: true,
            Keys.includeShops: true,
        ])
        self.includeCanada = defaults.bool(forKey: Keys.includeCanada)
        self.includeSatellites = defaults.bool(forKey: Keys.includeSatellites)
        self.includeShops = defaults.bool(forKey: Keys.includeShops)
    }

    /// Whether a location counts toward the collection under the current settings.
    func isTracked(_ dealer: Dealer) -> Bool {
        switch dealer.kind {
        case .custom: return true
        case .satellite where !includeSatellites: return false
        case .shop where !includeShops: return false
        default: break
        }
        if dealer.country == "CA" && !includeCanada { return false }
        return true
    }

    /// Every tracked location: the bundled list, stores the collector added, and closed
    /// locations whose chip they already have, so a dealer closing never takes a chip away.
    func trackedDealers(custom: [CustomDealer], status: CollectionStatus) -> [Dealer] {
        let closed = directory.closedDealers.filter { status.isCollected($0.id) }
        return (directory.dealers + closed + custom.map(\.asDealer)).filter(isTracked)
    }

    /// Looks up any location by ID, bundled or hand-added, tracked or not.
    func dealer(id: String, custom: [CustomDealer]) -> Dealer? {
        directory.dealer(id: id) ?? custom.first { $0.dealerID == id }?.asDealer
    }
}
