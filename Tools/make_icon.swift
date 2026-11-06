// Renders the 1024x1024 app icon (a stylized poker chip) with CoreGraphics.
// Usage: swift Tools/make_icon.swift HarleyChipTracker/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let s = CGFloat(size)
let center = CGPoint(x: s / 2, y: s / 2)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Could not create context")
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let orange = rgb(0xF26414)
let deepOrange = rgb(0xC94A08)
let ink = rgb(0x141414)
let cream = rgb(0xFFF4E8)

// Background: dark radial gradient.
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x2B2B2B), rgb(0x050505)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(bg, startCenter: center, startRadius: 0, endCenter: center, endRadius: s * 0.75, options: [.drawsAfterEndLocation])

func disc(_ r: CGFloat, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
}

// Soft drop shadow under the chip.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0x000000, 0.6))
disc(410, deepOrange)
ctx.restoreGState()

// Chip body with a subtle vertical gradient.
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - 400, y: center.y - 400, width: 800, height: 800))
ctx.clip()
let body = CGGradient(colorsSpace: space, colors: [rgb(0xFF7A2E), orange, deepOrange] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(body, start: CGPoint(x: center.x, y: center.y + 400), end: CGPoint(x: center.x, y: center.y - 400), options: [])
ctx.restoreGState()

// Edge inserts: 8 cream blocks around the rim.
let stripes = 8
for i in 0..<stripes {
    let mid = CGFloat(i) * (2 * .pi / CGFloat(stripes)) + .pi / 8
    let half = (2 * .pi / CGFloat(stripes)) * 0.24
    let path = CGMutablePath()
    path.addArc(center: center, radius: 400, startAngle: mid - half, endAngle: mid + half, clockwise: false)
    path.addArc(center: center, radius: 318, startAngle: mid + half, endAngle: mid - half, clockwise: true)
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(cream)
    ctx.fillPath()
}

// Inner ring + dark center.
disc(300, cream)
disc(284, ink)

// Dashed accent ring inside the center.
ctx.setStrokeColor(orange)
ctx.setLineWidth(12)
ctx.setLineDash(phase: 0, lengths: [26, 18])
ctx.strokeEllipse(in: CGRect(x: center.x - 246, y: center.y - 246, width: 492, height: 492))
ctx.setLineDash(phase: 0, lengths: [])

// Checkmark.
let check = CGMutablePath()
check.move(to: CGPoint(x: center.x - 120, y: center.y + 6))
check.addLine(to: CGPoint(x: center.x - 34, y: center.y - 86))
check.addLine(to: CGPoint(x: center.x + 132, y: center.y + 110))
ctx.addPath(check)
ctx.setStrokeColor(cream)
ctx.setLineWidth(64)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()

guard let image = ctx.makeImage() else { fatalError("No image") }
let url = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png")
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not create PNG destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Could not write PNG") }
print("Wrote \(url.path)")
