import AppKit
import Foundation

// Reuses the menu bar's SF Symbol in a simple macOS app tile. No external artwork.
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets/AppIcon.icns")
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodexBarIcon-\(UUID()).iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }

func render(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 196, yRadius: 196)
    NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.37, blue: 0.82, alpha: 1),
               ending: NSColor(srgbRed: 0.27, green: 0.58, blue: 0.94, alpha: 1))!.draw(in: tile, angle: 90)
    let configuration = NSImage.SymbolConfiguration(pointSize: 600, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else { fatalError("Menu bar symbol unavailable") }
    let width: CGFloat = 630
    let height = width * symbol.size.height / symbol.size.width
    symbol.draw(in: NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2, width: width, height: height))
    return bitmap.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try render(size: base * scale).write(to: folder.appendingPathComponent(name))
    }
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", folder.path, "-o", output.path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
try FileManager.default.createDirectory(atPath: "TestResults", withIntermediateDirectories: true)
try render(size: 1024).write(to: URL(fileURLWithPath: "TestResults/app-icon.png"))
print("Created \(output.path)")
