import CoreLocation
import SwiftData
import SwiftUI

enum DealerSort: String, CaseIterable, Identifiable {
    case region, name, nearest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .region: "By State"
        case .name: "A to Z"
        case .nearest: "Nearest"
        }
    }

    var symbol: String {
        switch self {
        case .region: "map"
        case .name: "textformat"
        case .nearest: "location"
        }
    }
}

/// Every tracked location, searchable and filterable by collected / missing.
struct DealerListView: View {
    @Environment(AppModel.self) private var app
    @Query private var records: [ChipRecord]
    @Query(sort: \CustomDealer.createdAt) private var customDealers: [CustomDealer]

    @State private var searchText = ""
    @State private var filter: ChipFilter = .all
    @State private var sort: DealerSort = .region
    @State private var showingAddStore = false
    @State private var path: [Dealer] = []

    var body: some View {
        let status = CollectionStatus(records: records)
        let tracked = app.trackedDealers(custom: customDealers, status: status)
        let visible = tracked.filter {
            filter.includes(collected: status.isCollected($0.id)) && $0.matches(search: searchText)
        }

        NavigationStack(path: $path) {
            List {
                Section {
                    Picker("Show", selection: $filter) {
                        ForEach(ChipFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(summary(visibleCount: visible.count, tracked: tracked, status: status))
                }

                content(visible: visible, tracked: tracked, status: status)
            }
            .overlay {
                if visible.isEmpty { emptyState }
            }
            .navigationTitle("Dealers")
            .searchable(text: $searchText, prompt: "Dealer, city, state, or ZIP")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(DealerSort.allCases) { option in
                                Label(option.title, systemImage: option.symbol).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddStore = true
                    } label: {
                        Label("Add Store", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: Dealer.self) { dealer in
                DealerDetailView(dealer: dealer)
            }
            .sheet(isPresented: $showingAddStore) {
                AddDealerView()
            }
            .task(id: sort) {
                if sort == .nearest { app.location.refresh() }
            }
            #if DEBUG
            .onAppear {
                if path.isEmpty, let id = DebugLaunch.dealerID, let dealer = app.dealer(id: id, custom: customDealers) {
                    path = [dealer]
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private func content(visible: [Dealer], tracked: [Dealer], status: CollectionStatus) -> some View {
        switch sort {
        case .region:
            let totals = regionTotals(tracked, status: status)
            ForEach(RegionGroup.make(from: visible)) { group in
                Section {
                    ForEach(group.dealers) { dealer in
                        DealerLink(dealer: dealer, quantity: status.quantity(for: dealer.id))
                    }
                } header: {
                    RegionHeader(name: group.name,
                                 collected: totals[group.key]?.collected ?? 0,
                                 total: totals[group.key]?.total ?? 0)
                }
            }

        case .name:
            Section {
                ForEach(visible.sorted(by: Dealer.byName)) { dealer in
                    DealerLink(dealer: dealer, quantity: status.quantity(for: dealer.id))
                }
            }

        case .nearest:
            if let here = app.location.location {
                let sorted = visible
                    .map { ($0, $0.location.map(here.distance(from:))) }
                    .sorted { ($0.1 ?? .greatestFiniteMagnitude) < ($1.1 ?? .greatestFiniteMagnitude) }
                Section {
                    ForEach(sorted, id: \.0.id) { dealer, distance in
                        DealerLink(dealer: dealer, quantity: status.quantity(for: dealer.id), distance: distance)
                    }
                }
            } else {
                Section {
                    if app.location.isDenied {
                        Label("Location access is off. Turn it on in the Settings app to sort by distance.",
                              systemImage: "location.slash")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Finding your location…", systemImage: "location")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(visible.sorted(by: Dealer.byName)) { dealer in
                        DealerLink(dealer: dealer, quantity: status.quantity(for: dealer.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if filter == .missing {
            ContentUnavailableView("Nothing Missing", systemImage: "checkmark.seal.fill",
                                   description: Text("You've collected every chip on your list."))
        } else if filter == .collected {
            ContentUnavailableView("No Chips Yet", systemImage: "circle.dashed",
                                   description: Text("Tap the chip next to a dealer to mark it collected."))
        }
    }

    private func summary(visibleCount: Int, tracked: [Dealer], status: CollectionStatus) -> String {
        let collected = status.collectedCount(in: tracked)
        let shown = visibleCount == 1 ? "1 location" : "\(visibleCount) locations"
        return "\(shown) · \(collected) of \(tracked.count) collected"
    }

    private func regionTotals(_ dealers: [Dealer], status: CollectionStatus) -> [RegionKey: (collected: Int, total: Int)] {
        var totals: [RegionKey: (collected: Int, total: Int)] = [:]
        for dealer in dealers {
            var entry = totals[dealer.regionKey] ?? (0, 0)
            entry.total += 1
            if status.isCollected(dealer.id) { entry.collected += 1 }
            totals[dealer.regionKey] = entry
        }
        return totals
    }
}

#Preview {
    DealerListView()
        .environment(AppModel())
        .modelContainer(.preview)
}
