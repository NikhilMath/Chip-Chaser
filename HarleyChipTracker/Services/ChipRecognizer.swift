import CoreGraphics
import CoreLocation
import ImageIO
import UIKit
import Vision

/// Reads a photo of chips on the iPhone: the text printed on them, and where the chips are.
///
/// Everything runs on-device with Apple's Vision framework; the photo never leaves the phone.
nonisolated enum ChipRecognizer {
    /// What one photo shows.
    struct Scan: @unchecked Sendable {
        /// The photo, upright and scaled down.
        let image: CGImage
        let snippets: [ChipMatcher.Snippet]
        /// Things that stand out from the background (usually the chips): normalized, origin top-left.
        let subjects: [CGRect]
    }

    /// The longest side photos are scaled to before reading and saving.
    static let workingSize: CGFloat = 2_048

    /// Reads the text on the chips and finds them in the photo.
    ///
    /// Two kinds of reading run side by side:
    /// - Each round chip found in the photo gets its rim unrolled into a flat strip (both ways
    ///   round), so a dealer name curving around the edge reads as one straight line.
    /// - The whole photo is read turned eight ways (every 45°), for straight text on a chip
    ///   lying at an angle, and for chips too cut off to look round.
    static func scan(_ image: CGImage) async throws -> Scan {
        let reading = upTo(image, maxSide: 1_600)
        let size = CGSize(width: reading.width, height: reading.height)

        let circles = chipCircles(in: reading)
        let gray = ChipCircles.GrayImage(reading)

        enum Job { case turn(Double), strip(ChipCircles.Circle, clockwise: Bool) }
        var jobs: [Job] = []
        for circle in circles {
            jobs.append(.strip(circle, clockwise: true))
            jobs.append(.strip(circle, clockwise: false))
        }
        jobs += stride(from: 0.0, to: 360.0, by: 45.0).map { .turn($0 * .pi / 180) }

        func run(_ job: Job) async throws -> [ChipMatcher.Snippet] {
            switch job {
            case .turn(let angle):
                return try await readText(in: reading, turnedBy: angle)
            case .strip(let circle, let clockwise):
                guard let gray, let strip = ChipCircles.unroll(gray, circle: circle, clockwise: clockwise) else { return [] }
                let box = circle.box(in: size)
                return try await recognizeText(in: strip).map { ChipMatcher.Snippet($0.text, box: box) }
            }
        }

        var snippets: [ChipMatcher.Snippet] = []
        try await withThrowingTaskGroup(of: [ChipMatcher.Snippet].self) { group in
            // A few at a time keeps memory down on older phones.
            var pending = jobs[...]
            for _ in 0..<3 {
                guard let job = pending.popFirst() else { break }
                group.addTask { try await run(job) }
            }
            while let found = try await group.next() {
                snippets += found
                if let job = pending.popFirst() {
                    group.addTask { try await run(job) }
                }
            }
        }

        let salient = (try? await findSubjects(in: reading)) ?? []
        // The circle found is often the chip's inlay; frame a bit wider so the rim isn't cut off.
        let framed = circles.map { ChipCircles.Circle(center: $0.center, radius: $0.radius * 1.22).box(in: size) }
        let subjects = framed + salient
        return Scan(image: image, snippets: snippets, subjects: subjects)
    }

    /// The round chips in a photo (in the photo's pixels), plus a guess at one filling the
    /// middle of the frame when that might be a close-up (the rim cut off, or only the
    /// chip's middle looking round). Not for a photo of several chips, where that ring would
    /// run across all of them.
    static func chipCircles(in image: CGImage) -> [ChipCircles.Circle] {
        let size = CGSize(width: image.width, height: image.height)
        let shortSide = min(size.width, size.height)
        var circles: [ChipCircles.Circle] = []
        if let small = ChipCircles.GrayImage(image, maxSide: 360) {
            let scale = size.width / CGFloat(small.width)
            circles = ChipCircles.find(in: small).map {
                ChipCircles.Circle(center: CGPoint(x: $0.center.x * scale, y: $0.center.y * scale), radius: $0.radius * scale)
            }
        }
        if circles.count < 2 && !circles.contains(where: { $0.radius >= shortSide * 0.3 }) {
            circles.append(ChipCircles.Circle(center: CGPoint(x: size.width / 2, y: size.height / 2), radius: shortSide * 0.47))
        }
        return circles
    }

    /// Text in an image as it stands, with Vision's boxes (normalized, origin bottom-left).
    private static func recognizeText(in image: CGImage) async throws -> [(text: String, box: CGRect)] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Dealer names are proper nouns; "correcting" them to dictionary words hurts.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
        request.minimumTextHeightFraction = 0.012
        let observations = try await request.perform(on: image)
        var found: [(text: String, box: CGRect)] = []
        for observation in observations {
            for candidate in observation.topCandidates(2) where candidate.confidence >= 0.2 {
                found.append((candidate.string, observation.boundingBox.cgRect))
            }
        }
        return found
    }

    /// Reads text with the image turned by `angle` radians, and maps what it finds back onto
    /// the unturned image.
    private static func readText(in image: CGImage, turnedBy angle: Double) async throws -> [ChipMatcher.Snippet] {
        guard let turned = angle == 0 ? image : rotated(image, by: angle) else { return [] }
        let found = try await recognizeText(in: turned)

        let width = Double(image.width), height = Double(image.height)
        let turnedWidth = Double(turned.width), turnedHeight = Double(turned.height)
        // Vision's boxes are normalized with the origin bottom-left, like Core Graphics.
        let unturn = CGAffineTransform(translationX: width / 2, y: height / 2)
            .rotated(by: -angle)
            .translatedBy(x: -turnedWidth / 2, y: -turnedHeight / 2)

        var snippets: [ChipMatcher.Snippet] = []
        for (text, normalized) in found {
            let pixels = CGRect(x: normalized.minX * turnedWidth, y: normalized.minY * turnedHeight,
                                width: normalized.width * turnedWidth, height: normalized.height * turnedHeight)
            let original = pixels.applying(unturn)
            let box = CGRect(x: original.minX / width, y: 1 - original.maxY / height,
                             width: original.width / width, height: original.height / height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !box.isNull else { continue }
            snippets.append(ChipMatcher.Snippet(text, box: box))
        }
        return snippets
    }

    /// The main subject cut out as a square: for a photo of a chip whose dealer is already known.
    static func subjectPhoto(of image: CGImage) async -> UIImage {
        let subjects = (try? await findSubjects(in: upTo(image, maxSide: 1_024))) ?? []
        let rect = subjectCrop(subjects: subjects, imageSize: CGSize(width: image.width, height: image.height))
        return crop(image, to: rect)
    }

    private static func findSubjects(in image: CGImage) async throws -> [CGRect] {
        let request = GenerateObjectnessBasedSaliencyImageRequest()
        let observation = try await request.perform(on: image)
        return observation.salientObjects.map { object in
            let box = object.boundingBox.cgRect
            return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
    }

    // MARK: - Framing each chip

    /// The square to cut out for each chip, and whether it's likely a separate chip
    /// (rather than more text off one already found). Rects are normalized, origin top-left.
    static func layout(chips regions: [CGRect], subjects: [CGRect], imageSize: CGSize) -> [(crop: CGRect, separate: Bool)] {
        var results: [(crop: CGRect, separate: Bool)] = []
        var claimed: [CGRect] = []
        for region in regions {
            let center = CGPoint(x: region.midX, y: region.midY)
            let separate = claimed.isEmpty || !claimed.contains { neighborhood(of: $0).contains(center) }
            let others = regions.filter { $0 != region }.map { CGPoint(x: $0.midX, y: $0.midY) }
            let crop = cropRect(around: region, subjects: subjects, others: others, imageSize: imageSize)
            results.append((crop, separate))
            if separate { claimed.append(crop) }
        }
        return results
    }

    /// The square to save when nothing on the photo could be read: the main subject.
    static func subjectCrop(subjects: [CGRect], imageSize: CGSize) -> CGRect {
        let usable = subjects.filter { $0.width * $0.height < 0.9 && $0.width * $0.height > 0.01 }
        if let largest = usable.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            return square(largest, imageSize: imageSize, padding: 1.08)
        }
        let side = min(imageSize.width, imageSize.height) * 0.9
        let rect = CGRect(x: (imageSize.width - side) / 2 / imageSize.width,
                          y: (imageSize.height - side) / 2 / imageSize.height,
                          width: side / imageSize.width, height: side / imageSize.height)
        return rect
    }

    private static func cropRect(around region: CGRect, subjects: [CGRect], others: [CGPoint], imageSize: CGSize) -> CGRect {
        let center = CGPoint(x: region.midX, y: region.midY)
        let fitting = subjects.filter { subject in
            let area = subject.width * subject.height
            return area < 0.9 && area > 0.01
                && subject.contains(center)
                && subject.width >= region.width * 0.6
                && !others.contains { subject.contains($0) }
        }
        if let subject = fitting.min(by: { $0.width * $0.height < $1.width * $1.height }) {
            return square(subject, imageSize: imageSize, padding: 1.08)
        }
        // The text runs around the rim, so the chip is a bit bigger than the text found on it.
        return square(region, imageSize: imageSize, padding: 1.4, minimumShare: 0.25)
    }

    /// Where a found chip sits, generously: more text from the same chip lands in here.
    private static func neighborhood(of crop: CGRect) -> CGRect {
        crop.insetBy(dx: -crop.width * 0.1, dy: -crop.height * 0.1)
    }

    /// A square (in pixels) around `rect`, scaled by `padding`, kept inside the photo.
    private static func square(_ rect: CGRect, imageSize: CGSize, padding: CGFloat, minimumShare: CGFloat = 0) -> CGRect {
        let width = imageSize.width, height = imageSize.height
        let shortSide = min(width, height)
        var side = max(rect.width * width, rect.height * height) * padding
        side = min(max(side, shortSide * minimumShare), shortSide)
        var x = rect.midX * width - side / 2
        var y = rect.midY * height - side / 2
        x = min(max(x, 0), width - side)
        y = min(max(y, 0), height - side)
        return CGRect(x: x / width, y: y / height, width: side / width, height: side / height)
    }

    // MARK: - Images

    /// Cuts `rect` (normalized, origin top-left) out of `image`, at most `maxSide` pixels across.
    static func crop(_ image: CGImage, to rect: CGRect, maxSide: CGFloat = 1_200) -> UIImage {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let pixels = CGRect(x: rect.minX * width, y: rect.minY * height,
                            width: rect.width * width, height: rect.height * height).integral
        guard let cropped = image.cropping(to: pixels) else { return UIImage(cgImage: image) }
        return UIImage(cgImage: upTo(cropped, maxSide: maxSide))
    }

    /// An upright copy of a photo, at most `workingSize` pixels across.
    static func normalized(_ image: UIImage) -> CGImage? {
        let scale = min(1, workingSize / max(image.size.width * image.scale, image.size.height * image.scale))
        let size = CGSize(width: (image.size.width * image.scale * scale).rounded(),
                          height: (image.size.height * image.scale * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    /// Decodes a photo file (from the photo library) upright and scaled down, plus where it was
    /// taken if the file says.
    static func load(_ data: Data) -> (image: CGImage, location: CLLocation?)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: workingSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (image, location(fromGPS: properties?[kCGImagePropertyGPSDictionary] as? [CFString: Any]))
    }

    private static func location(fromGPS gps: [CFString: Any]?) -> CLLocation? {
        guard let gps,
              var latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              var longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { latitude = -latitude }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { longitude = -longitude }
        return CLLocation(latitude: latitude, longitude: longitude)
    }

    /// `image` scaled down so its longest side is at most `maxSide`.
    static func upTo(_ image: CGImage, maxSide: CGFloat) -> CGImage {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let width = Int((CGFloat(image.width) * scale).rounded())
        let height = Int((CGFloat(image.height) * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// `image` turned by `angle` radians on a canvas big enough to hold all of it.
    private static func rotated(_ image: CGImage, by angle: Double) -> CGImage? {
        let width = Double(image.width), height = Double(image.height)
        let turnedWidth = Int((abs(width * cos(angle)) + abs(height * sin(angle))).rounded(.up))
        let turnedHeight = Int((abs(width * sin(angle)) + abs(height * cos(angle))).rounded(.up))
        guard let context = CGContext(data: nil, width: turnedWidth, height: turnedHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: turnedWidth, height: turnedHeight))
        context.interpolationQuality = .high
        context.translateBy(x: Double(turnedWidth) / 2, y: Double(turnedHeight) / 2)
        context.rotate(by: angle)
        context.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        return context.makeImage()
    }
}
