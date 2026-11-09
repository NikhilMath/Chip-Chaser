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
    @AppStorage("map.filter") private var filter: ChipFilter = .all
    @State private var centeredOnUser = false
    /// What the map shows right now, for grouping pins that would overlap.
    @State private var visibleRegion = ChipMapView.centralUS
    @State private var mapSize = CGSize(width: 390, height: 760)

    /// Where the map starts before a location fix arrives.
    static let centralUS = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.0, longitude: -95.5),
        span: MKCoordinateSpan(latitudeDelta: 22, longitudeDelta: 24)
    )

    var body: some View {
        let status = CollectionStatus(records: records)
        let tracked = app.trackedDealers(custom: customDealers, status: status)
        let pins = tracked.filter {
            $0.coordinate != nil && filter.includes(collected: status.isCollected($0.id))
        }

        let marks = MapCluster.make(pins, status: status, in: visibleRegion, mapSize: mapSize, keepSeparate: selectedID)

        Map(position: $position, selection: $selectedID) {
            UserAnnotation()
            ForEach(marks) { mark in
                if let dealer = mark.single {
                    let selected = selectedID == dealer.id
                    Annotation(dealer.name, coordinate: mark.coordinate, anchor: .center) {
                        ChipIcon(collected: mark.collected > 0, size: selected ? 34 : 22, opaque: true)
                            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                            .animation(.snappy, value: selected)
                    }
                    .annotationTitles(.hidden)
                    .tag(dealer.id)
                } else {
                    Annotation("\(mark.dealers.count) locations", coordinate: mark.coordinate, anchor: .center) {
                        ClusterBubble(count: mark.dealers.count, collected: mark.collected)
                            .onTapGesture {
                                withAnimation { position = .region(mark.region) }
                            }
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { mapSize = $0 }
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

/// Several locations too close together to show apart: how many, and how many are collected.
private struct ClusterBubble: View {
    let count: Int
    let collected: Int

    var body: some View {
        let size: CGFloat = count >= 10 ? 40 : 34
        ZStack {
            Circle().fill(Color(.systemGray))
            Circle().strokeBorder(Color.white.opacity(0.92), lineWidth: 3)
            Circle()
                .trim(from: 0, to: Double(collected) / Double(max(count, 1)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                .rotationEffect(.degrees(-90))
                .padding(1.5)
            Text("\(count)")
                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) locations, \(collected) collected")
        .accessibilityHint("Double-tap to zoom in")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    ChipMapView()
        .environment(AppModel())
        .modelContainer(.preview)
}
