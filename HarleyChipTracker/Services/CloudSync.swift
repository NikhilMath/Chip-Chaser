import CloudKit
import Combine
import CoreData
import Observation
import SwiftData
import SwiftUI

/// iCloud sync for the collection.
///
/// The SwiftData store mirrors to the private database of the collector's own iCloud account,
/// so there's no in-app sign-in: whoever is signed in to the iPhone with their Apple ID gets
/// their collection saved and synced to their other devices. Nobody else (including the
/// developer) can read it.
enum CloudSync {
    nonisolated static let containerID = "iCloud.com.nikhilmath.HarleyChipTracker"
    static let models: [any PersistentModel.Type] = [ChipRecord.self, CustomDealer.self]
    static var schema: Schema { Schema(models) }

    /// Where every collection lives on the iPhone: SwiftData's default location, where 1.0
    /// saved it. Spelled out so it can never move by accident. A store at any other path
    /// opens empty, and to the collector it looks like an update wiped their chips.
    /// Never change it.
    static var storeURL: URL { URL.applicationSupportDirectory.appending(path: "default.store") }

    /// The app's store, synced through iCloud. Falls back to a local-only store (same file)
    /// if CloudKit can't be set up, so the collection always opens.
    ///
    /// App updates keep this file. To keep it readable, model changes must only add properties
    /// with default values. `UpgradeTests` opens a store saved by 1.0 to prove it.
    static func makeContainer() -> ModelContainer {
        do {
            return try container(at: storeURL, cloudKit: true)
        } catch {
            print("iCloud store unavailable, using local store: \(error)")
        }
        do {
            return try container(at: storeURL, cloudKit: false)
        } catch {
            fatalError("Could not open the collection store: \(error)")
        }
    }

    /// Opens the collection store at `url`, the way the app does.
    static func container(at url: URL, cloudKit: Bool) throws -> ModelContainer {
        let schema = schema
        return try ModelContainer(for: schema, configurations: ModelConfiguration(
            schema: schema, url: url, cloudKitDatabase: cloudKit ? .private(containerID) : .none
        ))
    }

    #if DEBUG
    /// Bump when the models change, so debug builds push the new schema once.
    nonisolated static let schemaVersion = 1

    /// Pushes the model's record types to the CloudKit *development* environment, so they can be
    /// deployed to production in CloudKit Console before shipping a build with model changes.
    /// Debug builds do this once per `schemaVersion` (or every launch with `-initCloudKitSchema YES`).
    nonisolated static func initializeSchemaIfNeeded(force: Bool) {
        let key = "cloudKitSchemaInitialized-v\(schemaVersion)"
        guard force || !UserDefaults.standard.bool(forKey: key) else { return }
        if initializeSchema() { UserDefaults.standard.set(true, forKey: key) }
    }

    @discardableResult
    nonisolated static func initializeSchema() -> Bool {
        let url = URL.temporaryDirectory.appending(path: "schema-init.store")
        let description = NSPersistentStoreDescription(url: url)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerID)
        description.shouldAddStoreAsynchronously = false
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: [ChipRecord.self, CustomDealer.self]) else {
            print("CloudKit schema: couldn't build the managed object model")
            return false
        }
        let container = NSPersistentCloudKitContainer(name: "HarleyChipTracker", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            print("CloudKit schema: store failed to load: \(loadError)")
            return false
        }
        defer {
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }
        }
        do {
            try container.initializeCloudKitSchema()
            print("CloudKit schema: initialized in the development environment")
            return true
        } catch {
            print("CloudKit schema: failed: \(error)")
            return false
        }
    }
    #endif
}

/// Whether this iPhone is signed in to iCloud, for the status row in Settings.
@Observable
final class CloudAccount {
    enum Status {
        case checking, available, noAccount, restricted, temporarilyUnavailable, unknown

        var title: String {
            switch self {
            case .checking: "Checking…"
            case .available: "On"
            case .noAccount: "Not Signed In"
            case .restricted: "Restricted"
            case .temporarilyUnavailable: "Unavailable"
            case .unknown: "Can't Connect"
            }
        }

        var symbol: String {
            switch self {
            case .available: "checkmark.icloud"
            case .checking, .temporarilyUnavailable, .unknown: "icloud"
            case .noAccount, .restricted: "icloud.slash"
            }
        }

        var explanation: String {
            switch self {
            case .checking:
                "Checking your iCloud account…"
            case .available:
                "Your collection is saved to your Apple ID in iCloud and syncs to every iPhone signed in with it. On a new phone, just install the app and your chips come back."
            case .noAccount:
                "To save your collection to iCloud, open the Settings app, sign in with your Apple ID, and make sure iCloud is on for Chip Chaser. Until then, it's saved on this iPhone only."
            case .restricted:
                "iCloud is restricted on this iPhone (Screen Time or device management), so your collection is saved on this iPhone only."
            case .temporarilyUnavailable:
                "iCloud is temporarily unavailable. Your changes are saved on this iPhone and sync when iCloud is back."
            case .unknown:
                "Couldn't reach iCloud. Your changes are saved on this iPhone and sync when it can."
            }
        }
    }

    private(set) var status: Status = .checking

    func refresh() async {
        do {
            switch try await CKContainer(identifier: CloudSync.containerID).accountStatus() {
            case .available: status = .available
            case .noAccount: status = .noAccount
            case .restricted: status = .restricted
            case .temporarilyUnavailable: status = .temporarilyUnavailable
            case .couldNotDetermine: status = .unknown
            @unknown default: status = .unknown
            }
        } catch {
            status = .unknown
        }
    }
}

extension View {
    /// Keeps the iCloud account status current and merges duplicates that sync brings in.
    func cloudSyncMaintenance(account: CloudAccount) -> some View {
        modifier(CloudSyncMaintenance(account: account))
    }
}

private struct CloudSyncMaintenance: ViewModifier {
    let account: CloudAccount
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task {
                await account.refresh()
                merge()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await account.refresh() }
                merge()
            }
            .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged).receive(on: RunLoop.main)) { _ in
                Task { await account.refresh() }
            }
            // Posted when iCloud changes arrive. Wait for the burst to settle, then tidy up.
            .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
                .debounce(for: .seconds(2), scheduler: RunLoop.main)) { _ in
                merge()
            }
    }

    private func merge() {
        do {
            try context.mergeDuplicates()
        } catch {
            print("Couldn't merge duplicate records: \(error)")
        }
    }
}
