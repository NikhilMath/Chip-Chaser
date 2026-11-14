import StoreKit
import SwiftUI

/// The "Support Chip Chaser" section in Settings. Hidden until the App Store returns the tips.
struct TipJarSection: View {
    @Environment(TipJar.self) private var tipJar
    @State private var message: AlertMessage?

    var body: some View {
        Group {
            if !tipJar.products.isEmpty {
                Section {
                    ForEach(tipJar.products) { product in
                        Button {
                            buy(product)
                        } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(product.displayName)
                                            .foregroundStyle(.primary)
                                        if !product.description.isEmpty {
                                            Text(product.description)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                } icon: {
                                    Image(systemName: symbol(for: product))
                                }
                                Spacer()
                                if tipJar.purchasing == product.id {
                                    ProgressView()
                                } else {
                                    Text(product.displayPrice)
                                        .monospacedDigit()
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .disabled(tipJar.purchasing != nil)
                    }
                } header: {
                    Text("Support Chip Chaser")
                } footer: {
                    Text(footer)
                }
            }
        }
        .task { await tipJar.loadProducts() }
        .alert($message)
    }

    private var footer: String {
        let base = "Chip Chaser is free, with no ads and nothing locked. If it's helped you chase chips, a tip keeps the dealer list fresh and new features coming."
        switch tipJar.tipCount {
        case 0: return base
        case 1: return "Thanks for your tip! " + base
        default: return "Thanks for your \(tipJar.tipCount) tips! " + base
        }
    }

    private func symbol(for product: Product) -> String {
        switch TipJar.productIDs.firstIndex(of: product.id) {
        case 0: "cup.and.saucer"
        case 1: "fuelpump"
        default: "flag.checkered"
        }
    }

    private func buy(_ product: Product) {
        Task {
            do {
                switch try await tipJar.purchase(product) {
                case .thanked:
                    message = AlertMessage(title: "Thank You!", body: "Your tip means a lot. Ride safe and happy chasing.")
                case .pending:
                    message = AlertMessage(title: "Tip Pending", body: "Your tip will go through once it's approved.")
                case .cancelled:
                    break
                }
            } catch {
                message = AlertMessage(title: "Couldn't Send Tip", body: error.localizedDescription)
            }
        }
    }
}
