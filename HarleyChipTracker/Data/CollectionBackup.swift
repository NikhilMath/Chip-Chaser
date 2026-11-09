import CoreTransferable
import Foundation
import SwiftData
import UIKit
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
    /// Chip photos (JPEG) by dealer ID. Only in backups the collector exports: the automatic
    /// daily copies leave them out, and backups from before 1.4 don't have them.
    var photos: [String: Data]?

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

    /// Merges the backup into the store. Restoring only ever adds: a chip that's in both keeps
    /// the higher count, the earlier date and both notes, so nothing marked or written since
    /// the backup was saved is lost. Hand-added stores are added unless they already exist.
    /// Returns the number of collected chips in the backup.
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
            guard let record = context.chipRecord(for: chip.dealerID) else {
                context.insert(ChipRecord(dealerID: chip.dealerID, quantity: max(0, chip.quantity),
                                          collectedAt: chip.collectedAt, notes: chip.notes))
                continue
            }
            record.quantity = max(record.quantity, chip.quantity, 0)
            if record.quantity > 0 {
                record.collectedAt = [record.collectedAt, chip.collectedAt].compactMap { $0 }.min()
            }
            if record.notes.isEmpty {
                record.notes = chip.notes
            } else if !chip.notes.isEmpty && !record.notes.contains(chip.notes) {
                record.notes += "\n" + chip.notes
            }
        }
        try context.save()
        return chips.filter { $0.quantity > 0 }.count
    }
}

/// The backup the collector exports from Settings: the collection plus its chip photos, so a
/// phone on another Apple ID (or a restored one) gets the pictures too.
nonisolated struct CollectionExport: Sendable, Transferable {
    var backup: CollectionBackup
    /// Where each chip's photo is on this iPhone, by dealer ID. Read only when the export is made.
    var photoFiles: [String: URL]

    func data() throws -> Data {
        var backup = backup
        var photos: [String: Data] = [:]
        for (dealerID, url) in photoFiles {
            if let data = try? Data(contentsOf: url) { photos[dealerID] = data }
        }
        backup.photos = photos.isEmpty ? nil : photos
        return try CollectionBackup.encoder.encode(backup)
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { try $0.data() }
            .suggestedFileName("Chip Chaser Backup.json")
    }
}

extension CollectionBackup {
    /// Saves the backup's photos for chips that don't have one on this iPhone. A photo already
    /// here is never replaced. Returns how many were added.
    @MainActor
    @discardableResult
    func restorePhotos(into store: ChipPhotoStore) -> Int {
        var added = 0
        for (dealerID, data) in photos ?? [:] where !store.hasPhoto(for: dealerID) {
            guard let image = UIImage(data: data), (try? store.save(image, for: dealerID)) != nil else { continue }
            added += 1
        }
        return added
    }
}
