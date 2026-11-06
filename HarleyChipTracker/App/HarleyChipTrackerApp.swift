import SwiftData
import SwiftUI

@main
struct HarleyChipTrackerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .modelContainer(for: [ChipRecord.self, CustomDealer.self])
    }
}
