import SwiftData
import SwiftUI

struct RootView: View {
    @SceneStorage("selectedTab") private var selectedTab = AppTab.dealers

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Dealers", systemImage: "list.bullet", value: AppTab.dealers) {
                DealerListView()
            }
            Tab("Map", systemImage: "map", value: AppTab.map) {
                ChipMapView()
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
    case dealers, map, progress, settings
}

#Preview {
    RootView()
        .environment(AppModel())
        .modelContainer(.preview)
}
