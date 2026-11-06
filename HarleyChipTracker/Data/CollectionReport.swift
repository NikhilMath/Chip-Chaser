import Foundation

/// Plain-text lists to share in collector groups and trading threads.
nonisolated enum CollectionReport {
    /// "Chips I still need", grouped by state.
    static func missingList(dealers: [Dealer], status: CollectionStatus) -> String {
        let missing = dealers.filter { !status.isCollected($0.id) }
        let collected = dealers.count - missing.count
        var lines = ["Harley-Davidson chips I still need (\(collected) of \(dealers.count) collected):"]
        if missing.isEmpty {
            lines.append("")
            lines.append("None, the collection is complete!")
        }
        for group in RegionGroup.make(from: missing) {
            lines.append("")
            lines.append("\(group.name) (\(group.dealers.count))")
            for dealer in group.dealers {
                lines.append("• \(dealer.name), \(dealer.city)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "Extras I can trade": chips owned more than once.
    static func extrasList(dealers: [Dealer], status: CollectionStatus) -> String {
        let extras = dealers.filter { status.quantity(for: $0.id) > 1 }
        var lines = ["Harley-Davidson chips I have extras of:"]
        if extras.isEmpty {
            lines.append("")
            lines.append("No extras right now.")
        }
        for group in RegionGroup.make(from: extras) {
            lines.append("")
            lines.append(group.name)
            for dealer in group.dealers {
                lines.append("• \(dealer.name), \(dealer.city) ×\(status.quantity(for: dealer.id) - 1)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
