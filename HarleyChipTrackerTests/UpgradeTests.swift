import Foundation
import SwiftData
import Testing
@testable import HarleyChipTracker

/// Guards against an app update losing anyone's chips.
@MainActor
struct UpgradeTests {
    /// Copies a fixture store to a scratch folder, so tests never change the original.
    private func scratchCopy(of fixture: String) throws -> URL {
        let source = try #require(Bundle(for: FixtureBundle.self).url(forResource: fixture, withExtension: "store"),
                                  "\(fixture).store is missing from the test bundle")
        let folder = URL.temporaryDirectory.appending(path: "upgrade-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: "default.store")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    /// `collection-1.0.store` was saved by Chip Chaser 1.0 (build 3/4, the App Store release):
    /// 4 chips collected (one ×3 with a note), a note on a missing chip, and one store added by hand.
    /// If a model change makes it unreadable, this fails before the build reaches anyone.
    @Test func opensACollectionSavedByVersion1_0() throws {
        let url = try scratchCopy(of: "collection-1.0")
        let container = try CloudSync.container(at: url, cloudKit: false)
        let context = container.mainContext

        let records = try context.fetch(FetchDescriptor<ChipRecord>())
        #expect(records.count == 5)
        let anchorage = try #require(context.chipRecord(for: "hd-66"))
        #expect(anchorage.quantity == 1)
        #expect(anchorage.collectedAt == Date(timeIntervalSinceReferenceDate: 802_008_000))
        let fairbanks = try #require(context.chipRecord(for: "hd-68"))
        #expect(fairbanks.quantity == 3)
        #expect(fairbanks.notes == "Traded 2 at Sturgis")
        let wishlist = try #require(context.chipRecord(for: "hd-1069"))
        #expect(wishlist.quantity == 0)
        #expect(wishlist.notes == "Ask about the 30th anniversary chip")

        let stores = try context.fetch(FetchDescriptor<CustomDealer>())
        let store = try #require(stores.first)
        #expect(stores.count == 1)
        #expect(store.name == "Rally Pop-Up Shop")
        #expect(store.identifier == UUID(uuidString: "5A0B7F3C-1D2E-4F60-8A9B-0C1D2E3F4A5B"))

        // Every chip still shows up in the app and counts toward progress.
        let model = AppModel(defaults: try #require(UserDefaults(suiteName: "upgrade-\(UUID().uuidString)")))
        let status = CollectionStatus(records: records)
        let tracked = model.trackedDealers(custom: stores, status: status)
        #expect(status.collectedCount(in: tracked) == 4)
        for record in records {
            #expect(model.dealer(id: record.dealerID, custom: stores) != nil, "\(record.dealerID) no longer resolves")
        }
    }

    @Test func updatedAppCanKeepWritingToAnOldCollection() throws {
        let url = try scratchCopy(of: "collection-1.0")
        do {
            let container = try CloudSync.container(at: url, cloudKit: false)
            container.mainContext.setCollected(true, dealerID: "hd-1069")
            try container.mainContext.save()
        }
        let reopened = try CloudSync.container(at: url, cloudKit: false)
        let records = try reopened.mainContext.fetch(FetchDescriptor<ChipRecord>())
        #expect(CollectionStatus(records: records).isCollected("hd-1069"))
        #expect(CollectionStatus(records: records).quantity(for: "hd-68") == 3)
    }

    /// 1.0 saved collections at SwiftData's default location. Moving the store would open an empty one.
    @Test func storeStaysWhere1_0PutIt() {
        #expect(CloudSync.storeURL == URL.applicationSupportDirectory.appending(path: "default.store"))
    }

    /// Chips are keyed by dealer ID, so no ID the app has ever shipped may disappear from the list.
    @Test func everyShippedDealerIDStillResolves() throws {
        let url = try #require(Bundle(for: FixtureBundle.self).url(forResource: "known-dealer-ids", withExtension: "txt"))
        let ids = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        #expect(ids.count >= 648)
        let missing = ids.filter { DealerDirectory.shared.dealer(id: $0) == nil }
        #expect(missing.isEmpty, "dealers.json dropped shipped IDs: \(missing)")
    }
}

@MainActor
struct ClosedDealerTests {
    let open = Dealer(id: "hd-1", name: "Still Open H-D", kind: .dealer, city: "Sturgis", region: "SD", country: "US")
    let closed = Dealer(id: "hd-2", name: "Closed H-D", kind: .dealer, city: "Rapid City", region: "SD", country: "US",
                        closed: "2027-03-01")

    @Test func closedLocationsDecodeFromTheBundledList() throws {
        let json = #"{"id":"hd-9","name":"Gone H-D","kind":"shop","city":"Wall","region":"SD","country":"US","closed":"2027-03-01"}"#
        let dealer = try JSONDecoder().decode(Dealer.self, from: Data(json.utf8))
        #expect(dealer.isClosed)
        let current = try JSONDecoder().decode(Dealer.self, from: Data(#"{"id":"hd-8","name":"Open","kind":"dealer","city":"X","region":"SD","country":"US"}"#.utf8))
        #expect(!current.isClosed)
    }

    @Test func directoryKeepsClosedLocationsOutOfTheListButFindsThem() {
        let directory = DealerDirectory(dealers: [open, closed])
        #expect(directory.dealers.map(\.id) == ["hd-1"])
        #expect(directory.closedDealers.map(\.id) == ["hd-2"])
        #expect(directory.dealer(id: "hd-2")?.name == "Closed H-D")
    }

    @Test func aClosedDealerKeepsTheChipsOfCollectorsWhoHaveIt() throws {
        let suite = "closed-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(directory: DealerDirectory(dealers: [open, closed]), defaults: defaults)

        let have = CollectionStatus(quantities: ["hd-2": 1])
        let tracked = model.trackedDealers(custom: [], status: have)
        #expect(tracked.map(\.id).sorted() == ["hd-1", "hd-2"], "a collected chip from a closed dealer still counts")
        #expect(have.collectedCount(in: tracked) == 1)

        let missing = model.trackedDealers(custom: [], status: CollectionStatus())
        #expect(missing.map(\.id) == ["hd-1"], "a closed dealer isn't something left to collect")
    }

    @Test func bundledClosedLocationsAreComplete() {
        for dealer in DealerDirectory.shared.closedDealers {
            #expect(!dealer.name.isEmpty && !dealer.city.isEmpty, "\(dealer.id) is incomplete")
            #expect(dealer.kind != .custom)
        }
        let all = DealerDirectory.shared.dealers + DealerDirectory.shared.closedDealers
        #expect(Set(all.map(\.id)).count == all.count, "an ID is both open and closed")
    }
}

@MainActor
struct AutomaticBackupTests {
    let container: ModelContainer
    let backups: AutomaticBackups
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: ChipRecord.self, CustomDealer.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        backups = AutomaticBackups(
            directory: URL.temporaryDirectory.appending(path: "auto-backups-\(UUID().uuidString)", directoryHint: .isDirectory),
            limit: 3
        )
    }

    private func snapshot(at date: Date) throws -> CollectionBackup {
        CollectionBackup(records: try context.fetch(FetchDescriptor<ChipRecord>()),
                         customDealers: try context.fetch(FetchDescriptor<CustomDealer>()),
                         exportedAt: date)
    }

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + Double(n) * 86_400) }

    @Test func neverSavesAnEmptyCollection() throws {
        #expect(try backups.save(try snapshot(at: day(0)), appVersion: "1.1 (5)") == nil)
        #expect(backups.entries().isEmpty)
    }

    @Test func keepsTheCopyFromBeforeAnUpdate() throws {
        context.setCollected(true, dealerID: "hd-1")
        context.setCollected(true, dealerID: "hd-2")
        try backups.save(try snapshot(at: day(0)), appVersion: "1.0 (4)")

        // Same day, the updated app sees fewer chips: its copy is saved separately.
        context.setCollected(false, dealerID: "hd-2")
        try backups.save(try snapshot(at: day(0).addingTimeInterval(60)), appVersion: "1.1 (5)")
        // And replaces only its own copy later that day.
        try backups.save(try snapshot(at: day(0).addingTimeInterval(120)), appVersion: "1.1 (5)")

        let entries = backups.entries()
        #expect(entries.map(\.appVersion) == ["1.1 (5)", "1.0 (4)"])
        #expect(entries.map(\.chipCount) == [1, 2])
        #expect(entries[1].summary == "2 chips · version 1.0 (4)")
    }

    @Test func keepsOnlyTheNewestCopies() throws {
        context.setCollected(true, dealerID: "hd-1")
        for n in 0..<5 {
            try backups.save(try snapshot(at: day(n)), appVersion: "1.1 (5)")
        }
        #expect(backups.entries().map(\.savedAt) == [day(4), day(3), day(2)])
    }

    @Test func restoresAfterTheCollectionIsWiped() throws {
        let store = CustomDealer(name: "Pop-Up", city: "Sturgis", region: "SD", country: "US")
        context.insert(store)
        context.setCollected(true, dealerID: store.dealerID)
        context.setCollected(true, dealerID: "hd-66")
        context.ensureChipRecord(for: "hd-66").quantity = 4
        try backups.save(try snapshot(at: day(0)), appVersion: "1.1 (5)")

        try context.resetCollection()
        let entry = try #require(backups.entries().first)
        #expect(try backups.load(entry.url).restore(into: context) == 2)
        #expect(context.chipRecord(for: "hd-66")?.quantity == 4)
        #expect(try context.fetch(FetchDescriptor<CustomDealer>()).map(\.dealerID) == [store.dealerID])
    }

    @Test func fileNamesSortByDayAndCarryTheVersion() {
        let name = AutomaticBackups.fileName(day: day(0), appVersion: "1.1 (5)")
        #expect(name.hasSuffix(" 1.1 (5).json"))
        #expect(AutomaticBackups.appVersion(fromFileName: URL(filePath: "/x/\(name)")) == "1.1 (5)")
    }
}

/// Finds the test bundle's resources.
private final class FixtureBundle {}
