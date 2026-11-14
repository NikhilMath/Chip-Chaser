import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import HarleyChipTracker

/// Loads the tips from Tips.storekit, a local copy of the App Store Connect products. No real money.
/// Buying one is checked on TestFlight, where tips are free: a purchase in a unit test waits for a
/// payment sheet that never appears.
@MainActor
struct TipJarTests {
    @Test func loadsAllThreeTipsCheapestFirst() async throws {
        let url = try #require(Bundle(for: TipJarTestsBundle.self).url(forResource: "Tips", withExtension: "storekit"),
                               "Tips.storekit is missing from the test bundle")
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        let jar = TipJar(defaults: UserDefaults(suiteName: "tipjar-\(UUID().uuidString)")!)
        await jar.loadProducts()
        #expect(jar.products.map(\.id) == TipJar.productIDs)
        #expect(jar.tipCount == 0)
    }
}

private final class TipJarTestsBundle {}
