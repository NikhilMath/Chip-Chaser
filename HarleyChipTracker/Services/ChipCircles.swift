import CoreGraphics
import Foundation

/// Finds the round chips in a photo and unrolls the text around their rims.
///
/// Dealer names usually run around the edge of a chip, too curved for text recognition to read
/// in one go. Unrolling the ring between the rim and the middle into a flat strip (like peeling
/// the label off a can) turns that curve into a straight line of text.
nonisolated enum ChipCircles {
    /// A round thing in the photo, in pixels, origin top-left.
    struct Circle: Hashable, Sendable {
        var center: CGPoint
        var radius: CGFloat

        /// Its bounding square, normalized to the image, origin top-left.
        func box(in size: CGSize) -> CGRect {
            CGRect(x: (center.x - radius) / size.width, y: (center.y - radius) / size.height,
                   width: radius * 2 / size.width, height: radius * 2 / size.height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    /// An 8-bit grayscale copy of an image. Row 0 is the top.
    struct GrayImage: Sendable {
        let width: Int
        let height: Int
        var pixels: [UInt8]

        init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        init?(_ image: CGImage, maxSide: CGFloat? = nil) {
            let longest = CGFloat(max(image.width, image.height))
            let scale = maxSide.map { min(1, $0 / longest) } ?? 1
            let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
            let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
            var pixels = [UInt8](repeating: 0, count: width * height)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.init(width: width, height: height, pixels: pixels)
        }

        func makeImage() -> CGImage? {
            let data = Data(pixels) as CFData
            guard let provider = CGDataProvider(data: data) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }

        /// Bilinear sample; mid-grey outside the image.
        @inline(__always)
        func sample(_ x: Double, _ y: Double) -> UInt8 {
            guard x >= 0, y >= 0, x < Double(width - 1), y < Double(height - 1) else { return 128 }
            let x0 = Int(x), y0 = Int(y)
            let fx = x - Double(x0), fy = y - Double(y0)
            let index = y0 * width + x0
            let top = Double(pixels[index]) * (1 - fx) + Double(pixels[index + 1]) * fx
            let bottom = Double(pixels[index + width]) * (1 - fx) + Double(pixels[index + width + 1]) * fx
            return UInt8(max(0, min(255, (top * (1 - fy) + bottom * fy).rounded())))
        }
    }

    // MARK: - Unrolling

    /// The ring of `circle` from near the middle out to the rim, laid flat.
    ///
    /// `clockwise` reads text that runs over the top of the chip (letters standing on the
    /// inner edge); otherwise it reads text that runs along the bottom (letters hanging from
    /// the inner edge, upright when the chip is held normally). The strip goes round one and
    /// two-thirds times, so a name running up to two-thirds of the way around is whole at least
    /// once however the chip is turned. The ring reaches a little past `radius`, in case the
    /// circle found was the chip's inlay rather than its rim.
    static func unroll(_ gray: GrayImage, circle: Circle, clockwise: Bool) -> CGImage? {
        let outer = Double(circle.radius) * 1.12
        let inner = Double(circle.radius) * 0.28
        let reference = Double(circle.radius) * 0.72
        let sweep = 2 * Double.pi * 5 / 3
        let scale = min(1, 3_600 / (sweep * reference))
        let width = Int(sweep * reference * scale)
        let height = Int((outer - inner) * scale)
        guard width > 32, height > 16 else { return nil }

        let step = sweep / Double(width)
        let cx = Double(circle.center.x), cy = Double(circle.center.y)
        var cosines = [Double](repeating: 0, count: width)
        var sines = [Double](repeating: 0, count: width)
        for column in 0..<width {
            // Clockwise starts at the bottom so the top of the chip comes early and whole; the
            // other way starts at the top so the bottom does.
            let angle = clockwise ? Double.pi / 2 + Double(column) * step : -Double.pi / 2 - Double(column) * step
            cosines[column] = cos(angle)
            sines[column] = sin(angle)
        }

        var pixels = [UInt8](repeating: 128, count: width * height)
        for row in 0..<height {
            let radius = clockwise ? outer - Double(row) / scale : inner + Double(row) / scale
            let base = row * width
            for column in 0..<width {
                pixels[base + column] = gray.sample(cx + radius * cosines[column], cy + radius * sines[column])
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels).makeImage()
    }

    // MARK: - Finding circles

    /// Round things in `gray`, biggest evidence first, at most `limit`.
    ///
    /// A two-step Hough transform: every strong edge votes for centers along its gradient,
    /// then each likely center picks the radius most of its edge agrees on. Chips have crisp
    /// round edges (the rim, the inlay), so they stand out from tables and hands.
    static func find(in gray: GrayImage, limit: Int = 8) -> [Circle] {
        let width = gray.width, height = gray.height
        guard width > 16, height > 16 else { return [] }
        let shortSide = Double(min(width, height))
        let minRadius = max(6, Int(shortSide * 0.07))
        let maxRadius = Int(shortSide * 0.62)

        // Edges: Sobel on a lightly blurred copy.
        let blurred = boxBlur(gray)
        var edges: [(x: Int, y: Int, dx: Double, dy: Double)] = []
        var magnitudes: [Double] = []
        var gradients: [(Int, Int, Double, Double, Double)] = []
        gradients.reserveCapacity(width * height / 4)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                func p(_ dx: Int, _ dy: Int) -> Double { Double(blurred[(y + dy) * width + x + dx]) }
                let gx = (p(1, -1) + 2 * p(1, 0) + p(1, 1)) - (p(-1, -1) + 2 * p(-1, 0) + p(-1, 1))
                let gy = (p(-1, 1) + 2 * p(0, 1) + p(1, 1)) - (p(-1, -1) + 2 * p(0, -1) + p(1, -1))
                let magnitude = (gx * gx + gy * gy).squareRoot()
                if magnitude > 40 {
                    gradients.append((x, y, gx, gy, magnitude))
                    magnitudes.append(magnitude)
                }
            }
        }
        guard gradients.count > 50 else { return [] }
        magnitudes.sort()
        let threshold = max(60, magnitudes[Int(Double(magnitudes.count) * 0.6)])
        for (x, y, gx, gy, magnitude) in gradients where magnitude >= threshold {
            edges.append((x, y, gx / magnitude, gy / magnitude))
        }

        // Step 1: votes for centers.
        var votes = [Float](repeating: 0, count: width * height)
        for edge in edges {
            for sign in [-1.0, 1.0] {
                for radius in stride(from: minRadius, through: maxRadius, by: 1) {
                    let x = Int((Double(edge.x) + sign * edge.dx * Double(radius)).rounded())
                    let y = Int((Double(edge.y) + sign * edge.dy * Double(radius)).rounded())
                    guard x >= 0, y >= 0, x < width, y < height else { break }
                    votes[y * width + x] += 1
                }
            }
        }
        let smoothed = boxBlur(votes, width: width, height: height)

        // Local peaks.
        var peaks: [(x: Int, y: Int, votes: Float)] = []
        let window = max(3, minRadius / 2)
        let strongest = smoothed.max() ?? 0
        guard strongest > 0 else { return [] }
        for y in window..<(height - window) {
            for x in window..<(width - window) {
                let value = smoothed[y * width + x]
                guard value >= strongest * 0.15 else { continue }
                var isPeak = true
                search: for dy in -window...window {
                    for dx in -window...window where dx != 0 || dy != 0 {
                        if smoothed[(y + dy) * width + x + dx] > value { isPeak = false; break search }
                    }
                }
                if isPeak { peaks.append((x, y, value)) }
            }
        }
        peaks.sort { $0.votes > $1.votes }

        // Step 2: each peak's radius, from how much of each ring its edges cover.
        var circles: [(circle: Circle, support: Double)] = []
        for peak in peaks.prefix(24) {
            var histogram = [Double](repeating: 0, count: maxRadius + 2)
            for edge in edges {
                let dx = Double(edge.x - peak.x), dy = Double(edge.y - peak.y)
                let distance = (dx * dx + dy * dy).squareRoot()
                let bin = Int(distance.rounded())
                guard bin >= minRadius, bin <= maxRadius else { continue }
                // Only edges that face the center belong to this circle.
                let alignment = abs((dx * edge.dx + dy * edge.dy) / distance)
                if alignment > 0.85 { histogram[bin] += 1 }
            }
            var best: (radius: Int, support: Double)?
            var supports = [Double](repeating: 0, count: maxRadius + 2)
            for radius in minRadius...maxRadius {
                let count = histogram[radius - 1] + histogram[radius] + histogram[radius + 1]
                supports[radius] = count / (2 * .pi * Double(radius))
            }
            let top = supports.max() ?? 0
            // The rim, not the inlay: the biggest ring with nearly as much support.
            for radius in stride(from: maxRadius, through: minRadius, by: -1)
            where supports[radius] >= max(0.3, top * 0.6) {
                best = (radius, supports[radius])
                break
            }
            guard let best else { continue }
            circles.append((Circle(center: CGPoint(x: peak.x, y: peak.y), radius: CGFloat(best.radius)), best.support))
        }

        // Keep the clearest of circles that coincide, and drop two kinds of ghost: small rings
        // inside a chip (its logo, edge spots), and the gap between chips that touch, whose
        // edges line up into a circle crossing two or more of them.
        circles.sort { $0.circle.radius * $0.support > $1.circle.radius * $1.support }
        var kept: [Circle] = []
        for candidate in circles {
            let circle = candidate.circle
            var coincides = false, inside = false, crossings = 0
            for other in kept {
                let distance = hypot(circle.center.x - other.center.x, circle.center.y - other.center.y)
                if distance < max(circle.radius, other.radius) * 0.6 { coincides = true }
                if distance < other.radius && circle.radius < other.radius * 0.7 { inside = true }
                if distance < (circle.radius + other.radius) * 0.85 { crossings += 1 }
            }
            if !coincides && !inside && crossings < 2 { kept.append(circle) }
            if kept.count == limit { break }
        }
        return kept
    }

    private static func boxBlur(_ gray: GrayImage) -> [UInt8] {
        let width = gray.width, height = gray.height
        var output = gray.pixels
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var sum = 0
                for dy in -1...1 {
                    for dx in -1...1 { sum += Int(gray.pixels[(y + dy) * width + x + dx]) }
                }
                output[y * width + x] = UInt8(sum / 9)
            }
        }
        return output
    }

    private static func boxBlur(_ values: [Float], width: Int, height: Int) -> [Float] {
        var output = values
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var sum: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 { sum += values[(y + dy) * width + x + dx] }
                }
                output[y * width + x] = sum / 9
            }
        }
        return output
    }
}
