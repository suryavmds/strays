// Assembles the README's animated hero from rendered snapshots.
//
//   swift scripts/make-hero.swift <snapshot-directory> <output.gif>
//
// The frames come from `scripts/snapshots.sh`, which renders the app with
// demo data, so nothing from a real machine ends up in the image.

import AppKit
import ImageIO
import UniformTypeIdentifiers

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else {
    print("usage: swift scripts/make-hero.swift <snapshot-directory> <output.gif>")
    exit(2)
}
let directory = URL(fileURLWithPath: arguments[0])
let output = URL(fileURLWithPath: arguments[1])

// The tour, and how long each stop is shown.
let tour: [(file: String, seconds: Double)] = [
    ("dashboard-cards-dark.png", 2.6),
    ("dashboard-agent-dark.png", 2.4),
    ("dashboard-docker-dark.png", 2.2),
    ("dashboard-table-dark.png", 2.0),
    ("dashboard-timeline-dark.png", 2.0),
    ("dashboard-stacks-dark.png", 2.2),
    ("dashboard-palette-dark.png", 2.0),
]
let width = 1180

guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, tour.count, nil) else {
    print("could not create \(output.path)")
    exit(1)
}
CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

for stop in tour {
    let url = directory.appendingPathComponent(stop.file)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        print("missing frame: \(stop.file)")
        exit(1)
    }
    // Scale down to keep the file a sensible size.
    let height = Int(Double(image.height) * Double(width) / Double(image.width))
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { exit(1) }
    context.interpolationQuality = .high
    // The window's rounded corners are transparent; GIF has no partial alpha.
    context.setFillColor(CGColor(gray: 0.11, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let frame = context.makeImage() else { exit(1) }
    CGImageDestinationAddImage(destination, frame, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: stop.seconds, kCGImagePropertyGIFUnclampedDelayTime: stop.seconds],
    ] as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else {
    print("could not write \(output.path)")
    exit(1)
}
let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
print("Wrote \(output.lastPathComponent): \(tour.count) frames, \(size / 1024) KB")
