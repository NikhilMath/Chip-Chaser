import Foundation
import SwiftData

extension ModelContext {
    /// The collector's record for a dealer, if one exists.
    func chipRecord(for dealerID: String) -> ChipRecord? {
        var descriptor = FetchDescriptor<ChipRecord>(predicate: #Predicate { $0.dealerID == dealerID })
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }

    /// The record for a dealer, creating an empty one when needed.
    @discardableResult
    func ensureChipRecord(for dealerID: String) -> ChipRecord {
        if let existing = chipRecord(for: dealerID) { return existing }
        let record = ChipRecord(dealerID: dealerID)
        insert(record)
        return record
    }

    /// Marks a chip as collected (quantity 1, dated today) or missing (quantity 0).
    func setCollected(_ collected: Bool, dealerID: String) {
        if collected {
            let record = ensureChipRecord(for: dealerID)
            guard record.quantity == 0 else { return }
            record.quantity = 1
            record.collectedAt = .now
        } else {
            guard let record = chipRecord(for: dealerID) else { return }
            record.quantity = 0
            record.collectedAt = nil
            if record.notes.isEmpty { delete(record) }
        }
    }

    func toggleCollected(dealerID: String) {
        let collected = chipRecord(for: dealerID)?.isCollected ?? false
        setCollected(!collected, dealerID: dealerID)
    }

    /// Removes a hand-added store and its chip record.
    func deleteCustomDealer(_ dealer: CustomDealer) {
        if let record = chipRecord(for: dealer.dealerID) { delete(record) }
        delete(dealer)
    }

    /// Deletes every chip record and hand-added store.
    func resetCollection() throws {
        try delete(model: ChipRecord.self)
        try delete(model: CustomDealer.self)
        try save()
    }
}
