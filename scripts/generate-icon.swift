#!/usr/bin/env swift
import AppKit
import Foundation

// Renders the Claude Pulse app icon at every macOS-required size into a
// directory laid out as an `AppIcon.iconset`. `iconutil -c icns` consumes
// that directory and produces the final `AppIcon.icns` bundle resource.
//
// Usage: generate-icon.swift <output_iconset_dir>

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-icon.swift <output_iconset_dir>\n".utf8))
    exit(1)
}
let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("16x16",     16),  ("16x16@2x",   32),
    ("32x32",     32),  ("32x32@2x",   64),
    ("128x128", 128),  ("128x128@2x", 256),
    ("256x256", 256),  ("256x256@2x", 512),
    ("512x512", 512),  ("512x512@2x", 1024),
]

/// Render directly into an NSBitmapImageRep with explicit pixel dimensions
/// — bypasses NSImage's lockFocus, which on a retina host backs the image
/// at 2× and produces 512px output for a "256px" request.
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    )!
    rep.size = NSSize(width: px, height: px)

    let prev = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.current = prev }

    let p = CGFloat(px)
    let rect = NSRect(x: 0, y: 0, width: p, height: p)

    // Apple's icon "squircle" sits inside transparent padding so the
    // system mask matches Sonoma/Sequoia native apps. ~5% on each side.
    let pad = p * 0.05
    let body = rect.insetBy(dx: pad, dy: pad)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.22, yRadius: body.width * 0.22)

    NSGradient(colors: [
        NSColor(srgbRed: 1.00, green: 0.55, blue: 0.32, alpha: 1.0),
        NSColor(srgbRed: 0.90, green: 0.25, blue: 0.36, alpha: 1.0),
    ])!.draw(in: shape, angle: 135)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let gloss = NSBezierPath()
    gloss.move(to: NSPoint(x: body.minX, y: body.maxY))
    gloss.line(to: NSPoint(x: body.maxX, y: body.maxY))
    gloss.line(to: NSPoint(x: body.maxX, y: body.maxY - body.height * 0.45))
    gloss.curve(
        to: NSPoint(x: body.minX, y: body.maxY - body.height * 0.55),
        controlPoint1: NSPoint(x: body.midX + body.width * 0.3, y: body.maxY - body.height * 0.65),
        controlPoint2: NSPoint(x: body.midX - body.width * 0.3, y: body.maxY - body.height * 0.65)
    )
    gloss.close()
    NSColor.white.withAlphaComponent(0.10).setFill()
    gloss.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Heartbeat — drawn as a path so it stays crisp at every size.
    let baseY = body.midY
    let topY = body.midY + body.height * 0.18
    let bottomY = body.midY - body.height * 0.20
    let leftX = body.minX + body.width * 0.15
    let rightX = body.maxX - body.width * 0.15
    let cw = body.width

    let beat = NSBezierPath()
    beat.move(to: NSPoint(x: leftX,                       y: baseY))
    beat.line(to: NSPoint(x: leftX + cw * 0.18,           y: baseY))
    beat.line(to: NSPoint(x: leftX + cw * 0.28,           y: topY))
    beat.line(to: NSPoint(x: leftX + cw * 0.38,           y: bottomY))
    beat.line(to: NSPoint(x: leftX + cw * 0.48,           y: topY))
    beat.line(to: NSPoint(x: leftX + cw * 0.55,           y: baseY))
    beat.line(to: NSPoint(x: rightX,                      y: baseY))
    beat.lineWidth = max(2.0, p * 0.045)
    beat.lineCapStyle = .round
    beat.lineJoinStyle = .round
    NSColor.white.setStroke()
    beat.stroke()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("PNG encode failed at \(px)px\n".utf8))
        exit(2)
    }
    return png
}

for (name, px) in sizes {
    let path = "\(outDir)/icon_\(name).png"
    try render(px).write(to: URL(fileURLWithPath: path))
}
print("Wrote \(sizes.count) icon variants to \(outDir)")
