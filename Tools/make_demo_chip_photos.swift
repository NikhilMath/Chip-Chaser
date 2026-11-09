// Draws original stand-in chip photos for the demo collection used in App Store screenshots.
// Not any real chip design. Usage: swift Tools/make_demo_chip_photos.swift HarleyChipTracker/Resources/dealers.json <outDir>
import AppKit
import Foundation

struct Payload: Decodable { let dealers: [D] }
struct D: Decodable { let id: String; let name: String; let city: String; let region: String; let closed: String? }

let args = CommandLine.arguments
let data = try! Data(contentsOf: URL(fileURLWithPath: args[1]))
let all = try! JSONDecoder().decode(Payload.self, from: data).dealers.filter { $0.closed == nil }
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let rims: [NSColor] = [
    NSColor(red: 0.78, green: 0.33, blue: 0.08, alpha: 1), // orange
    NSColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1), // black
    NSColor(red: 0.62, green: 0.1, blue: 0.1, alpha: 1),   // red
    NSColor(red: 0.1, green: 0.24, blue: 0.5, alpha: 1),   // blue
    NSColor(red: 0.12, green: 0.38, blue: 0.22, alpha: 1), // green
    NSColor(red: 0.45, green: 0.45, blue: 0.47, alpha: 1), // silver
]

func seeded(_ s: String) -> UInt64 { s.unicodeScalars.reduce(1469598103934665603) { ($0 ^ UInt64($1.value)) &* 1099511628211 } }

func drawArc(_ text: String, ctx: CGContext, radius: CGFloat, maxSweep: CGFloat, size: CGFloat, color: NSColor, onTop: Bool) {
    var fontSize = size
    var attrs: [NSAttributedString.Key: Any] = [:]
    var widths: [CGFloat] = []
    let letters = text.map { String($0) as NSString }
    repeat {
        attrs = [.font: NSFont.systemFont(ofSize: fontSize, weight: .heavy), .foregroundColor: color, .kern: fontSize * 0.04]
        widths = letters.map { $0.size(withAttributes: attrs).width + fontSize * 0.05 }
        fontSize *= 0.95
    } while widths.reduce(0, +) / radius > maxSweep
    let sweep = widths.reduce(0, +) / radius
    // y-up coordinates: top is +pi/2, text over the top reads clockwise (angle decreasing).
    var angle = onTop ? .pi / 2 + sweep / 2 : -.pi / 2 - sweep / 2
    for (letter, width) in zip(letters, widths) {
        let half = width / 2 / radius
        angle += onTop ? -half : half
        ctx.saveGState()
        ctx.translateBy(x: radius * cos(angle), y: radius * sin(angle))
        ctx.rotate(by: onTop ? angle - .pi / 2 : angle + .pi / 2)
        let s = letter.size(withAttributes: attrs)
        letter.draw(at: CGPoint(x: -s.width / 2, y: -s.height / 2), withAttributes: attrs)
        ctx.restoreGState()
        angle += onTop ? -half : half
    }
}

func render(_ d: D, index: Int) -> NSBitmapImageRep {
    let side = 1200
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    var rng = seeded(d.id)
    func rand() -> CGFloat { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(rng >> 33) / CGFloat(1 << 31) }

    // Wooden table.
    let wood = NSGradient(colors: [NSColor(red: 0.36, green: 0.24, blue: 0.15, alpha: 1),
                                   NSColor(red: 0.25, green: 0.16, blue: 0.1, alpha: 1)])!
    wood.draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: -60)
    for i in 0..<70 {
        let y = CGFloat(i) * 18 + rand() * 10
        ctx.setStrokeColor(NSColor(white: rand() > 0.5 ? 0 : 1, alpha: 0.04 + rand() * 0.04).cgColor)
        ctx.setLineWidth(2 + rand() * 5)
        ctx.move(to: CGPoint(x: 0, y: y))
        ctx.addCurve(to: CGPoint(x: CGFloat(side), y: y + rand() * 40 - 20),
                     control1: CGPoint(x: 400, y: y + rand() * 30 - 15), control2: CGPoint(x: 800, y: y + rand() * 30 - 15))
        ctx.strokePath()
    }

    let rim = rims[index % rims.count]
    let r: CGFloat = 470
    ctx.translateBy(x: 600 + rand() * 30 - 15, y: 600 + rand() * 30 - 15)
    ctx.rotate(by: (rand() - 0.5) * 0.5)

    // Shadow and rim.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 14, height: -20), blur: 40, color: NSColor(white: 0, alpha: 0.6).cgColor)
    ctx.setFillColor(rim.cgColor)
    ctx.fillEllipse(in: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
    ctx.restoreGState()
    // Edge inserts.
    ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
    for spot in 0..<8 {
        let a = Double(spot) * .pi / 4 + .pi / 8
        ctx.saveGState()
        ctx.translateBy(x: cos(a) * r * 0.92, y: sin(a) * r * 0.92)
        ctx.rotate(by: a)
        ctx.fill(CGRect(x: -r * 0.08, y: -r * 0.1, width: r * 0.16, height: r * 0.2))
        ctx.restoreGState()
    }
    // Inlay.
    let inlay = r * 0.8
    let paper = NSColor(red: 0.97, green: 0.95, blue: 0.9, alpha: 1)
    ctx.setFillColor(paper.cgColor)
    ctx.fillEllipse(in: CGRect(x: -inlay, y: -inlay, width: 2 * inlay, height: 2 * inlay))
    let ink = rim == rims[5] ? NSColor(white: 0.1, alpha: 1) : rim.blended(withFraction: 0.25, of: .black)!
    ctx.setStrokeColor(ink.cgColor)
    ctx.setLineWidth(6)
    ctx.strokeEllipse(in: CGRect(x: -inlay * 0.94, y: -inlay * 0.94, width: 2 * inlay * 0.94, height: 2 * inlay * 0.94))
    ctx.strokeEllipse(in: CGRect(x: -inlay * 0.6, y: -inlay * 0.6, width: 2 * inlay * 0.6, height: 2 * inlay * 0.6))

    // Center: state, a star, and a year.
    let center = d.region.uppercased() as NSString
    let cAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 150, weight: .black), .foregroundColor: ink]
    let cs = center.size(withAttributes: cAttrs)
    center.draw(at: CGPoint(x: -cs.width / 2, y: -cs.height / 2 - 18), withAttributes: cAttrs)
    let star = NSBezierPath()
    for p in 0..<10 {
        let a = Double(p) * .pi / 5 + .pi / 2
        let rr: CGFloat = p.isMultiple(of: 2) ? 38 : 16
        let pt = CGPoint(x: cos(a) * rr, y: sin(a) * rr + 120)
        p == 0 ? star.move(to: pt) : star.line(to: pt)
    }
    star.close()
    ink.setFill(); star.fill()
    let year = "EST. \(1940 + Int(rand() * 70))" as NSString
    let yAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: ink, .kern: 4]
    let ys = year.size(withAttributes: yAttrs)
    year.draw(at: CGPoint(x: -ys.width / 2, y: -150), withAttributes: yAttrs)

    let name = d.name.replacingOccurrences(of: " Harley-Davidson", with: "").uppercased()
    drawArc(name, ctx: ctx, radius: inlay * 0.77, maxSweep: 2.6, size: 62, color: ink, onTop: true)
    drawArc("\(d.city), \(d.region)".uppercased(), ctx: ctx, radius: inlay * 0.77, maxSweep: 2.2, size: 46, color: ink, onTop: false)

    // Soft light from the top left.
    let light = NSGradient(colors: [NSColor(white: 1, alpha: 0.14), NSColor(white: 1, alpha: 0)])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)); ctx.clip()
    light.draw(in: NSRect(x: -r, y: -r, width: 2 * r, height: 2 * r), angle: -50)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func jpeg(_ rep: NSBitmapImageRep, side: Int, to url: URL) {
    let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
    NSGraphicsContext.current!.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    try! small.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!.write(to: url)
}

var n = 0
for (offset, d) in all.enumerated() where offset.isMultiple(of: 7) {
    let rep = render(d, index: n)
    let file = d.id.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? d.id
    jpeg(rep, side: 1200, to: out.appendingPathComponent(file + ".jpg"))
    jpeg(rep, side: 360, to: out.appendingPathComponent(file + ".thumb.jpg"))
    n += 1
}
print("rendered \(n)")
