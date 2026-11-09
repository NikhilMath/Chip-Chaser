import Foundation
import Observation
import UIKit

/// Photos of the collector's chips (one per location), kept as JPEG files on this iPhone.
///
/// They live in `Application Support/Chip Photos/`, outside the SwiftData store, so photos never
/// touch the collection database or its iCloud schema: adding them can't put a single chip at
/// risk. App updates keep the folder, and the iPhone's own iCloud Backup includes it.
///
/// Photos are only ever deleted when the collector removes one. Marking a chip missing,
/// resetting the collection or deleting an added store leaves them alone, so restoring a
/// backup brings each chip back with its photo.
@Observable
final class ChipPhotoStore {
    let directory: URL
    /// Which locations have a photo, and a counter that changes whenever one is replaced.
    private(set) var revisions: [String: Int] = [:]

    @ObservationIgnored private let thumbnails = NSCache<NSString, UIImage>()
    @ObservationIgnored private var nextRevision = 1

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Chip Photos", directoryHint: .isDirectory)
    }

    /// Photos for the debug-only demo collection, kept apart from the real ones.
    static var demo: ChipPhotoStore {
        ChipPhotoStore(directory: URL.temporaryDirectory.appending(path: "Demo Chip Photos", directoryHint: .isDirectory))
    }

    init(directory: URL = ChipPhotoStore.defaultDirectory) {
        self.directory = directory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names where name.hasSuffix(Self.photoSuffix) && !name.hasSuffix(Self.thumbnailSuffix) {
            guard let id = Self.dealerID(fromFileName: name) else { continue }
            revisions[id] = nextRevision
        }
    }

    var count: Int { revisions.count }

    /// Every photo's file, by dealer ID, for exporting a backup.
    var photoFiles: [String: URL] {
        Dictionary(uniqueKeysWithValues: revisions.keys.map { ($0, photoURL(for: $0)) })
    }

    func hasPhoto(for dealerID: String) -> Bool { revisions[dealerID] != nil }

    /// Changes whenever the photo for `dealerID` is added, replaced or removed.
    func revision(for dealerID: String) -> Int { revisions[dealerID] ?? 0 }

    /// Saves `image` as the photo for a location, replacing any photo it had.
    func save(_ image: UIImage, for dealerID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photo = Self.resized(image, maxSide: 1_200)
        let thumbnail = Self.resized(image, maxSide: 360)
        guard let photoData = photo.jpegData(compressionQuality: 0.85),
              let thumbnailData = thumbnail.jpegData(compressionQuality: 0.8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try photoData.write(to: photoURL(for: dealerID), options: .atomic)
        try thumbnailData.write(to: thumbnailURL(for: dealerID), options: .atomic)
        thumbnails.setObject(thumbnail, forKey: dealerID as NSString)
        nextRevision += 1
        revisions[dealerID] = nextRevision
    }

    /// Adds photos from an imported backup for locations that don't have one here; a photo
    /// already on this iPhone is never replaced. The files are written off the main thread,
    /// since a backup can hold hundreds. Returns how many were added.
    func importPhotos(_ photos: [String: Data]) async -> Int {
        let directory = directory
        let files = photos
            .filter { !hasPhoto(for: $0.key) }
            .map { (id: $0.key, data: $0.value, photo: photoURL(for: $0.key), thumbnail: thumbnailURL(for: $0.key)) }
        guard !files.isEmpty else { return 0 }

        let saved = await Task.detached(priority: .userInitiated) { () -> [String] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var saved: [String] = []
            for file in files {
                guard let image = UIImage(data: file.data),
                      let thumbnail = Self.resized(image, maxSide: 360).jpegData(compressionQuality: 0.8) else { continue }
                // Photos this app exported are already the right size; anything bigger is scaled down.
                let fits = max(image.size.width * image.scale, image.size.height * image.scale) <= 1_200
                guard let photo = fits ? file.data : Self.resized(image, maxSide: 1_200).jpegData(compressionQuality: 0.85),
                      (try? photo.write(to: file.photo, options: .atomic)) != nil,
                      (try? thumbnail.write(to: file.thumbnail, options: .atomic)) != nil else { continue }
                saved.append(file.id)
            }
            return saved
        }.value

        for id in saved {
            nextRevision += 1
            revisions[id] = nextRevision
        }
        return saved.count
    }

    /// Deletes the photo for a location. Only called when the collector asks.
    func removePhoto(for dealerID: String) {
        try? FileManager.default.removeItem(at: photoURL(for: dealerID))
        try? FileManager.default.removeItem(at: thumbnailURL(for: dealerID))
        thumbnails.removeObject(forKey: dealerID as NSString)
        revisions[dealerID] = nil
    }

    /// A small copy for grids and lists.
    func thumbnail(for dealerID: String) async -> UIImage? {
        guard hasPhoto(for: dealerID) else { return nil }
        if let cached = thumbnails.object(forKey: dealerID as NSString) { return cached }
        let url = thumbnailURL(for: dealerID)
        let image = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: url.path(percentEncoded: false))?.preparingForDisplay()
        }.value
        if let image { thumbnails.setObject(image, forKey: dealerID as NSString) }
        return image
    }

    /// The full-size photo.
    func photo(for dealerID: String) async -> UIImage? {
        guard hasPhoto(for: dealerID) else { return nil }
        let url = photoURL(for: dealerID)
        return await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: url.path(percentEncoded: false))?.preparingForDisplay()
        }.value
    }

    func photoURL(for dealerID: String) -> URL {
        directory.appending(path: Self.fileName(for: dealerID) + Self.photoSuffix, directoryHint: .notDirectory)
    }

    private func thumbnailURL(for dealerID: String) -> URL {
        directory.appending(path: Self.fileName(for: dealerID) + Self.thumbnailSuffix, directoryHint: .notDirectory)
    }

    // MARK: - File names

    private static let photoSuffix = ".jpg"
    private static let thumbnailSuffix = ".thumb.jpg"
    private static let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

    /// "hd-1069" stays as is; anything unusual is percent-encoded so every ID makes a safe file name.
    static func fileName(for dealerID: String) -> String {
        dealerID.addingPercentEncoding(withAllowedCharacters: safeCharacters) ?? dealerID
    }

    static func dealerID(fromFileName name: String) -> String? {
        guard name.hasSuffix(photoSuffix) else { return nil }
        return String(name.dropLast(photoSuffix.count)).removingPercentEncoding
    }

    nonisolated private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let scale = min(1, maxSide / max(pixelSize.width, pixelSize.height, 1))
        let size = CGSize(width: (pixelSize.width * scale).rounded(), height: (pixelSize.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
