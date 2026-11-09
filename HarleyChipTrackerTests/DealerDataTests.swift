import Foundation
import Testing
@testable import HarleyChipTracker

@MainActor
struct DealerDirectoryTests {
    let directory = DealerDirectory.shared

    @Test func bundledListLoads() {
        #expect(directory.dealers.count > 600)
        #expect(!directory.generated.isEmpty)
        #expect(directory.generatedDisplay != directory.generated, "generated date should parse")
    }

    @Test func idsAreUnique() {
        let ids = directory.dealers.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyDealerIsMappableAndNamed() {
        for dealer in directory.dealers {
            #expect(!dealer.name.isEmpty)
            #expect(!dealer.city.isEmpty, "\(dealer.id) has no city")
            #expect(dealer.coordinate != nil, "\(dealer.name) has no coordinates")
            #expect(dealer.regionName != dealer.region, "\(dealer.name): unknown region \(dealer.region)")
            #expect(dealer.kind != .custom)
        }
    }

    @Test func coversUSAndCanadaOnly() {
        let countries = Set(directory.dealers.map(\.country))
        #expect(countries == ["US", "CA"])
        let states = Set(directory.dealers.filter { $0.country == "US" }.map(\.region))
        #expect(states.isSuperset(of: ["WI", "CA", "TX", "FL", "NY", "AK", "HI"]))
    }

    @Test func satelliteParentsExist() {
        for dealer in directory.dealers {
            if let parentId = dealer.parentId {
                #expect(directory.dealer(id: parentId) != nil, "\(dealer.name) points at missing parent \(parentId)")
            }
        }
    }
}

struct DealerTests {
    let dealer = Dealer(
        id: "hd-1", name: "Test Harley-Davidson", kind: .dealer, address: "1 Main St",
        city: "Sturgis", region: "SD", postalCode: "57785-0000", country: "US",
        latitude: 44.41, longitude: -103.5, phone: "(605) 555-0100", website: "https://example.com"
    )

    @Test func searchMatchesNameCityStateAndZip() {
        #expect(dealer.matches(search: ""))
        #expect(dealer.matches(search: "sturgis"))
        #expect(dealer.matches(search: "Test Harley"))
        #expect(dealer.matches(search: "sd"))
        #expect(dealer.matches(search: "South Dakota"))
        #expect(dealer.matches(search: "5778"))
        #expect(dealer.matches(search: "  sturgis  "), "surrounding whitespace is ignored")
        #expect(dealer.matches(search: "sturgis sd"), "several words each match something")
        #expect(dealer.matches(search: "Sturgis, South Dakota"))
        #expect(dealer.matches(search: "test 57785"))
        #expect(!dealer.matches(search: "sturgis wi"), "every word has to match")
        #expect(!dealer.matches(search: "Milwaukee"))
        #expect(!dealer.matches(search: "WI"))
    }

    @Test func formatsAddressAndLinks() {
        #expect(dealer.fullAddress == "1 Main St\nSturgis, SD 57785")
        #expect(dealer.phoneURL?.absoluteString == "tel:6055550100")
        #expect(dealer.websiteURL?.host() == "example.com")
        #expect(dealer.mapsURL?.absoluteString.contains("ll=44.41,-103.5") == true)
    }

    @Test func groupsUSBeforeCanadaAlphabetically() {
        let dealers = [
            Dealer(id: "a", name: "A", kind: .dealer, city: "Calgary", region: "AB", country: "CA"),
            Dealer(id: "b", name: "B", kind: .dealer, city: "Mobile", region: "AL", country: "US"),
            Dealer(id: "c", name: "C", kind: .dealer, city: "Laramie", region: "WY", country: "US"),
            Dealer(id: "d", name: "D", kind: .dealer, city: "Juneau", region: "AK", country: "US"),
        ]
        let names = RegionGroup.make(from: dealers).map(\.name)
        #expect(names == ["Alabama", "Alaska", "Wyoming", "Alberta"])
    }
}

/// A downloaded dealer list is only ever used when it can't strand a chip.
@MainActor
struct DealerListUpdateTests {
    private func dealer(_ id: String, closed: String? = nil) -> Dealer {
        Dealer(id: id, name: "Store \(id)", kind: .dealer, city: "Town", region: "WI", country: "US", closed: closed)
    }

    private func json(_ ids: [String], generated: String) -> Data {
        let rows = ids.map { #"{"id": "\#($0)", "name": "Store", "kind": "dealer", "city": "Town", "region": "WI", "country": "US"}"# }
        return Data(#"{"source": "test", "generated": "\#(generated)", "dealers": [\#(rows.joined(separator: ","))]}"#.utf8)
    }

    @Test func newerListWithEveryLocationReplacesTheBundledOne() throws {
        let bundled = DealerDirectory(dealers: [dealer("hd-1"), dealer("hd-2")], generated: "2026-11-08")
        let folder = URL.temporaryDirectory.appending(path: "dealer-list-\(UUID().uuidString)")
        let file = folder.appending(path: "dealers.json")
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(DealerDirectory.newest(bundled: bundled, downloaded: file) === bundled, "no download yet")

        #expect(try DealerListUpdate.save(json(["hd-1", "hd-2", "hd-3"], generated: "2026-12-01"), ifNewerThan: bundled, to: file))
        let newest = DealerDirectory.newest(bundled: bundled, downloaded: file)
        #expect(newest.generated == "2026-12-01")
        #expect(newest.dealer(id: "hd-3") != nil)

        // A later app update bundles an even newer list: the old download is ignored.
        let updated = DealerDirectory(dealers: [dealer("hd-1"), dealer("hd-2"), dealer("hd-3"), dealer("hd-4")], generated: "2027-01-15")
        #expect(DealerDirectory.newest(bundled: updated, downloaded: file) === updated)
    }

    @Test func unsafeListsAreThrownAway() throws {
        let bundled = DealerDirectory(dealers: [dealer("hd-1"), dealer("hd-2", closed: "2026-10-01")], generated: "2026-11-08")
        let file = URL.temporaryDirectory.appending(path: "dealer-list-\(UUID().uuidString)/dealers.json")

        // Lost a location (even a closed one), not newer, not a date, or not a dealer list at all.
        #expect(try !DealerListUpdate.save(json(["hd-1"], generated: "2026-12-01"), ifNewerThan: bundled, to: file))
        #expect(try !DealerListUpdate.save(json(["hd-1", "hd-2"], generated: "2026-11-08"), ifNewerThan: bundled, to: file))
        #expect(try !DealerListUpdate.save(json(["hd-1", "hd-2"], generated: "soon"), ifNewerThan: bundled, to: file))
        #expect(try !DealerListUpdate.save(Data("<html>Not Found</html>".utf8), ifNewerThan: bundled, to: file))
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }
}
