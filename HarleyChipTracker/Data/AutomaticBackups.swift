import Foundation
import SwiftData
import SwiftUI

/// Copies of the collection the app saves on the iPhone by itself, as a safety net for updates.
///
/// There's one file per day and per app version (`2026-11-08 1.1 (5).json`), so the copy saved
/// before an update is never overwritten by one saved after it. The newest `limit` files are kept.
/// An empty collection is never saved, so a reset, or anything else that empties the store,
/// can't push out a good copy. Restoring uses the same merge as importing a backup file.
nonisolated struct AutomaticBackups: Sendable {
    struct Entry: Identifiable, Hashable, Sendable {
        let url: URL
        let savedAt: Date
        /// The app version that saved it, e.g. "1.1 (5)".
        let appVersion: String
        let chipCount: Int
        let storeCount: Int

        var id: URL { url }

        var summary: String {
            var parts = [chipCount == 1 ? "1 chip" : "\(chipCount) chips"]
            if storeCount > 0 { parts.append(storeCount == 1 ? "1 added store" : "\(storeCount) added stores") }
            if !appVersion.isEmpty { parts.append("version \(appVersion)") }
            return parts.joined(separator: " · ")
        }
    }

    let directory: URL
    var limit = 14

    static let shared = AutomaticBackups(
        directory: URL.applicationSupportDirectory.appending(path: "Automatic Backups", directoryHint: .isDirectory)
    )

    /// Saves the collection, replacing today's copy from the same app version. Returns nil
    /// (and saves nothing) when the collection is empty.
    @discardableResult
    func save(_ backup: CollectionBackup, appVersion: String) throws -> URL? {
        guard !backup.chips.isEmpty || !backup.customStores.isEmpty else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: Self.fileName(day: backup.exportedAt, appVersion: appVersion))
        try CollectionBackup.encoder.encode(backup).write(to: url, options: .atomic)
        try prune()
        return url
    }

    /// Every saved copy, newest first. Unreadable files are skipped.
    func entries() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Entry? in
                guard let backup = try? load(url) else { return nil }
                return Entry(url: url, savedAt: backup.exportedAt, appVersion: Self.appVersion(fromFileName: url),
                             chipCount: backup.chips.filter { $0.quantity > 0 }.count,
                             storeCount: backup.customStores.count)
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func load(_ url: URL) throws -> CollectionBackup {
        try CollectionBackup.decoder.decode(CollectionBackup.self, from: Data(contentsOf: url))
    }

    func delete(_ entry: Entry) throws {
        try FileManager.default.removeItem(at: entry.url)
    }

    /// Keeps the newest `limit` copies.
    func prune() throws {
        for entry in entries().dropFirst(limit) {
            try FileManager.default.removeItem(at: entry.url)
        }
    }

    static func fileName(day: Date, appVersion: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let version = appVersion.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(formatter.string(from: day)) \(version).json"
    }

    /// "2026-11-08 1.1 (5).json" → "1.1 (5)".
    static func appVersion(fromFileName url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        guard let space = name.firstIndex(of: " ") else { return "" }
        return String(name[name.index(after: space)...])
    }
}

extension View {
    /// Saves an automatic backup when the app opens and whenever it goes to the background.
    func automaticBackups(enabled: Bool = true) -> some View {
        modifier(AutomaticBackupSaver(enabled: enabled))
    }
}

private struct AutomaticBackupSaver: ViewModifier {
    let enabled: Bool
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task { save() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { save() }
            }
    }

    private func save() {
        guard enabled else { return }
        do {
            let backup = CollectionBackup(records: try context.fetch(FetchDescriptor<ChipRecord>()),
                                          customDealers: try context.fetch(FetchDescriptor<CustomDealer>()))
            try AutomaticBackups.shared.save(backup, appVersion: Bundle.main.versionString)
        } catch {
            print("Couldn't save the automatic backup: \(error)")
        }
    }
}

/// Settings → Automatic Backups: the copies saved on this iPhone, newest first. Tap one to restore it.
struct AutomaticBackupsView: View {
    @Environment(\.modelContext) private var context
    @State private var entries: [AutomaticBackups.Entry] = []
    @State private var pending: AutomaticBackups.Entry?
    @State private var message: AlertMessage?

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    Button {
                        pending = entry
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.savedAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.primary)
                            Text(entry.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for entry in offsets.map({ entries[$0] }) { try? AutomaticBackups.shared.delete(entry) }
                    entries = AutomaticBackups.shared.entries()
                }
            } footer: {
                if !entries.isEmpty {
                    Text("Saved on this iPhone each day you use Chip Chaser, with a separate copy for each app version, so there's always one from before an update. Restoring puts those chips back. Chips you've marked since stay marked.")
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No Automatic Backups Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Chip Chaser saves a copy of your collection on this iPhone each day you use it."))
            }
        }
        .navigationTitle("Automatic Backups")
        .navigationBarTitleDisplayMode(.inline)
        .task { entries = AutomaticBackups.shared.entries() }
        .confirmationDialog("Restore this backup?", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible, presenting: pending) { entry in
            Button("Restore \(entry.chipCount == 1 ? "1 Chip" : "\(entry.chipCount) Chips")") { restore(entry) }
        } message: { entry in
            Text("Saved \(entry.savedAt.formatted(date: .abbreviated, time: .shortened)): \(entry.summary). Chips you've marked since stay marked.")
        }
        .alert(message?.title ?? "", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        ), presenting: message) { _ in
            Button("OK") {}
        } message: { message in
            Text(message.body)
        }
    }

    private func restore(_ entry: AutomaticBackups.Entry) {
        do {
            let backup = try AutomaticBackups.shared.load(entry.url)
            let restored = try backup.restore(into: context)
            message = AlertMessage(title: "Backup Restored",
                                   body: "Restored \(restored) collected chips and \(backup.customStores.count) added stores.")
        } catch {
            message = AlertMessage(title: "Couldn't Restore", body: error.localizedDescription)
        }
    }
}
