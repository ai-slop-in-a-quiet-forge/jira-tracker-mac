import AppKit
import CoreGraphics
import Foundation

// Generates Chrono's app icon set from code.
//
// Drawing the icon rather than committing a binary asset keeps it reviewable and tweakable, and
// means the whole app builds from source with nothing to check in. Output is a full iconset
// directory, which `iconutil` turns into the .icns the bundle needs.

let brand = CGColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1)   // #2563EB
let accent = CGColor(red: 0.063, green: 0.725, blue: 0.506, alpha: 1)  // #10B981

/// Draws the icon at an arbitrary size. All geometry is expressed against a 1024pt grid and
/// scaled, so every size is pixel-consistent rather than a resampled blur.
func drawIcon(size: CGFloat) -> CGImage? {
    let scale = size / 1024
    guard let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * scale, y: y * scale)
    }

    // macOS app icons sit inside a rounded square with a margin; 824pt on a 1024pt canvas with
    // a 180pt radius matches the system's proportions closely.
    let inset: CGFloat = 100 * scale
    let side = size - inset * 2
    let squircle = CGPath(
        roundedRect: CGRect(x: inset, y: inset, width: side, height: side),
        cornerWidth: 180 * scale,
        cornerHeight: 180 * scale,
        transform: nil
    )
    context.addPath(squircle)
    context.setFillColor(brand)
    context.fillPath()

    // A soft highlight in the upper left, clipped to the squircle, for a little depth.
    context.saveGState()
    context.addPath(squircle)
    context.clip()
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    context.fillEllipse(in: CGRect(
        x: 140 * scale, y: 480 * scale, width: 560 * scale, height: 560 * scale
    ))
    context.restoreGState()

    // Clock face.
    let centre = point(512, 512)
    let radius = 230 * scale
    let stroke = 46 * scale

    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.strokeEllipse(in: CGRect(
        x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2
    ))

    // Hands at ten past ten, the angle that reads as "a clock" at every size.
    context.beginPath()
    context.move(to: centre)
    context.addLine(to: CGPoint(x: centre.x, y: centre.y + radius * 0.60))
    context.move(to: centre)
    context.addLine(to: CGPoint(x: centre.x + radius * 0.46, y: centre.y + radius * 0.22))
    context.strokePath()

    // Centre pin.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    let pin = stroke * 0.62
    context.fillEllipse(in: CGRect(x: centre.x - pin, y: centre.y - pin, width: pin * 2, height: pin * 2))

    // The "running" dot, echoing the menu bar glyph.
    let dot = 62 * scale
    let dotCentre = point(680, 344)
    context.setFillColor(CGColor(red: 0.145, green: 0.388, blue: 0.922, alpha: 1))
    context.fillEllipse(in: CGRect(
        x: dotCentre.x - dot * 1.25, y: dotCentre.y - dot * 1.25, width: dot * 2.5, height: dot * 2.5
    ))
    context.setFillColor(accent)
    context.fillEllipse(in: CGRect(
        x: dotCentre.x - dot, y: dotCentre.y - dot, width: dot * 2, height: dot * 2
    ))

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = NSSize(width: image.width, height: image.height)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url, options: .atomic)
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: GenerateIcons <output-iconset-directory>\n".utf8))
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// The sizes `iconutil` expects in an .iconset, with their required filenames.
let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    guard let image = drawIcon(size: variant.pixels) else {
        FileHandle.standardError.write(Data("could not render \(variant.name)\n".utf8))
        exit(1)
    }
    try write(image, to: outputDirectory.appendingPathComponent(variant.name))
}

print("[chrono] wrote \(variants.count) icon sizes to \(outputDirectory.path)")
