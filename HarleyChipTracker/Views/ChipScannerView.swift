import CoreLocation
import PhotosUI
import SwiftData
import SwiftUI

/// Take or pick a photo of chips: Chip Chaser reads the dealer off each one, then adds the
/// chips to the collection with their photos once the collector checks them.
struct ChipScannerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var records: [ChipRecord]
    @Query private var customDealers: [CustomDealer]

    @State private var phase = Phase.start
    @State private var items: [ScanItem] = []
    @State private var nearby: [Dealer] = []
    @State private var added: [Dealer] = []
    @State private var showingCamera = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var choosingFor: ScanItem.ID?
    @State private var problem: AlertMessage?

    enum Phase {
        case start
        /// A picked photo is being fetched (from iCloud, perhaps) before it can be read.
        case opening
        case reading(UIImage)
        case review(UIImage)
        case done
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .start: startView
                case .opening:
                    ProgressView("Opening photo…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .reading(let image): readingView(image)
                case .review(let image): reviewView(image)
                case .done: doneView
                }
            }
            .navigationTitle("Add from Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .done = phase {
                        EmptyView()
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in
                Task { await readCameraPhoto(image) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            libraryItem = nil
            Task { await readLibraryPhoto(item) }
        }
        .sheet(isPresented: Binding(get: { choosingFor != nil }, set: { if !$0 { choosingFor = nil } })) {
            if let index = items.firstIndex(where: { $0.id == choosingFor }) {
                DealerPickerView(suggestions: items[index].alternatives, nearby: nearby, dealers: allDealers) { dealer in
                    items[index].dealer = dealer
                    items[index].isGuess = false
                    items[index].selected = true
                    choosingFor = nil
                }
            }
        }
        .alert($problem)
        .task {
            app.location.refresh()
            #if DEBUG
            await readDebugImage()
            #endif
        }
    }

    #if DEBUG
    /// `-debugScanImage /path/to/photo.jpg` reads that photo as if picked from the library;
    /// `-debugScanAdd YES` then adds what it found (for screenshots and simulator checks).
    private func readDebugImage() async {
        guard case .start = phase, let path = DebugLaunch.scanImage,
              let data = FileManager.default.contents(atPath: path),
              let loaded = ChipRecognizer.load(data) else { return }
        await read(loaded.image, location: loaded.location)
        if DebugLaunch.scanAutoAdd { addSelected() }
    }
    #endif

    // MARK: - Start

    private var startView: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 24)
                VStack(spacing: 8) {
                    Text("Snap Your Chips")
                        .font(.title2.weight(.bold))
                    Text("Take a photo of a chip, or a few laid out face up. Chip Chaser reads the dealer's name off each one and adds it to your collection, photo and all.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 12) {
                    if CameraPicker.isAvailable {
                        Button {
                            showingCamera = true
                        } label: {
                            Label("Take Photo", systemImage: "camera")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    PhotosPicker(selection: $libraryItem, matching: .images) {
                        Label("Choose from Library", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .tint(Color.accentColor)

                VStack(alignment: .leading, spacing: 10) {
                    Label("Good light, no glare on the face", systemImage: "sun.max")
                    Label("Chips face up, with the dealer's name showing", systemImage: "circle.grid.2x2")
                    Label("Get close: fill the frame with the chips", systemImage: "arrow.up.left.and.arrow.down.right")
                    Label("The photo stays on your iPhone", systemImage: "lock")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Reading

    private func readingView(_ image: UIImage) -> some View {
        VStack(spacing: 20) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.black.opacity(0.25))
                }
                .frame(maxHeight: 420)
            ProgressView {
                Text("Reading your chips…")
                    .font(.headline)
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Review

    private func reviewView(_ photo: UIImage) -> some View {
        let status = CollectionStatus(records: records)
        let selectedCount = items.filter { $0.selected && $0.dealer != nil }.count
        let foundAny = items.contains { $0.dealer != nil && !$0.isGuess }

        return List {
            Section {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach($items) { $item in
                    ScanItemRow(item: $item,
                                quantity: item.dealer.map { status.quantity(for: $0.id) } ?? 0,
                                hasPhoto: item.dealer.map { app.photos.hasPhoto(for: $0.id) } ?? false) {
                        choosingFor = item.id
                    }
                }
            } header: {
                Text(foundAny ? (items.count == 1 ? "Found in This Photo" : "Found \(items.count) Chips") : "Which Chip Is This?")
            } footer: {
                Text(foundAny
                     ? "Check each match before adding. Tap Change if one's wrong."
                     : "Couldn't read a dealer's name on this photo. Choose the dealer, or try again closer up with less glare.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button {
                    addSelected()
                } label: {
                    Text(addTitle(selectedCount))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCount == 0)
                Button("Try Another Photo") { reset() }
                    .font(.subheadline)
            }
            .controlSize(.large)
            .tint(Color.accentColor)
            .padding()
            .background(.bar)
        }
    }

    private func addTitle(_ count: Int) -> String {
        switch count {
        case 0: "Add to Collection"
        case 1: "Add 1 Chip"
        default: "Add \(count) Chips"
        }
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.bounce, value: added.count)
            Text(added.count == 1 ? "Added to Your Collection" : "Added \(added.count) Chips")
                .font(.title2.weight(.bold))
            VStack(spacing: 4) {
                ForEach(added) { dealer in
                    Text("\(dealer.name), \(dealer.cityLine)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            Spacer()
            VStack(spacing: 12) {
                Button {
                    reset()
                } label: {
                    Label("Add Another", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    dismiss()
                } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .tint(Color.accentColor)
        }
        .padding(24)
        .sensoryFeedback(.success, trigger: added.count)
    }

    // MARK: - Work

    /// Every location a chip could be from: open, closed and hand-added, tracked or not.
    private var allDealers: [Dealer] {
        app.directory.dealers + app.directory.closedDealers + customDealers.map(\.asDealer)
    }

    private func couldNotOpen() {
        withAnimation { phase = .start }
        problem = AlertMessage(title: "Couldn't Open That Photo",
                               body: "Try another photo, or take a new one.")
    }

    private func readCameraPhoto(_ image: UIImage) async {
        guard let upright = ChipRecognizer.normalized(image) else { return couldNotOpen() }
        // A photo just taken was taken here; use the fix if it's recent.
        let here = app.location.location.flatMap { $0.timestamp.timeIntervalSinceNow > -1_800 ? $0 : nil }
        await read(upright, location: here)
    }

    private func readLibraryPhoto(_ item: PhotosPickerItem) async {
        withAnimation { phase = .opening }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return couldNotOpen() }
        let loaded = await Task.detached(priority: .userInitiated) { ChipRecognizer.load(data) }.value
        guard let loaded else { return couldNotOpen() }
        await read(loaded.image, location: loaded.location)
    }

    private func read(_ image: CGImage, location: CLLocation?) async {
        withAnimation { phase = .reading(UIImage(cgImage: image)) }
        let matcher = ChipMatcher(dealers: allDealers)
        let size = CGSize(width: image.width, height: image.height)

        var found: [ScanItem] = []
        let scan = try? await ChipRecognizer.scan(image)
        let snippets = scan?.snippets ?? []
        let subjects = scan?.subjects ?? []
        let findings = await Task.detached(priority: .userInitiated) {
            matcher.findChips(in: snippets, near: location)
        }.value
        let close = location.map { matcher.dealers(near: $0, within: 3_000) } ?? []

        if findings.chips.isEmpty {
            let crop = ChipRecognizer.crop(image, to: ChipRecognizer.subjectCrop(subjects: subjects, imageSize: size))
            // Offer a best guess when one stands out, or when there's one store right here.
            var guess: Dealer?
            if let first = findings.suggestions.first {
                let second = findings.suggestions.dropFirst().first?.score ?? 0
                if first.score >= second * 1.3 { guess = first.dealer }
            } else if close.count == 1, let only = close.first, let spot = only.location,
                      let location, location.distance(from: spot) < 1_000 {
                guess = only
            }
            found = [ScanItem(dealer: guess, alternatives: findings.suggestions.map(\.dealer),
                              photo: crop, selected: false, isGuess: guess != nil)]
        } else {
            let layout = ChipRecognizer.layout(chips: findings.chips.map(\.region), subjects: subjects, imageSize: size)
            // List them as they lie in the photo: top row first, left to right.
            let ordered = zip(findings.chips, layout).sorted { lhs, rhs in
                let lhsRow = Int(lhs.1.crop.midY * 3), rhsRow = Int(rhs.1.crop.midY * 3)
                return lhsRow != rhsRow ? lhsRow < rhsRow : lhs.1.crop.midX < rhs.1.crop.midX
            }
            for (chip, frame) in ordered {
                found.append(ScanItem(dealer: chip.best.dealer,
                                      alternatives: chip.alternatives.map(\.dealer),
                                      photo: ChipRecognizer.crop(image, to: frame.crop),
                                      selected: frame.separate,
                                      isGuess: false))
            }
        }

        items = found
        nearby = close
        withAnimation { phase = .review(UIImage(cgImage: image)) }
    }

    private func addSelected() {
        var dealers: [Dealer] = []
        var unsavedPhotos = 0
        for item in items where item.selected {
            // Two rows set to the same dealer are one chip: the first row's photo is the one kept.
            guard let dealer = item.dealer, !dealers.contains(dealer) else { continue }
            context.setCollected(true, dealerID: dealer.id)
            do {
                try app.photos.save(item.photo, for: dealer.id)
            } catch {
                unsavedPhotos += 1
                print("Couldn't save the photo for \(dealer.id): \(error)")
            }
            dealers.append(dealer)
        }
        try? context.save()
        added = dealers
        withAnimation { phase = .done }
        if unsavedPhotos > 0 {
            problem = AlertMessage(title: "Couldn't Save Every Photo",
                                   body: "Your chips were added, but \(unsavedPhotos == 1 ? "1 photo" : "\(unsavedPhotos) photos") couldn't be saved. Your iPhone may be low on storage. You can add a photo from the chip's page.")
        }
    }

    private func reset() {
        items = []
        added = []
        withAnimation { phase = .start }
    }
}

/// One chip found in the photo.
struct ScanItem: Identifiable {
    let id = UUID()
    var dealer: Dealer?
    var alternatives: [Dealer]
    var photo: UIImage
    var selected: Bool
    /// Picked from weak evidence (a partial read, or the only store nearby): needs a check.
    var isGuess: Bool
}

private struct ScanItemRow: View {
    @Binding var item: ScanItem
    let quantity: Int
    let hasPhoto: Bool
    var onChange: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(uiImage: item.photo)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                if let dealer = item.dealer {
                    if item.isGuess {
                        Text("Best guess")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    Text(dealer.name)
                        .font(.headline)
                    Text(dealer.cityLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    statusLine
                } else {
                    Text("Which dealer is this?")
                        .font(.headline)
                    Text("Couldn't read the name")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button(item.dealer == nil ? "Choose Dealer" : "Change", action: onChange)
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
            }

            Spacer(minLength: 4)

            if item.dealer != nil {
                Button {
                    item.selected.toggle()
                } label: {
                    Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(item.selected ? Color.accentColor : Color(.tertiaryLabel))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(item.selected ? "Will be added" : "Won't be added")
                .accessibilityHint("Double-tap to change")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        if quantity > 0 {
            Text(hasPhoto ? "In your collection · replaces its photo" : "In your collection · adds its photo")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("\(Image(systemName: "sparkles")) New chip")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
    }
}

/// Pick the right dealer for a chip: the closest matches first, then nearby stores, then all.
struct DealerPickerView: View {
    let suggestions: [Dealer]
    let nearby: [Dealer]
    let dealers: [Dealer]
    var onPick: (Dealer) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    if !suggestions.isEmpty {
                        Section("Closest Matches") { rows(suggestions) }
                    }
                    if !nearby.isEmpty {
                        Section("Near You") { rows(nearby) }
                    }
                    Section("All Locations") { rows(dealers.sorted(by: Dealer.byName)) }
                } else {
                    rows(dealers.filter { $0.matches(search: searchText) }.sorted(by: Dealer.byName))
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Dealer, city, state, or ZIP")
            .navigationTitle("Choose Dealer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func rows(_ list: [Dealer]) -> some View {
        ForEach(list) { dealer in
            Button {
                onPick(dealer)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dealer.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(dealer.cityLine)
                        if dealer.isClosed { Text("· Closed") }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    ChipScannerView()
        .environment(AppModel())
        .modelContainer(.preview)
}
