import SwiftData
import SwiftUI

struct RootView: View {
    /// The app always opens on the map, the first tab.
    @State private var selectedTab = AppTab.map

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Map", systemImage: "map", value: AppTab.map) {
                ChipMapView()
            }
            Tab("Dealers", systemImage: "list.bullet", value: AppTab.dealers) {
                DealerListView()
            }
            Tab("Progress", systemImage: "chart.pie", value: AppTab.progress) {
                CollectionStatsView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tint(Color.accentColor)
        #if DEBUG
        .onAppear {
            if let tab = DebugLaunch.tab { selectedTab = tab }
        }
        #endif
    }
}

enum AppTab: String {
    case map, dealers, progress, settings
}

#Preview {
    RootView()
        .environment(AppModel())
        .environment(CloudAccount())
        .modelContainer(.preview)
}
