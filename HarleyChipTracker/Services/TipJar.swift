import Foundation
import Observation
import StoreKit

/// Optional tips through the App Store. Tips unlock nothing: every feature stays free.
///
/// The three products are consumables set up in App Store Connect with the IDs in `productIDs`.
/// Until they exist there (or when the App Store can't be reached), `products` stays empty and
/// Settings hides the tip section, so a build without them never shows a broken screen.
@Observable
final class TipJar {
    static let productIDs = [
        "com.nikhilmath.HarleyChipTracker.tip.small",
        "com.nikhilmath.HarleyChipTracker.tip.medium",
        "com.nikhilmath.HarleyChipTracker.tip.large",
    ]

    enum PurchaseResult: Equatable {
        case thanked
        /// Waiting on Ask to Buy or a payment check; the App Store finishes it later.
        case pending
        case cancelled
    }

    /// Cheapest first. Empty until loaded, or if the App Store has none.
    private(set) var products: [Product] = []
    /// The product being bought right now.
    private(set) var purchasing: Product.ID?
    /// How many tips this iPhone has sent, to say thanks again.
    private(set) var tipCount: Int

    private let defaults: UserDefaults
    private var updates: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tipCount = defaults.integer(forKey: Self.tipCountKey)
    }

    /// Loads the products once, and finishes tips the App Store approves later (Ask to Buy).
    func start() async {
        // Under tests, StoreKit would remember an empty answer before the test's StoreKit file loads.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if updates == nil {
            updates = Task { [weak self] in
                for await update in Transaction.updates {
                    guard case .verified(let transaction) = update else { continue }
                    await self?.finish(transaction)
                }
            }
        }
        // A tip bought on a version that crashed before finishing it.
        for await entry in Transaction.unfinished {
            if case .verified(let transaction) = entry { await finish(transaction) }
        }
        await loadProducts()
    }

    func loadProducts() async {
        guard products.isEmpty else { return }
        do {
            products = try await Product.products(for: Self.productIDs).sorted { $0.price < $1.price }
        } catch {
            products = [] // Offline or no products yet: the section stays hidden.
        }
    }

    func purchase(_ product: Product) async throws -> PurchaseResult {
        purchasing = product.id
        defer { purchasing = nil }
        switch try await product.purchase() {
        case .success(.verified(let transaction)):
            await finish(transaction)
            return .thanked
        case .success(.unverified(let transaction, let error)):
            await transaction.finish() // Never charge twice for a tip that can't be checked.
            throw error
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    private func finish(_ transaction: Transaction) async {
        guard Self.productIDs.contains(transaction.productID) else { return }
        await transaction.finish()
        tipCount += 1
        defaults.set(tipCount, forKey: Self.tipCountKey)
    }

    private static let tipCountKey = "tipJar.tipCount"
}
