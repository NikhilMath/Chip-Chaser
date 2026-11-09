import Foundation
import MapKit
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
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
        let tracked = model.trackedDealers(custom: [store], status: CollectionStatus())
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
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
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

    @Test func restoreNeverTakesAnythingAway() throws {
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        // When the backup was saved: a note on a chip not yet collected, and one chip owned once.
        context.ensureChipRecord(for: "hd-1").notes = "ask Bob"
        context.insert(ChipRecord(dealerID: "hd-2", quantity: 1, collectedAt: early, notes: "red"))
        context.insert(ChipRecord(dealerID: "hd-3", quantity: 4, collectedAt: early))
        let backup = CollectionBackup(records: try records(), customDealers: [])

        // Since then: the first chip was collected, the second gained extras and a new note,
        // and the third was traded down to one.
        context.setCollected(true, dealerID: "hd-1")
        let second = try #require(context.chipRecord(for: "hd-2"))
        second.quantity = 3
        second.notes = "red, two from Sturgis"
        try #require(context.chipRecord(for: "hd-3")).quantity = 1

        try backup.restore(into: context)

        let first = try #require(context.chipRecord(for: "hd-1"))
        #expect(first.quantity == 1, "a chip collected since the backup stays collected")
        #expect(first.collectedAt != nil)
        #expect(first.notes == "ask Bob")
        #expect(second.quantity == 3)
        #expect(second.collectedAt == early)
        #expect(second.notes == "red, two from Sturgis", "a note that already holds the old one isn't doubled")
        #expect(try #require(context.chipRecord(for: "hd-3")).quantity == 4, "restoring puts chips back")

        // Different notes are both kept.
        second.notes = "blue"
        try backup.restore(into: context)
        #expect(second.notes == "blue\nred")
    }

    @Test func mapGroupsOnlyPinsThatWouldOverlap() {
        func dealer(_ id: String, _ latitude: Double, _ longitude: Double) -> Dealer {
            Dealer(id: id, name: id, kind: .dealer, city: "Town", region: "WI", country: "US", latitude: latitude, longitude: longitude)
        }
        let dealers = [dealer("a", 43.00, -88.00), dealer("b", 43.02, -88.01), dealer("c", 44.5, -89.5), dealer("far", 30, -100)]
        let status = CollectionStatus(quantities: ["a": 1])
        let size = CGSize(width: 400, height: 800)
        func region(_ span: Double) -> MKCoordinateRegion {
            MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 43.5, longitude: -88.5),
                               span: MKCoordinateSpan(latitudeDelta: span * 2, longitudeDelta: span))
        }

        // Zoomed out: the two neighbours share a mark, the third stands alone, and the one off screen isn't drawn.
        let wide = MapCluster.make(dealers, status: status, in: region(6), mapSize: size)
        #expect(wide.count == 2)
        let pair = wide.first { $0.dealers.count == 2 }
        #expect(pair?.dealers.map(\.id) == ["a", "b"])
        #expect(pair?.collected == 1)
        #expect(wide.contains { $0.single?.id == "c" })

        // The selected location always keeps its own pin.
        #expect(MapCluster.make(dealers, status: status, in: region(6), mapSize: size, keepSeparate: "a").count == 3)

        // Zoomed in on the pair, both show.
        let close = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 43.01, longitude: -88.005),
                                       span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.05))
        #expect(MapCluster.make(dealers, status: status, in: close, mapSize: size).compactMap(\.single?.id).sorted() == ["a", "b"])
        // Tapping a group zooms to a region that holds all of it.
        #expect((pair?.region.span.latitudeDelta ?? 0) >= 0.02)
    }

    @Test func mergeFoldsSyncedDuplicates() throws {
        // The same chip marked on two devices before they synced.
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(ChipRecord(dealerID: "hd-5", quantity: 1, collectedAt: .now, notes: "from iPhone"))
        context.insert(ChipRecord(dealerID: "hd-5", quantity: 3, collectedAt: early, notes: "from iPad"))
        context.insert(ChipRecord(dealerID: "hd-5", quantity: 2, collectedAt: .now, notes: "from iPad"))
        context.insert(ChipRecord(dealerID: "hd-6", quantity: 1))
        let store = CustomDealer(name: "Pop-Up", city: "Sturgis", region: "SD", country: "US")
        let copy = CustomDealer(name: "Pop-Up", city: "Sturgis", region: "SD", country: "US")
        copy.identifier = store.identifier
        context.insert(store)
        context.insert(copy)

        #expect(try context.mergeDuplicates() == 3)

        let merged = try records().filter { $0.dealerID == "hd-5" }
        #expect(merged.count == 1)
        let record = try #require(merged.first)
        #expect(record.quantity == 3, "keeps the highest count")
        #expect(record.collectedAt == early, "keeps the earliest date")
        #expect(record.notes.contains("from iPhone") && record.notes.contains("from iPad"))
        #expect(record.notes.components(separatedBy: "from iPad").count == 2, "identical notes appear once")
        #expect(try records().count == 2)
        #expect(try context.fetch(FetchDescriptor<CustomDealer>()).count == 1)

        #expect(try context.mergeDuplicates() == 0, "nothing left to merge")
    }

    @Test func mergeKeepsTheSameSurvivorEverywhere() throws {
        // Two devices merging the same pair must keep the same row, or both copies get deleted.
        let a = ChipRecord(dealerID: "hd-7", quantity: 1)
        let b = ChipRecord(dealerID: "hd-7", quantity: 1)
        let expected = min(a.rowID.uuidString, b.rowID.uuidString)
        context.insert(b)
        context.insert(a)
        try context.mergeDuplicates()
        #expect(try records().map(\.rowID.uuidString) == [expected])
    }

    @Test func unmarkingClearsEveryCopy() throws {
        context.insert(ChipRecord(dealerID: "hd-8", quantity: 1, collectedAt: .now))
        context.insert(ChipRecord(dealerID: "hd-8", quantity: 2, collectedAt: .now))
        context.setCollected(false, dealerID: "hd-8")
        #expect(try records().isEmpty)
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
        let all = model.trackedDealers(custom: [], status: CollectionStatus())
        #expect(all.count == model.directory.dealers.count, "everything is tracked by default")

        model.includeCanada = false
        model.includeShops = false
        model.includeSatellites = false
        let narrowed = model.trackedDealers(custom: [], status: CollectionStatus())
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
