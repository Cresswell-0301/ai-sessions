// Renders the app icon into an .iconset folder for iconutil:
//
//     swift scripts/make-icon.swift <out.iconset>
//
// A rounded square on the macOS icon grid with an indigo-to-violet gradient
// and a white "bell.badge" symbol. scripts/build.sh runs it when
// Resources/AppIcon.icns is missing.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <out.iconset>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

/// One square PNG, `pixels` wide, drawn on a 1024-point design grid.
func renderIcon(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()

    // Apple's grid: an 824-point body centred in the 1024 canvas, radius ~185.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor(srgbRed: 0.27, green: 0.25, blue: 0.78, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.33, green: 0.36, blue: 0.95, alpha: 1), // indigo, top left
        NSColor(srgbRed: 0.56, green: 0.31, blue: 0.91, alpha: 1), // violet
        NSColor(srgbRed: 0.80, green: 0.33, blue: 0.80, alpha: 1), // orchid, bottom right
    ])
    gradient?.draw(in: shape, angle: -50)

    // A soft top highlight gives the flat gradient some depth.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: NSColor.white.withAlphaComponent(0))?
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let configuration = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let size = symbol.size
        let frame = NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2 - 8,
                           width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        let glyphShadow = NSShadow()
        glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        glyphShadow.shadowBlurRadius = 18
        glyphShadow.shadowOffset = NSSize(width: 0, height: -8)
        glyphShadow.set()
        symbol.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
    }
    return bitmap.representation(using: .png, properties: [:])
}

do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            guard let png = renderIcon(pixels: points * scale) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: name])
            }
            try png.write(to: output.appendingPathComponent(name))
        }
    }
    print(output.path)
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
