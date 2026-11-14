import SwiftData
import SwiftUI

@main
struct HarleyChipTrackerApp: App {
    @State private var model: AppModel
    @State private var cloudAccount = CloudAccount()
    @State private var tipJar = TipJar()
    private let container: ModelContainer

    init() {
        container = Self.makeContainer()
        _model = State(initialValue: AppModel(photos: Self.usesDemoData ? .demo : ChipPhotoStore()))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(cloudAccount)
                .environment(tipJar)
                .cloudSyncMaintenance(account: cloudAccount)
                .automaticBackups(enabled: !Self.usesDemoData)
                .task {
                    if !Self.usesDemoData { await DealerListUpdate.refreshIfDue() }
                }
                .task { await tipJar.start() }
        }
        .modelContainer(container)
    }

    /// Demo data lives in memory and must never end up in the collector's automatic backups.
    private static var usesDemoData: Bool {
        #if DEBUG
        DebugLaunch.demoData
        #else
        false
        #endif
    }

    private static func makeContainer() -> ModelContainer {
        #if DEBUG
        // `-demoData YES` runs against an in-memory sample collection (screenshots, demos).
        if DebugLaunch.demoData { return .preview }
        // Pushes the model to CloudKit's development environment once (or on `-initCloudKitSchema YES`).
        let forceSchema = DebugLaunch.initCloudKitSchema
        Task.detached(priority: .utility) { CloudSync.initializeSchemaIfNeeded(force: forceSchema) }
        #endif
        return CloudSync.makeContainer()
    }
}

#if DEBUG
/// Debug-only launch arguments, e.g. `-demoData YES -debugTab collection -debugDealer hd-1069`.
enum DebugLaunch {
    static var demoData: Bool { UserDefaults.standard.bool(forKey: "demoData") }
    static var initCloudKitSchema: Bool { UserDefaults.standard.bool(forKey: "initCloudKitSchema") }
    static var tab: AppTab? { UserDefaults.standard.string(forKey: "debugTab").flatMap(AppTab.init(rawValue:)) }
    static var dealerID: String? { UserDefaults.standard.string(forKey: "debugDealer") }
    /// Opens Collection's photo scanner on this image file.
    static var scanImage: String? { UserDefaults.standard.string(forKey: "debugScanImage") }
    /// With `-debugTab settings`: imports this backup file as if picked in Import Backup.
    static var importBackup: String? { UserDefaults.standard.string(forKey: "debugImportBackup") }
    static var scanAutoAdd: Bool { UserDefaults.standard.bool(forKey: "debugScanAdd") }
}
#endif
