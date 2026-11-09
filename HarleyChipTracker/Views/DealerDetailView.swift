import MapKit
import PhotosUI
import SwiftData
import SwiftUI

/// One location: mark the chip, photograph it, count extras, keep notes, and get directions.
struct DealerDetailView: View {
    let dealer: Dealer

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Query private var records: [ChipRecord]
    @Query private var customDealers: [CustomDealer]
    @State private var confirmingDelete = false
    @State private var showingCamera = false
    @State private var showingLibrary = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var showingPhoto = false
    @State private var confirmingRemovePhoto = false
    @State private var confirmingUnmark = false

    init(dealer: Dealer) {
        self.dealer = dealer
        let id = dealer.id
        _records = Query(filter: #Predicate<ChipRecord> { $0.dealerID == id })
    }

    private var record: ChipRecord? { records.first }
    private var quantity: Int { record?.quantity ?? 0 }
    private var collected: Bool { quantity > 0 }
    private var hasPhoto: Bool { app.photos.hasPhoto(for: dealer.id) }

    var body: some View {
        Form {
            header

            Section("My Chip") {
                Toggle("Collected", isOn: Binding(
                    get: { collected },
                    set: { newValue in
                        if newValue {
                            withAnimation(.snappy) { context.setCollected(true, dealerID: dealer.id) }
                        } else {
                            confirmingUnmark = true
                        }
                    }
                ))

                if collected, let record {
                    DatePicker("Collected on",
                               selection: Binding(get: { record.collectedAt ?? .now },
                                                  set: { record.collectedAt = $0 }),
                               in: ...Date.now,
                               displayedComponents: .date)

                    Stepper(value: Binding(get: { record.quantity }, set: { record.quantity = max(1, $0) }),
                            in: 1...99) {
                        LabeledContent("Chips owned", value: "\(record.quantity)")
                    }

                    if record.quantity > 1 {
                        Label(record.quantity == 2 ? "1 extra to trade" : "\(record.quantity - 1) extras to trade",
                              systemImage: "arrow.left.arrow.right")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                photoMenu

                TextField("Notes: chip color, who you traded with…", text: notesBinding, axis: .vertical)
                    .lineLimit(2...6)
            }

            visitSection

            if let coordinate = dealer.coordinate {
                Section {
                    Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
                                                                    latitudinalMeters: 2_500,
                                                                    longitudinalMeters: 2_500)),
                        interactionModes: []) {
                        Marker(dealer.name, systemImage: dealer.kind.symbol, coordinate: coordinate)
                            .tint(collected ? Color.accentColor : .gray)
                    }
                    .frame(height: 190)
                    .listRowInsets(EdgeInsets())
                    .onTapGesture {
                        if let url = dealer.mapsURL { openURL(url) }
                    }
                    .accessibilityLabel("Map of \(dealer.name). Opens in Maps.")
                }
            }

            if dealer.kind == .custom {
                Section {
                    Button("Delete Store", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
        .navigationTitle(dealer.name)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: collected) { _, isCollected in isCollected }
        .confirmationDialog("Delete \(dealer.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Store", role: .destructive, action: deleteCustomStore)
        } message: {
            Text("This removes the store and its chip from your collection.")
        }
        .unmarkConfirmation(isPresented: $confirmingUnmark, dealer: dealer, quantity: quantity) {
            withAnimation(.snappy) { context.setCollected(false, dealerID: dealer.id) }
        }
        .confirmationDialog("Remove this chip's photo?", isPresented: $confirmingRemovePhoto, titleVisibility: .visible) {
            Button("Remove Photo", role: .destructive) {
                withAnimation { app.photos.removePhoto(for: dealer.id) }
            }
        } message: {
            Text("The chip stays in your collection.")
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker(allowsEditing: true) { image in
                guard let upright = ChipRecognizer.normalized(image) else { return }
                savePhoto(UIImage(cgImage: upright))
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showingLibrary, selection: $libraryItem, matching: .images)
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            libraryItem = nil
            Task { await saveLibraryPhoto(item) }
        }
        .sheet(isPresented: $showingPhoto) {
            ChipPhotoViewer(dealer: dealer)
        }
    }

    /// Add, retake or remove the photo of the collector's chip.
    private var photoMenu: some View {
        Menu {
            if CameraPicker.isAvailable {
                Button {
                    showingCamera = true
                } label: {
                    Label(hasPhoto ? "Retake Photo" : "Take Photo", systemImage: "camera")
                }
            }
            Button {
                showingLibrary = true
            } label: {
                Label("Choose from Library", systemImage: "photo.on.rectangle")
            }
            if hasPhoto {
                Button(role: .destructive) {
                    confirmingRemovePhoto = true
                } label: {
                    Label("Remove Photo", systemImage: "trash")
                }
            }
        } label: {
            Label(hasPhoto ? "Change Photo" : "Add a Photo of Your Chip", systemImage: hasPhoto ? "photo" : "camera")
        }
    }

    private func saveLibraryPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let loaded = await Task.detached(priority: .userInitiated, operation: { ChipRecognizer.load(data) }).value
        else { return }
        savePhoto(await ChipRecognizer.subjectPhoto(of: loaded.image))
    }

    /// A photo of a chip means the collector has it, so a missing chip gets marked collected.
    private func savePhoto(_ image: UIImage) {
        do {
            try app.photos.save(image, for: dealer.id)
            withAnimation(.snappy) { context.setCollected(true, dealerID: dealer.id) }
        } catch {
            print("Couldn't save the photo for \(dealer.id): \(error)")
        }
    }

    private var header: some View {
        Section {
            VStack(spacing: 10) {
                if hasPhoto {
                    Button {
                        showingPhoto = true
                    } label: {
                        ChipPhotoView(dealerID: dealer.id, collected: collected, cornerRadius: 22)
                            .frame(width: 168, height: 168)
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Photo of your chip")
                    .accessibilityHint("Double-tap to view it full size")
                } else {
                    Button {
                        if collected {
                            confirmingUnmark = true
                        } else {
                            withAnimation(.snappy) { context.setCollected(true, dealerID: dealer.id) }
                        }
                    } label: {
                        ChipIcon(collected: collected, size: 104)
                            .shadow(color: .black.opacity(collected ? 0.25 : 0), radius: 8, y: 4)
                            .scaleEffect(collected ? 1 : 0.94)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(collected ? "Collected" : "Missing")
                    .accessibilityHint("Double-tap to toggle")
                }
                Text(dealer.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(dealer.cityLine.isEmpty ? dealer.regionName : "\(dealer.city), \(dealer.regionName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Label(dealer.kind.label, systemImage: dealer.kind.symbol)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                    if dealer.isClosed {
                        Label("Closed", systemImage: "xmark.circle")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if dealer.isClosed {
                    Text("This location has left Harley-Davidson's dealer list. Your chip from it stays in your collection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if !hasPhoto {
                    Text(collected ? "Tap the chip to mark it missing" : "Tap the chip when you get it")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var visitSection: some View {
        let parent = dealer.parentId.flatMap { app.directory.dealer(id: $0) }
        if dealer.mapsURL != nil || dealer.phoneURL != nil || dealer.websiteURL != nil || parent != nil
            || dealer.openingHours != nil {
            Section("Visit") {
                if let url = dealer.mapsURL, dealer.address != nil || dealer.coordinate != nil {
                    Link(destination: url) {
                        Label {
                            Text(dealer.fullAddress).foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "map")
                        }
                    }
                }
                if let hours = dealer.openingHours {
                    StoreHoursRow(hours: hours, timeZone: dealer.storeTimeZone)
                }
                if let phone = dealer.phone, let url = dealer.phoneURL {
                    Link(destination: url) {
                        Label { Text(phone).foregroundStyle(.primary) } icon: { Image(systemName: "phone") }
                    }
                }
                if let url = dealer.websiteURL {
                    Link(destination: url) {
                        Label {
                            Text(url.host() ?? url.absoluteString).foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "safari")
                        }
                    }
                }
                if let parent {
                    NavigationLink(value: parent) {
                        LabeledContent("Run by", value: parent.name)
                    }
                }
            }
        }
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { record?.notes ?? "" },
            set: { newValue in
                if let record {
                    record.notes = newValue
                } else if !newValue.isEmpty {
                    context.ensureChipRecord(for: dealer.id).notes = newValue
                }
            }
        )
    }

    private func deleteCustomStore() {
        guard let store = customDealers.first(where: { $0.dealerID == dealer.id }) else { return }
        context.deleteCustomDealer(store)
        dismiss()
    }
}

#Preview {
    NavigationStack {
        DealerDetailView(dealer: DealerDirectory.shared.dealers.first ?? .sample)
    }
    .environment(AppModel())
    .modelContainer(.preview)
}
