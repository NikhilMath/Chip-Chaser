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
            // Every copy, in case iCloud delivered a duplicate that hasn't been merged yet.
            let records = (try? fetch(FetchDescriptor<ChipRecord>(predicate: #Predicate { $0.dealerID == dealerID }))) ?? []
            for record in records {
                record.quantity = 0
                record.collectedAt = nil
                if record.notes.isEmpty { delete(record) }
            }
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
    ///
    /// Deletes object by object rather than with `delete(model:)`: the batch delete only
    /// hits what's already saved, so a chip marked a moment ago (not yet autosaved) would survive.
    func resetCollection() throws {
        for record in try fetch(FetchDescriptor<ChipRecord>()) { delete(record) }
        for store in try fetch(FetchDescriptor<CustomDealer>()) { delete(store) }
        try save()
    }

    /// Folds duplicate records together and returns how many were removed.
    ///
    /// iCloud can't enforce one record per dealer, so duplicates appear when the same chip is
    /// marked on two devices before they sync, or a backup is imported while iCloud is still
    /// downloading. The merged record keeps the highest count, the earliest date and every note.
    /// Each device picks the same survivor (lowest `rowID`), so two devices merging at the same
    /// time never delete both copies.
    @discardableResult
    func mergeDuplicates() throws -> Int {
        var removed = 0

        let records = try fetch(FetchDescriptor<ChipRecord>())
        for group in Dictionary(grouping: records, by: \.dealerID).values where group.count > 1 {
            let ordered = group.sorted { Self.survivorOrder($0, $1) }
            let survivor = ordered[0]
            survivor.quantity = group.map(\.quantity).max() ?? 0
            survivor.collectedAt = survivor.quantity > 0 ? group.compactMap(\.collectedAt).min() : nil
            var notes: [String] = []
            for note in ordered.map(\.notes) where !note.isEmpty && !notes.contains(note) {
                notes.append(note)
            }
            survivor.notes = notes.joined(separator: "\n")
            for duplicate in ordered.dropFirst() {
                delete(duplicate)
                removed += 1
            }
        }

        let stores = try fetch(FetchDescriptor<CustomDealer>())
        for group in Dictionary(grouping: stores, by: \.identifier).values where group.count > 1 {
            let ordered = group.sorted { ($0.rowID.uuidString, $0.createdAt) < ($1.rowID.uuidString, $1.createdAt) }
            for duplicate in ordered.dropFirst() {
                delete(duplicate)
                removed += 1
            }
        }

        if removed > 0 { try save() }
        return removed
    }

    private static func survivorOrder(_ lhs: ChipRecord, _ rhs: ChipRecord) -> Bool {
        if lhs.rowID != rhs.rowID { return lhs.rowID.uuidString < rhs.rowID.uuidString }
        if lhs.quantity != rhs.quantity { return lhs.quantity > rhs.quantity }
        return lhs.notes < rhs.notes
    }
}
