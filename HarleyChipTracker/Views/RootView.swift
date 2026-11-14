import SwiftData
import SwiftUI

struct RootView: View {
    /// The app always opens on the map, the first tab.
    @State private var selectedTab = AppTab.map
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Map", systemImage: "map", value: AppTab.map) {
                ChipMapView()
            }
            Tab("Dealers", systemImage: "list.bullet", value: AppTab.dealers) {
                DealerListView()
            }
            Tab("Collection", systemImage: "circle.grid.2x2", value: AppTab.collection) {
                ChipCollectionView()
            }
            Tab("Progress", systemImage: "chart.pie", value: AppTab.progress) {
                CollectionStatsView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tint(Color.accentColor)
        .onChange(of: scenePhase) { old, phase in
            // Back from the background, maybe a ride later: distances need a fresh fix.
            if phase == .active && old == .background { app.location.refreshIfAllowed() }
        }
        #if DEBUG
        .onAppear {
            if let tab = DebugLaunch.tab { selectedTab = tab }
        }
        #endif
    }
}

enum AppTab: String {
    case map, dealers, collection, progress, settings
}

#Preview {
    RootView()
        .environment(AppModel())
        .environment(CloudAccount())
        .environment(TipJar())
        .modelContainer(.preview)
}
