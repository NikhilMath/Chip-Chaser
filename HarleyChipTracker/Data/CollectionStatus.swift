import Foundation

/// A snapshot of the collection: how many of each chip the collector owns.
nonisolated struct CollectionStatus: Sendable {
    private var quantities: [String: Int]

    init(quantities: [String: Int] = [:]) {
        self.quantities = quantities.filter { $0.value > 0 }
    }

    @MainActor
    init(records: [ChipRecord]) {
        var map: [String: Int] = [:]
        for record in records where record.quantity > 0 {
            map[record.dealerID, default: 0] = max(map[record.dealerID] ?? 0, record.quantity)
        }
        self.quantities = map
    }

    func quantity(for dealerID: String) -> Int { quantities[dealerID] ?? 0 }

    func isCollected(_ dealerID: String) -> Bool { quantity(for: dealerID) > 0 }

    func collectedCount(in dealers: [Dealer]) -> Int {
        dealers.reduce(0) { $0 + (isCollected($1.id) ? 1 : 0) }
    }

    /// Chips beyond the first, which collectors keep for trading.
    func extrasCount(in dealers: [Dealer]) -> Int {
        dealers.reduce(0) { $0 + max(0, quantity(for: $1.id) - 1) }
    }
}

/// The All / Missing / Collected filter used on the list and map.
nonisolated enum ChipFilter: String, CaseIterable, Identifiable, Sendable {
    case all, missing, collected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .missing: "Missing"
        case .collected: "Collected"
        }
    }

    func includes(collected: Bool) -> Bool {
        switch self {
        case .all: true
        case .missing: !collected
        case .collected: collected
        }
    }
}

/// Dealers in one state or province, used for list sections and progress rows.
nonisolated struct RegionGroup: Identifiable, Sendable {
    let key: RegionKey
    let dealers: [Dealer]

    var id: String { key.id }
    var name: String { key.name }

    /// Groups dealers by state/province: US first, then Canada, then others, each alphabetical.
    static func make(from dealers: [Dealer]) -> [RegionGroup] {
        Dictionary(grouping: dealers, by: \.regionKey)
            .map { key, members in
                RegionGroup(key: key, dealers: members.sorted(by: Dealer.byName))
            }
            .sorted {
                let lhs = (Regions.countryRank($0.key.country), $0.key.country, $0.name)
                let rhs = (Regions.countryRank($1.key.country), $1.key.country, $1.name)
                return lhs < rhs
            }
    }
}

nonisolated extension Dealer {
    static func byName(_ lhs: Dealer, _ rhs: Dealer) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.city.localizedStandardCompare(rhs.city) == .orderedAscending
    }
}
