import SwiftData
import SwiftUI

// Sample data for SwiftUI previews and the debug-only `-demoData` launch argument.
// Not wrapped in `#if DEBUG`: `#Preview` blocks are compiled in Release too, so they need these symbols.

extension ModelContainer {
    /// An in-memory store with a handful of collected chips, for SwiftUI previews.
    static var preview: ModelContainer {
        do {
            let container = try ModelContainer(
                for: ChipRecord.self, CustomDealer.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let dealers = DealerDirectory.shared.dealers
            for (offset, dealer) in dealers.enumerated() where offset.isMultiple(of: 7) {
                let quantity = offset.isMultiple(of: 21) ? 3 : 1
                container.mainContext.insert(ChipRecord(
                    dealerID: dealer.id,
                    quantity: quantity,
                    collectedAt: Date.now.addingTimeInterval(-Double(offset) * 86_400)
                ))
            }
            return container
        } catch {
            fatalError("Preview container failed: \(error)")
        }
    }
}

extension Dealer {
    static let sample = Dealer(
        id: "sample",
        name: "Sample Harley-Davidson",
        kind: .dealer,
        address: "3700 W Juneau Ave",
        city: "Milwaukee",
        region: "WI",
        postalCode: "53208",
        country: "US",
        latitude: 43.0464,
        longitude: -87.9604
    )
}
