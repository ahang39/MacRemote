import AppKit
import Foundation

// Self-contained, original MacRemote app artwork (macOS 14+).
// Warm ivory + almond-orange, with a single desktop and a short relay path.
guard CommandLine.arguments.count == 2 else {
    fputs("usage: icon-generator ICONSET_DIR\n", stderr)
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func stroke(_ path: NSBezierPath, _ c: NSColor, width: CGFloat) {
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    c.setStroke()
    path.stroke()
}

func drawIcon() {
    // Transparent margins match modern macOS rounded app icons.
    let card = NSBezierPath(
        roundedRect: NSRect(x: 90, y: 85, width: 844, height: 844),
        xRadius: 200, yRadius: 200
    )
    let shadow = NSShadow()
    shadow.shadowColor = color(84, 62, 45, 0.16)
    shadow.shadowBlurRadius = 43
    shadow.shadowOffset = NSSize(width: 0, height: -13)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    color(250, 242, 233).setFill()
    card.fill()
    NSGraphicsContext.restoreGraphicsState()

    stroke(card, color(220, 202, 182), width: 4)

    let glow = NSBezierPath(
        ovalIn: NSRect(x: 505, y: 400, width: 390, height: 390)
    )
    color(249, 221, 190, 0.52).setFill()
    glow.fill()

    let desktop = NSBezierPath(
        roundedRect: NSRect(x: 225, y: 325, width: 575, height: 395),
        xRadius: 57, yRadius: 57
    )
    color(83, 64, 57).setFill()
    desktop.fill()
    let screen = NSBezierPath(
        roundedRect: NSRect(x: 245, y: 346, width: 535, height: 353),
        xRadius: 41, yRadius: 41
    )
    color(253, 250, 245).setFill()
    screen.fill()

    // A single destination panel with amber visual accent.
    let panel = NSBezierPath(
        roundedRect: NSRect(x: 279, y: 384, width: 465, height: 276),
        xRadius: 25, yRadius: 25
    )
    let gradient = NSGradient(
        starting: color(249, 227, 202),
        ending: color(222, 149, 97)
    )!
    gradient.draw(in: panel, angle: 20)

    let circle = NSBezierPath(ovalIn: NSRect(x: 450, y: 447, width: 124, height: 124))
    color(255, 252, 246, 0.89).setFill()
    circle.fill()

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 476, y: 508))
    arrow.line(to: NSPoint(x: 546, y: 508))
    arrow.move(to: NSPoint(x: 526, y: 528))
    arrow.line(to: NSPoint(x: 547, y: 508))
    arrow.line(to: NSPoint(x: 526, y: 488))
    stroke(arrow, color(161, 89, 51), width: 12)

    let stem = NSBezierPath(
        roundedRect: NSRect(x: 474, y: 266, width: 76, height: 62),
        xRadius: 10, yRadius: 10
    )
    color(83, 64, 57).setFill()
    stem.fill()
    let foot = NSBezierPath(
        roundedRect: NSRect(x: 385, y: 242, width: 254, height: 30),
        xRadius: 15, yRadius: 15
    )
    color(83, 64, 57).setFill()
    foot.fill()
}

func render(_ size: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "MacRemoteIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MacRemoteIcon", code: 2)
    }
    return png
}

for (name, pixels) in [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
] {
    let output = folder.appendingPathComponent(name)
    try render(pixels).write(to: output, options: .atomic)
}
print("MacRemote iconset generated:", folder.path)
