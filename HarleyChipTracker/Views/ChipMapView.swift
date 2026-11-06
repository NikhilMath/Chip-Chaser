import MapKit
import SwiftData
import SwiftUI

/// Every tracked location on a map: orange for collected, grey for missing.
struct ChipMapView: View {
    @Environment(AppModel.self) private var app
    @Query private var records: [ChipRecord]
    @Query private var customDealers: [CustomDealer]

    @State private var position: MapCameraPosition = .region(ChipMapView.centralUS)
    @State private var selectedID: String?
    @State private var filter: ChipFilter = .all
    @State private var centeredOnUser = false

    /// Where the map starts before a location fix arrives.
    static let centralUS = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.0, longitude: -95.5),
        span: MKCoordinateSpan(latitudeDelta: 22, longitudeDelta: 24)
    )

    var body: some View {
        let status = CollectionStatus(records: records)
        let tracked = app.trackedDealers(custom: customDealers)
        let pins = tracked.filter {
            $0.coordinate != nil && filter.includes(collected: status.isCollected($0.id))
        }

        Map(position: $position, selection: $selectedID) {
            UserAnnotation()
            ForEach(pins) { dealer in
                if let coordinate = dealer.coordinate {
                    let collected = status.isCollected(dealer.id)
                    let selected = selectedID == dealer.id
                    Annotation(dealer.name, coordinate: coordinate, anchor: .center) {
                        ChipIcon(collected: collected, size: selected ? 34 : 22, opaque: true)
                            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                            .animation(.snappy, value: selected)
                    }
                    .annotationTitles(.hidden)
                    .tag(dealer.id)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 6) {
                Picker("Show", selection: $filter) {
                    ForEach(ChipFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("\(status.collectedCount(in: tracked)) of \(tracked.count) collected · \(pins.count) shown")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal)
            .padding(.top, 4)
        }
        .sheet(item: selectedDealer(tracked)) { dealer in
            NavigationStack {
                DealerDetailView(dealer: dealer)
                    .navigationDestination(for: Dealer.self) { DealerDetailView(dealer: $0) }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { selectedID = nil }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task { app.location.refresh() }
        .onChange(of: app.location.location) { _, location in
            // Zoom to the rider's area once, unless they've already moved the map.
            guard let location, !centeredOnUser, !position.positionedByUser else { return }
            centeredOnUser = true
            withAnimation {
                position = .region(MKCoordinateRegion(center: location.coordinate,
                                                      span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 6)))
            }
        }
    }

    private func selectedDealer(_ dealers: [Dealer]) -> Binding<Dealer?> {
        Binding(
            get: { selectedID.flatMap { id in dealers.first { $0.id == id } } },
            set: { selectedID = $0?.id }
        )
    }
}

#Preview {
    ChipMapView()
        .environment(AppModel())
        .modelContainer(.preview)
}
