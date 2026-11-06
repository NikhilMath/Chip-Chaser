import Foundation
import SwiftData

/// What the collector has for one location. No record (or quantity 0) means the chip is missing.
///
/// The store syncs through iCloud (CloudKit), so every property has a default and there are
/// no unique constraints. That means two records for one dealer can appear (the same chip
/// marked on two devices before they sync); `ModelContext.mergeDuplicates()` folds them together.
@Model
final class ChipRecord {
    /// Unique per row, so every device picks the same survivor when merging duplicates.
    var rowID: UUID = UUID()
    var dealerID: String = ""
    /// How many of this chip the collector owns. Anything over 1 is an extra for trading.
    var quantity: Int = 0
    var collectedAt: Date?
    var notes: String = ""

    init(dealerID: String, quantity: Int = 0, collectedAt: Date? = nil, notes: String = "") {
        self.rowID = UUID()
        self.dealerID = dealerID
        self.quantity = quantity
        self.collectedAt = collectedAt
        self.notes = notes
    }

    var isCollected: Bool { quantity > 0 }
}

/// A store the collector added because it isn't in the bundled list
/// (a new dealer, a closed one, an event chip, a shop overseas).
@Model
final class CustomDealer {
    /// Unique per row, so every device picks the same survivor when merging duplicates.
    var rowID: UUID = UUID()
    /// The store's identity. Shared by duplicates (e.g. one backup imported on two devices).
    var identifier: UUID = UUID()
    var name: String = ""
    var address: String = ""
    var city: String = ""
    var region: String = ""
    var country: String = "US"
    var createdAt: Date = Date.now

    init(name: String, address: String = "", city: String, region: String, country: String) {
        self.rowID = UUID()
        self.identifier = UUID()
        self.name = name
        self.address = address
        self.city = city
        self.region = region
        self.country = country
        self.createdAt = .now
    }

    var dealerID: String { CustomDealer.dealerID(for: identifier) }

    static func dealerID(for identifier: UUID) -> String { "custom-\(identifier.uuidString)" }

    var asDealer: Dealer {
        Dealer(
            id: dealerID,
            name: name,
            kind: .custom,
            address: address.isEmpty ? nil : address,
            city: city,
            region: region.uppercased(),
            country: country
        )
    }
}
