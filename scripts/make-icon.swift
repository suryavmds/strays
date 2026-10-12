// Draws Strays' app icon and writes every size the asset catalog needs.
//
//   swift scripts/make-icon.swift Strays/Resources/Assets.xcassets/AppIcon.appiconset
//
// The icon is drawn rather than stored as art so that it can be regenerated
// and tweaked from source: a deep blue-to-cyan squircle with a white paw.

import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.appiconset")

func draw(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let size = CGFloat(pixels)
    // Apple's macOS icon grid: the shape fills 824 of 1024 points.
    let inset = size * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * 0.2237
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // A soft drop shadow, as system icons have.
    NSGraphicsContext.current?.cgContext.setShadow(
        offset: CGSize(width: 0, height: -size * 0.012),
        blur: size * 0.03,
        color: NSColor.black.withAlphaComponent(0.32).cgColor
    )
    NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.62, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

    // Deep blue to cyan, lit from the top left.
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.17, green: 0.42, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.12, green: 0.30, blue: 0.86, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.90, alpha: 1),
    ])?.draw(in: body, angle: -58)

    // A faint glow where the paw sits, for depth.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])?
        .draw(fromCenter: CGPoint(x: body.midX - body.width * 0.12, y: body.midY + body.height * 0.2), radius: 0,
              toCenter: CGPoint(x: body.midX, y: body.midY), radius: body.width * 0.62, options: [])
    NSGraphicsContext.current?.restoreGraphicsState()

    // A hairline highlight along the top edge.
    NSColor.white.withAlphaComponent(0.18).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: size * 0.004, dy: size * 0.004), xRadius: radius, yRadius: radius)
    rim.lineWidth = max(1, size * 0.006)
    rim.stroke()

    // The paw.
    let configuration = NSImage.SymbolConfiguration(pointSize: body.width * 0.46, weight: .semibold)
    if let paw = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
        let tinted = NSImage(size: paw.size, flipped: false) { rect in
            paw.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let origin = CGPoint(x: body.midX - paw.size.width / 2, y: body.midY - paw.size.height / 2 - body.height * 0.01)
        NSGraphicsContext.current?.cgContext.setShadow(
            offset: CGSize(width: 0, height: -size * 0.008),
            blur: size * 0.022,
            color: NSColor(calibratedRed: 0.02, green: 0.10, blue: 0.40, alpha: 0.45).cgColor
        )
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }
    return rep
}

let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

var images: [[String: String]] = []
for (points, scale) in sizes {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let data = draw(pixels: points * scale).representation(using: .png, properties: [:])!
    try data.write(to: output.appendingPathComponent(name))
    images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(sizes.count) icons to \(output.path)")
