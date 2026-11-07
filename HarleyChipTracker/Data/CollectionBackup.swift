import CoreTransferable
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// A JSON backup of the collection, for moving to a new phone or keeping a copy.
nonisolated struct CollectionBackup: Codable, Sendable, Transferable {
    struct Chip: Codable, Sendable, Equatable {
        var dealerID: String
        var quantity: Int
        var collectedAt: Date?
        var notes: String
    }

    struct Store: Codable, Sendable, Equatable {
        var identifier: UUID
        var name: String
        var address: String
        var city: String
        var region: String
        var country: String
        var createdAt: Date
    }

    var app = "Chip Chaser"
    var version = 1
    var exportedAt: Date
    var chips: [Chip]
    var customStores: [Store]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { backup in
            try CollectionBackup.encoder.encode(backup)
        }
        .suggestedFileName("Chip Chaser Backup.json")
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension CollectionBackup {
    @MainActor
    init(records: [ChipRecord], customDealers: [CustomDealer], exportedAt: Date = .now) {
        self.exportedAt = exportedAt
        self.chips = records
            .filter { $0.quantity > 0 || !$0.notes.isEmpty }
            .map { Chip(dealerID: $0.dealerID, quantity: $0.quantity, collectedAt: $0.collectedAt, notes: $0.notes) }
            .sorted { $0.dealerID < $1.dealerID }
        self.customStores = customDealers.map {
            Store(identifier: $0.identifier, name: $0.name, address: $0.address, city: $0.city,
                  region: $0.region, country: $0.country, createdAt: $0.createdAt)
        }
    }

    /// Merges the backup into the store: backed-up chips overwrite matching records,
    /// and hand-added stores are added unless they already exist. Returns the number of chips restored.
    @MainActor
    @discardableResult
    func restore(into context: ModelContext) throws -> Int {
        let existingStores = Set(try context.fetch(FetchDescriptor<CustomDealer>()).map(\.identifier))
        for store in customStores where !existingStores.contains(store.identifier) {
            let dealer = CustomDealer(name: store.name, address: store.address, city: store.city,
                                      region: store.region, country: store.country)
            dealer.identifier = store.identifier
            dealer.createdAt = store.createdAt
            context.insert(dealer)
        }
        for chip in chips {
            let record = context.ensureChipRecord(for: chip.dealerID)
            record.quantity = max(0, chip.quantity)
            record.collectedAt = chip.collectedAt
            record.notes = chip.notes
        }
        try context.save()
        return chips.filter { $0.quantity > 0 }.count
    }
}
