import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// What to track, iCloud status, backup/restore, and about.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(CloudAccount.self) private var cloudAccount
    @Environment(\.modelContext) private var context
    @Query private var records: [ChipRecord]
    @Query(sort: \CustomDealer.createdAt) private var customDealers: [CustomDealer]

    @State private var importing = false
    @State private var confirmingReset = false
    @State private var message: AlertMessage?

    var body: some View {
        @Bindable var app = app
        let counts = Dictionary(grouping: app.directory.dealers, by: \.kind).mapValues(\.count)
        let canadaCount = app.directory.dealers.filter { $0.country == "CA" }.count

        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $app.includeCanada) {
                        Label("Canadian Locations (\(canadaCount))", systemImage: "leaf")
                    }
                    Toggle(isOn: $app.includeSatellites) {
                        Label("Satellite Stores (\(counts[.satellite] ?? 0))", systemImage: DealerKind.satellite.symbol)
                    }
                    Toggle(isOn: $app.includeShops) {
                        Label("Apparel & Gift Shops (\(counts[.shop] ?? 0))", systemImage: DealerKind.shop.symbol)
                    }
                } header: {
                    Text("What to Track")
                } footer: {
                    Text("Turn off kinds of locations you don't collect. Chips you've already marked are kept and come back if you turn them on again.")
                }

                Section {
                    LabeledContent {
                        Text(cloudAccount.status.title)
                    } label: {
                        Label("iCloud Sync", systemImage: cloudAccount.status.symbol)
                    }
                } header: {
                    Text("Your Apple ID")
                } footer: {
                    Text(cloudAccount.status.explanation)
                }

                Section {
                    ShareLink(item: CollectionExport(backup: CollectionBackup(records: records, customDealers: customDealers),
                                                     photoFiles: app.photos.photoFiles),
                              preview: SharePreview("Chip Chaser Backup", image: Image(systemName: "doc.text"))) {
                        Label("Export Backup", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        importing = true
                    } label: {
                        Label("Import Backup", systemImage: "square.and.arrow.down")
                    }
                    NavigationLink {
                        AutomaticBackupsView()
                    } label: {
                        Label("Automatic Backups", systemImage: "clock.arrow.circlepath")
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Chip Chaser also saves a copy on this iPhone each day you use it, including one from before every update. Export a backup to keep your own copy in Files, or AirDrop it to a phone on a different Apple ID. An exported backup includes your chip photos; iCloud sync and the daily copies don't, so on a second iPhone, import a backup to bring the photos over.")
                }

                Section {
                    Button(role: .destructive) {
                        confirmingReset = true
                    } label: {
                        Label("Reset Collection", systemImage: "trash")
                    }
                }

                Section("About") {
                    LabeledContent("Locations in List", value: "\(app.directory.dealers.count)")
                    LabeledContent("List Updated", value: app.directory.generatedDisplay)
                    LabeledContent("Version", value: Bundle.main.versionString)
                    Text("Location data comes from Harley-Davidson's public dealer locator, and the list refreshes itself between app updates. Chip Chaser is an independent collector's app and is not affiliated with, sponsored by, or endorsed by Harley-Davidson.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
            .navigationTitle("Settings")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                importBackup(result)
            }
            .confirmationDialog("Reset your collection?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Erase All Chips and Stores", role: .destructive, action: reset)
            } message: {
                Text("This deletes every chip you've marked, your notes, and stores you added, on this iPhone and in iCloud. Automatic backups on this iPhone are kept, so you can restore them from Settings. Your chip photos are kept too.")
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
    }

    private func importBackup(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let backup = try CollectionBackup.decoder.decode(CollectionBackup.self, from: data)
            let restored = try backup.restore(into: context)
            let photos = backup.restorePhotos(into: app.photos)
            var body = "Restored \(restored) collected chips and \(backup.customStores.count) added stores."
            if photos > 0 { body += photos == 1 ? " Added 1 chip photo." : " Added \(photos) chip photos." }
            body += " Nothing you've marked since was changed."
            message = AlertMessage(title: "Backup Imported", body: body)
        } catch is DecodingError {
            message = AlertMessage(title: "Couldn't Import", body: "That file isn't a Chip Chaser backup.")
        } catch {
            message = AlertMessage(title: "Couldn't Import", body: error.localizedDescription)
        }
    }

    private func reset() {
        do {
            try context.resetCollection()
        } catch {
            message = AlertMessage(title: "Couldn't Reset", body: error.localizedDescription)
        }
    }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

extension Bundle {
    var versionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
        .environment(CloudAccount())
        .modelContainer(.preview)
}
