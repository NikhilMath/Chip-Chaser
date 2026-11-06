import CoreLocation
import SwiftData
import SwiftUI

/// One dealer in a list: tap the chip to mark it, tap the row for details.
struct DealerRow: View {
    let dealer: Dealer
    let quantity: Int
    var distance: CLLocationDistance?
    var onToggle: () -> Void

    private var collected: Bool { quantity > 0 }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                ChipIcon(collected: collected, size: 38)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(collected ? "Collected" : "Missing")
            .accessibilityHint(collected ? "Marks this chip as missing" : "Marks this chip as collected")

            VStack(alignment: .leading, spacing: 2) {
                Text(dealer.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(dealer.cityLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if dealer.kind != .dealer {
                    Label(dealer.kind.label, systemImage: dealer.kind.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                if quantity > 1 {
                    Text("×\(quantity)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("\(quantity) owned")
                }
                if let distance {
                    Text(distance.roadDistanceText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .sensoryFeedback(.impact(weight: .light), trigger: collected)
    }
}

/// A `DealerRow` wired to the store, with navigation and swipe-to-mark.
struct DealerLink: View {
    let dealer: Dealer
    let quantity: Int
    var distance: CLLocationDistance?

    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationLink(value: dealer) {
            DealerRow(dealer: dealer, quantity: quantity, distance: distance, onToggle: toggle)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(action: toggle) {
                if quantity > 0 {
                    Label("Missing", systemImage: "circle.dashed")
                } else {
                    Label("Got It", systemImage: "checkmark.circle.fill")
                }
            }
            .tint(quantity > 0 ? .gray : .accentColor)
        }
    }

    private func toggle() {
        withAnimation(.snappy) {
            context.toggleCollected(dealerID: dealer.id)
        }
    }
}

/// Section header like "Wisconsin   12/20", with a seal when the state is complete.
struct RegionHeader: View {
    let name: String
    let collected: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
            Spacer()
            if total > 0 && collected == total {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Complete")
            }
            Text("\(collected)/\(total)")
                .monospacedDigit()
        }
    }
}
