#!/usr/bin/env swift
import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let iconsetDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ChargeCap.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data? {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }

    let s = CGFloat(size)
    let rect = CGRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84)
    let corner = s * 0.21

    // Rounded squircle background with deep glass emerald-blue gradient
    let bgPath = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let colors = [
        NSColor(calibratedRed: 0.06, green: 0.16, blue: 0.28, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.48, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.12, green: 0.78, blue: 0.54, alpha: 1.0).cgColor
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 0.55, 1.0])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])

    // Glass specular highlight
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
    ctx.fillEllipse(in: CGRect(x: s * 0.0, y: s * 0.52, width: s * 1.0, height: s * 0.55))
    ctx.restoreGState()

    // Outer glass rim
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
    ctx.setLineWidth(s * 0.016)
    ctx.strokePath()
    ctx.restoreGState()

    // Gauge ring (80% Charge Cap arc)
    let center = CGPoint(x: s * 0.5, y: s * 0.5)
    let radius = s * 0.26
    ctx.saveGState()
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    ctx.setLineWidth(s * 0.065)
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(s * 0.065)
    ctx.setLineCap(.round)
    let startAngle: CGFloat = .pi / 2
    let endAngle: CGFloat = startAngle - (.pi * 2 * 0.80)
    ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()

    // Center lightning bolt
    ctx.saveGState()
    ctx.setFillColor(NSColor.white.cgColor)
    let bolt = CGMutablePath()
    bolt.move(to: CGPoint(x: center.x + s * 0.03, y: center.y + s * 0.14))
    bolt.addLine(to: CGPoint(x: center.x - s * 0.09, y: center.y - s * 0.01))
    bolt.addLine(to: CGPoint(x: center.x + s * 0.005, y: center.y - s * 0.01))
    bolt.addLine(to: CGPoint(x: center.x - s * 0.03, y: center.y - s * 0.14))
    bolt.addLine(to: CGPoint(x: center.x + s * 0.09, y: center.y + s * 0.01))
    bolt.addLine(to: CGPoint(x: center.x - s * 0.005, y: center.y + s * 0.01))
    bolt.closeSubpath()
    ctx.addPath(bolt)
    ctx.fillPath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in specs {
    if let data = drawIcon(size: px) {
        try data.write(to: iconsetDir.appendingPathComponent(name))
    }
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", outputPath]
try proc.run()
proc.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetDir)
