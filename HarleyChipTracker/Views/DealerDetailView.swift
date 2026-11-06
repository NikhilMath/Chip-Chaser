import MapKit
import SwiftData
import SwiftUI

/// One location: mark the chip, count extras, keep notes, and get directions.
struct DealerDetailView: View {
    let dealer: Dealer

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Query private var records: [ChipRecord]
    @Query private var customDealers: [CustomDealer]
    @State private var confirmingDelete = false

    init(dealer: Dealer) {
        self.dealer = dealer
        let id = dealer.id
        _records = Query(filter: #Predicate<ChipRecord> { $0.dealerID == id })
    }

    private var record: ChipRecord? { records.first }
    private var quantity: Int { record?.quantity ?? 0 }
    private var collected: Bool { quantity > 0 }

    var body: some View {
        Form {
            header

            Section("My Chip") {
                Toggle("Collected", isOn: Binding(
                    get: { collected },
                    set: { newValue in
                        withAnimation(.snappy) { context.setCollected(newValue, dealerID: dealer.id) }
                    }
                ))

                if collected, let record {
                    DatePicker("Collected on",
                               selection: Binding(get: { record.collectedAt ?? .now },
                                                  set: { record.collectedAt = $0 }),
                               in: ...Date.now,
                               displayedComponents: .date)

                    Stepper(value: Binding(get: { record.quantity }, set: { record.quantity = max(1, $0) }),
                            in: 1...99) {
                        LabeledContent("Chips owned", value: "\(record.quantity)")
                    }

                    if record.quantity > 1 {
                        Label(record.quantity == 2 ? "1 extra to trade" : "\(record.quantity - 1) extras to trade",
                              systemImage: "arrow.left.arrow.right")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("Notes: chip color, who you traded with…", text: notesBinding, axis: .vertical)
                    .lineLimit(2...6)
            }

            visitSection

            if let coordinate = dealer.coordinate {
                Section {
                    Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
                                                                    latitudinalMeters: 2_500,
                                                                    longitudinalMeters: 2_500)),
                        interactionModes: []) {
                        Marker(dealer.name, systemImage: dealer.kind.symbol, coordinate: coordinate)
                            .tint(collected ? Color.accentColor : .gray)
                    }
                    .frame(height: 190)
                    .listRowInsets(EdgeInsets())
                    .onTapGesture {
                        if let url = dealer.mapsURL { openURL(url) }
                    }
                    .accessibilityLabel("Map of \(dealer.name). Opens in Maps.")
                }
            }

            if dealer.kind == .custom {
                Section {
                    Button("Delete Store", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
        .navigationTitle(dealer.name)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: collected) { _, isCollected in isCollected }
        .confirmationDialog("Delete \(dealer.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Store", role: .destructive, action: deleteCustomStore)
        } message: {
            Text("This removes the store and its chip from your collection.")
        }
    }

    private var header: some View {
        Section {
            VStack(spacing: 10) {
                Button {
                    withAnimation(.snappy) { context.setCollected(!collected, dealerID: dealer.id) }
                } label: {
                    ChipIcon(collected: collected, size: 104)
                        .shadow(color: .black.opacity(collected ? 0.25 : 0), radius: 8, y: 4)
                        .scaleEffect(collected ? 1 : 0.94)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(collected ? "Collected" : "Missing")
                .accessibilityHint("Double-tap to toggle")
                Text(dealer.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(dealer.cityLine.isEmpty ? dealer.regionName : "\(dealer.city), \(dealer.regionName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label(dealer.kind.label, systemImage: dealer.kind.symbol)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                Text(collected ? "Tap the chip to mark it missing" : "Tap the chip when you get it")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var visitSection: some View {
        let parent = dealer.parentId.flatMap { app.directory.dealer(id: $0) }
        if dealer.mapsURL != nil || dealer.phoneURL != nil || dealer.websiteURL != nil || parent != nil {
            Section("Visit") {
                if let url = dealer.mapsURL, dealer.address != nil || dealer.coordinate != nil {
                    Link(destination: url) {
                        Label {
                            Text(dealer.fullAddress).foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "map")
                        }
                    }
                }
                if let phone = dealer.phone, let url = dealer.phoneURL {
                    Link(destination: url) {
                        Label { Text(phone).foregroundStyle(.primary) } icon: { Image(systemName: "phone") }
                    }
                }
                if let url = dealer.websiteURL {
                    Link(destination: url) {
                        Label {
                            Text(url.host() ?? url.absoluteString).foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "safari")
                        }
                    }
                }
                if let parent {
                    NavigationLink(value: parent) {
                        LabeledContent("Run by", value: parent.name)
                    }
                }
            }
        }
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { record?.notes ?? "" },
            set: { newValue in
                if let record {
                    record.notes = newValue
                } else if !newValue.isEmpty {
                    context.ensureChipRecord(for: dealer.id).notes = newValue
                }
            }
        )
    }

    private func deleteCustomStore() {
        guard let store = customDealers.first(where: { $0.dealerID == dealer.id }) else { return }
        context.deleteCustomDealer(store)
        dismiss()
    }
}

#Preview {
    NavigationStack {
        DealerDetailView(dealer: DealerDirectory.shared.dealers.first ?? .sample)
    }
    .environment(AppModel())
    .modelContainer(.preview)
}
