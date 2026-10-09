#!/usr/bin/env swift
// AgentWatch's original app icon: a small three-bar activity chart.
import AppKit

private let backgroundTop = NSColor(red: 0.29, green: 0.44, blue: 0.62, alpha: 1)
private let backgroundBottom = NSColor(red: 0.19, green: 0.30, blue: 0.45, alpha: 1)

private func render(_ pixels: Int) -> NSImage {
    let side = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()

    let bounds = NSRect(x: 0, y: 0, width: side, height: side)
    NSBezierPath(roundedRect: bounds, xRadius: side * 0.2237, yRadius: side * 0.2237).addClip()
    NSGradient(starting: backgroundTop, ending: backgroundBottom)?.draw(in: bounds, angle: -90)

    NSColor.white.setFill()
    let bars: [(x: CGFloat, height: CGFloat)] = [
        (0.21, 0.31), (0.44, 0.55), (0.67, 0.42)
    ]
    for bar in bars {
        let rect = NSRect(x: side * bar.x, y: side * 0.23,
                          width: side * 0.12, height: side * bar.height)
        NSBezierPath(roundedRect: rect, xRadius: side * 0.04, yRadius: side * 0.04).fill()
    }

    image.unlockFocus()
    return image
}

private func png(_ image: NSImage, pixels: Int) -> Data {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else {
        fatalError("Could not rasterize app icon")
    }
    bitmap.size = NSSize(width: CGFloat(pixels), height: CGFloat(pixels))
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode app icon")
    }
    return data
}

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentWatch-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x")
]
for (pixels, name) in sizes {
    try png(render(pixels), pixels: pixels)
        .write(to: iconset.appendingPathComponent("\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", "AppIcon.icns", iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
