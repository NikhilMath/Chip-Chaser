import SwiftData
import SwiftUI

/// Overall progress, per-state progress, recent finds, and shareable lists.
struct CollectionStatsView: View {
    @Environment(AppModel.self) private var app
    @Query private var records: [ChipRecord]
    @Query private var customDealers: [CustomDealer]

    var body: some View {
        let status = CollectionStatus(records: records)
        let tracked = app.trackedDealers(custom: customDealers, status: status)
        let collected = status.collectedCount(in: tracked)
        let groups = RegionGroup.make(from: tracked)
        let completeStates = groups.filter { group in group.dealers.allSatisfy { status.isCollected($0.id) } }.count
        let trackedIDs = Set(tracked.map(\.id))
        let recent = records
            .filter { $0.isCollected && trackedIDs.contains($0.dealerID) }
            .sorted { ($0.collectedAt ?? .distantPast) > ($1.collectedAt ?? .distantPast) }
            .prefix(5)
            .compactMap { record in app.dealer(id: record.dealerID, custom: customDealers).map { ($0, record.collectedAt) } }

        NavigationStack {
            List {
                Section {
                    ProgressRing(collected: collected, total: tracked.count)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                }

                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatTile(value: tracked.count - collected, label: "Missing", symbol: "circle.dashed")
                        StatTile(value: status.extrasCount(in: tracked), label: "Extras to Trade", symbol: "arrow.left.arrow.right")
                        StatTile(value: completeStates, label: "States Complete", symbol: "checkmark.seal.fill")
                        StatTile(value: groups.count, label: "States & Provinces", symbol: "map")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if !recent.isEmpty {
                    Section("Recently Collected") {
                        ForEach(recent, id: \.0.id) { dealer, date in
                            NavigationLink(value: dealer) {
                                HStack(spacing: 12) {
                                    ChipIcon(collected: true, size: 30)
                                    VStack(alignment: .leading) {
                                        Text(dealer.name).font(.subheadline.weight(.semibold))
                                        Text(dealer.cityLine).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let date {
                                        Text(date, format: .dateTime.month(.abbreviated).day())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("By State & Province") {
                    ForEach(groups) { group in
                        let count = status.collectedCount(in: group.dealers)
                        NavigationLink(value: group.key) {
                            RegionProgressRow(name: group.name, collected: count, total: group.dealers.count)
                        }
                    }
                }
            }
            .navigationTitle("Progress")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ShareLink(item: CollectionReport.missingList(dealers: tracked, status: status)) {
                            Label("Share Missing List", systemImage: "circle.dashed")
                        }
                        ShareLink(item: CollectionReport.extrasList(dealers: tracked, status: status)) {
                            Label("Share Extras for Trade", systemImage: "arrow.left.arrow.right")
                        }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationDestination(for: RegionKey.self) { key in
                RegionDealersView(regionKey: key)
            }
            .navigationDestination(for: Dealer.self) { dealer in
                DealerDetailView(dealer: dealer)
            }
        }
    }
}

/// The big ring at the top of Progress.
struct ProgressRing: View {
    let collected: Int
    let total: Int

    private var fraction: Double { total == 0 ? 0 : Double(collected) / Double(total) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemFill), lineWidth: 22)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 22, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: fraction)
            VStack(spacing: 2) {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("\(collected) of \(total) chips")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 210, height: 210)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(collected) of \(total) chips collected")
    }
}

struct StatTile: View {
    let value: Int
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(Color.accentColor)
            Text("\(value)")
                .font(.title.weight(.bold).monospacedDigit())
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct RegionProgressRow: View {
    let name: String
    let collected: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                if collected == total && total > 0 {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Complete")
                }
                Spacer()
                Text("\(collected)/\(total)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(collected), total: Double(max(total, 1)))
                .tint(Color.accentColor)
        }
        .padding(.vertical, 2)
    }
}

/// All tracked locations in one state or province.
struct RegionDealersView: View {
    let regionKey: RegionKey

    @Environment(AppModel.self) private var app
    @Query private var records: [ChipRecord]
    @Query private var customDealers: [CustomDealer]

    var body: some View {
        let status = CollectionStatus(records: records)
        let dealers = app.trackedDealers(custom: customDealers, status: status)
            .filter { $0.regionKey == regionKey }
            .sorted(by: Dealer.byName)
        let collected = status.collectedCount(in: dealers)

        List {
            Section {
                RegionProgressRow(name: "\(collected) of \(dealers.count) collected", collected: collected, total: dealers.count)
            }
            Section {
                ForEach(dealers) { dealer in
                    DealerLink(dealer: dealer, quantity: status.quantity(for: dealer.id))
                }
            }
        }
        .navigationTitle(regionKey.name)
        .overlay {
            if dealers.isEmpty {
                ContentUnavailableView("No Locations", systemImage: "mappin.slash",
                                       description: Text("Nothing is tracked here with your current settings."))
            }
        }
    }
}

#Preview {
    CollectionStatsView()
        .environment(AppModel())
        .modelContainer(.preview)
}
