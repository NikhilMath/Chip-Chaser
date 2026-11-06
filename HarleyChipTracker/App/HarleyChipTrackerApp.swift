import SwiftData
import SwiftUI

@main
struct HarleyChipTrackerApp: App {
    @State private var model = AppModel()
    private let container: ModelContainer

    init() {
        container = Self.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .modelContainer(container)
    }

    private static func makeContainer() -> ModelContainer {
        #if DEBUG
        // `-demoData YES` runs against an in-memory sample collection (screenshots, demos).
        if DebugLaunch.demoData { return .preview }
        #endif
        do {
            return try ModelContainer(for: ChipRecord.self, CustomDealer.self)
        } catch {
            fatalError("Could not open the collection store: \(error)")
        }
    }
}

#if DEBUG
/// Debug-only launch arguments, e.g. `-demoData YES -debugTab progress -debugDealer hd-1069`.
enum DebugLaunch {
    static var demoData: Bool { UserDefaults.standard.bool(forKey: "demoData") }
    static var tab: AppTab? { UserDefaults.standard.string(forKey: "debugTab").flatMap(AppTab.init(rawValue:)) }
    static var dealerID: String? { UserDefaults.standard.string(forKey: "debugDealer") }
}
#endif
