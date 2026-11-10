import PhotosUI
import SwiftUI
import UIKit

/// A chip's photo, or a placeholder chip when it has none yet.
struct ChipPhotoView: View {
    let dealerID: String
    var collected = true
    var cornerRadius: CGFloat = 14

    @Environment(AppModel.self) private var app
    @State private var image: UIImage?

    var body: some View {
        let revision = app.photos.revision(for: dealerID)
        Color(.secondarySystemFill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .saturation(collected ? 1 : 0)
                } else {
                    GeometryReader { proxy in
                        ChipIcon(collected: collected, size: min(proxy.size.width, proxy.size.height) * 0.46)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: "\(dealerID)#\(revision)") {
                image = await app.photos.thumbnail(for: dealerID)
            }
            .accessibilityHidden(true)
    }
}

/// The full-size photo, for showing off or sharing a chip.
struct ChipPhotoViewer: View {
    let dealer: Dealer

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("Photo of your chip from \(dealer.name)")
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(dealer.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if let image {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: Image(uiImage: image),
                                  preview: SharePreview(dealer.name, image: Image(uiImage: image))) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .task { image = await app.photos.photo(for: dealer.id) }
    }
}
