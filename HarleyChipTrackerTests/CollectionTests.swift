import Foundation
import SwiftData
import Testing
@testable import HarleyChipTracker

@MainActor
struct CollectionTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: ChipRecord.self, CustomDealer.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func records() throws -> [ChipRecord] {
        try context.fetch(FetchDescriptor<ChipRecord>())
    }

    @Test func toggleMarksAndUnmarks() throws {
        context.toggleCollected(dealerID: "hd-1")
        let record = try #require(context.chipRecord(for: "hd-1"))
        #expect(record.quantity == 1)
        #expect(record.collectedAt != nil)

        context.toggleCollected(dealerID: "hd-1")
        #expect(try records().isEmpty, "an unmarked chip with no notes should leave no record behind")
    }

    @Test func markingTwiceDoesNotDuplicate() throws {
        context.setCollected(true, dealerID: "hd-1")
        context.setCollected(true, dealerID: "hd-1")
        #expect(try records().count == 1)
    }

    @Test func unmarkingKeepsNotes() throws {
        context.setCollected(true, dealerID: "hd-2")
        context.ensureChipRecord(for: "hd-2").notes = "Gold edition"
        context.setCollected(false, dealerID: "hd-2")
        let record = try #require(context.chipRecord(for: "hd-2"))
        #expect(record.quantity == 0)
        #expect(record.notes == "Gold edition")
    }

    @Test func statusCountsCollectedAndExtras() throws {
        let dealers = ["a", "b", "c"].map {
            Dealer(id: $0, name: $0, kind: .dealer, city: "X", region: "WI", country: "US")
        }
        context.insert(ChipRecord(dealerID: "a", quantity: 1))
        context.insert(ChipRecord(dealerID: "b", quantity: 4))
        context.insert(ChipRecord(dealerID: "c", quantity: 0, notes: "ask about restock"))
        let status = CollectionStatus(records: try records())
        #expect(status.collectedCount(in: dealers) == 2)
        #expect(status.extrasCount(in: dealers) == 3)
        #expect(!status.isCollected("c"))
    }

    @Test func customStoreCountsAndDeletesCleanly() throws {
        let store = CustomDealer(name: "Rally Pop-Up", city: "Sturgis", region: "sd", country: "US")
        context.insert(store)
        context.setCollected(true, dealerID: store.dealerID)
        #expect(store.asDealer.kind == .custom)
        #expect(store.asDealer.region == "SD")

        let model = AppModel(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        let tracked = model.trackedDealers(custom: [store])
        #expect(tracked.contains { $0.id == store.dealerID })

        context.deleteCustomDealer(store)
        #expect(try records().isEmpty)
        #expect(try context.fetch(FetchDescriptor<CustomDealer>()).isEmpty)
    }

    @Test func backupRoundTrips() throws {
        let store = CustomDealer(name: "Closed Dealer", city: "Anytown", region: "OH", country: "US")
        context.insert(store)
        context.insert(ChipRecord(dealerID: "hd-10", quantity: 2, collectedAt: Date(timeIntervalSince1970: 1_700_000_000), notes: "trade"))
        context.insert(ChipRecord(dealerID: store.dealerID, quantity: 1, collectedAt: .now))
        let backup = CollectionBackup(records: try records(), customDealers: [store])
        let data = try CollectionBackup.encoder.encode(backup)

        // Restore into a fresh store.
        let other = try ModelContainer(for: ChipRecord.self, CustomDealer.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let decoded = try CollectionBackup.decoder.decode(CollectionBackup.self, from: data)
        let restored = try decoded.restore(into: other.mainContext)
        #expect(restored == 2)

        let record = try #require(other.mainContext.chipRecord(for: "hd-10"))
        #expect(record.quantity == 2)
        #expect(record.notes == "trade")
        #expect(record.collectedAt == Date(timeIntervalSince1970: 1_700_000_000))
        let stores = try other.mainContext.fetch(FetchDescriptor<CustomDealer>())
        #expect(stores.map(\.dealerID) == [store.dealerID])

        // Importing the same backup again doesn't duplicate anything.
        try decoded.restore(into: other.mainContext)
        #expect(try other.mainContext.fetch(FetchDescriptor<CustomDealer>()).count == 1)
        #expect(try other.mainContext.fetch(FetchDescriptor<ChipRecord>()).count == 2)
    }

    @Test func resetClearsEverything() throws {
        context.insert(CustomDealer(name: "X", city: "Y", region: "WI", country: "US"))
        context.setCollected(true, dealerID: "hd-1")
        try context.resetCollection()
        #expect(try records().isEmpty)
        #expect(try context.fetch(FetchDescriptor<CustomDealer>()).isEmpty)
    }
}

@MainActor
struct TrackingTests {
    @Test func settingsFilterTrackedLocations() throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        let all = model.trackedDealers(custom: [])
        #expect(all.count == model.directory.dealers.count, "everything is tracked by default")

        model.includeCanada = false
        model.includeShops = false
        model.includeSatellites = false
        let narrowed = model.trackedDealers(custom: [])
        #expect(narrowed.allSatisfy { $0.country == "US" && $0.kind == .dealer })
        #expect(narrowed.count < all.count)

        // Settings persist.
        let reloaded = AppModel(defaults: defaults)
        #expect(!reloaded.includeCanada)
        #expect(!reloaded.includeShops)
    }
}

struct ReportTests {
    let dealers = [
        Dealer(id: "1", name: "Frontier H-D", kind: .dealer, city: "Lincoln", region: "NE", country: "US"),
        Dealer(id: "2", name: "Dillon Brothers H-D", kind: .dealer, city: "Omaha", region: "NE", country: "US"),
        Dealer(id: "3", name: "Badlands H-D", kind: .shop, city: "Wall", region: "SD", country: "US"),
    ]

    @Test func missingListGroupsByState() {
        let status = CollectionStatus(quantities: ["1": 1])
        let text = CollectionReport.missingList(dealers: dealers, status: status)
        #expect(text.contains("(1 of 3 collected)"))
        #expect(text.contains("Nebraska (1)\n• Dillon Brothers H-D, Omaha"))
        #expect(text.contains("South Dakota (1)\n• Badlands H-D, Wall"))
        #expect(!text.contains("Frontier"))
    }

    @Test func extrasListShowsSpareCount() {
        let status = CollectionStatus(quantities: ["1": 3, "2": 1])
        let text = CollectionReport.extrasList(dealers: dealers, status: status)
        #expect(text.contains("• Frontier H-D, Lincoln ×2"))
        #expect(!text.contains("Dillon"))
    }
}
