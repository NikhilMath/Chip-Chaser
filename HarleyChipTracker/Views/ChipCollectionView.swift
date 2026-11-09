import SwiftData
import SwiftUI

enum CollectionSort: String, CaseIterable, Identifiable {
    case recent, name, region

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "Recently Collected"
        case .name: "A to Z"
        case .region: "By State"
        }
    }

    var symbol: String {
        switch self {
        case .recent: "clock"
        case .name: "textformat"
        case .region: "map"
        }
    }
}

/// The digital collection: every chip the collector has, with its photo.
struct ChipCollectionView: View {
    @Environment(AppModel.self) private var app
    @Query private var records: [ChipRecord]
    @Query private var customDealers: [CustomDealer]

    @State private var sort = CollectionSort.recent
    @State private var searchText = ""
    @State private var scanning = false

    var body: some View {
        let status = CollectionStatus(records: records)
        let collected = app.trackedDealers(custom: customDealers, status: status).filter { status.isCollected($0.id) }
        let visible = sorted(collected.filter { $0.matches(search: searchText) })
        let photoCount = collected.reduce(0) { $0 + (app.photos.hasPhoto(for: $1.id) ? 1 : 0) }

        NavigationStack {
            Group {
                if collected.isEmpty {
                    emptyCollection
                } else {
                    ScrollView {
                        grid(collected: collected, visible: visible, photoCount: photoCount, status: status)
                    }
                    .overlay {
                        if visible.isEmpty { ContentUnavailableView.search(text: searchText) }
                    }
                }
            }
            .navigationTitle("Collection")
            .searchable(text: $searchText, prompt: "Dealer, city, or state")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(CollectionSort.allCases) { option in
                                Label(option.title, systemImage: option.symbol).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        scanning = true
                    } label: {
                        Label("Add from Photo", systemImage: "camera.viewfinder")
                    }
                }
            }
            .navigationDestination(for: Dealer.self) { dealer in
                DealerDetailView(dealer: dealer)
            }
            .sheet(isPresented: $scanning) {
                ChipScannerView()
            }
            #if DEBUG
            .onAppear {
                if DebugLaunch.scanImage != nil { scanning = true }
            }
            #endif
        }
    }

    private func grid(collected: [Dealer], visible: [Dealer], photoCount: Int, status: CollectionStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(summary(chips: collected.count, photos: photoCount))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if photoCount == 0 && searchText.isEmpty {
                photoTip.padding(.horizontal)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 12)], spacing: 18) {
                ForEach(visible) { dealer in
                    NavigationLink(value: dealer) {
                        CollectionCell(dealer: dealer, quantity: status.quantity(for: dealer.id))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private var photoTip: some View {
        Button {
            scanning = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "camera.viewfinder")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Photograph your chips")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Snap a chip or a few at once. Chip Chaser reads each dealer and saves the photo here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var emptyCollection: some View {
        ContentUnavailableView {
            Label("No Chips Yet", systemImage: "circle.grid.2x2")
        } description: {
            Text("Take a photo of your chips and Chip Chaser adds them here, or mark chips on the map and dealer list.")
        } actions: {
            Button {
                scanning = true
            } label: {
                Label("Add from Photo", systemImage: "camera.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
        }
    }

    private func summary(chips: Int, photos: Int) -> String {
        let chipText = chips == 1 ? "1 chip" : "\(chips) chips"
        let photoText = photos == 1 ? "1 photo" : "\(photos) photos"
        return "\(chipText) · \(photoText)"
    }

    private func sorted(_ dealers: [Dealer]) -> [Dealer] {
        switch sort {
        case .recent:
            var dates: [String: Date] = [:]
            for record in records where record.isCollected {
                let date = record.collectedAt ?? .distantPast
                dates[record.dealerID] = max(dates[record.dealerID] ?? .distantPast, date)
            }
            return dealers.sorted {
                let lhs = dates[$0.id] ?? .distantPast, rhs = dates[$1.id] ?? .distantPast
                return lhs != rhs ? lhs > rhs : Dealer.byName($0, $1)
            }
        case .name:
            return dealers.sorted(by: Dealer.byName)
        case .region:
            return RegionGroup.make(from: dealers).flatMap(\.dealers)
        }
    }
}

/// One chip in the collection grid.
private struct CollectionCell: View {
    let dealer: Dealer
    let quantity: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChipPhotoView(dealerID: dealer.id)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if quantity > 1 {
                        Text("×\(quantity)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(dealer.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                Text(dealer.cityLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(quantity > 1 ? "\(dealer.name), \(dealer.cityLine), \(quantity) owned" : "\(dealer.name), \(dealer.cityLine)")
    }
}

#Preview {
    ChipCollectionView()
        .environment(AppModel())
        .modelContainer(.preview)
}
