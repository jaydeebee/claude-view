// Draw the app icon and build Resources/AppIcon.icns from it.
//
//   swift scripts/make-icon.swift            # writes the .icns
//   swift scripts/make-icon.swift --preview  # plus dist/icon-preview.png
//
// The artwork is code rather than a binary someone has to open a design
// tool to change: the shapes are three numbers each, and the thing an
// icon most needs is to survive being 16 points wide, which is easier to
// check when you can re-render it.
//
// The motif is the app's own: the prompt chevron from a transcript row,
// and the lines of session output beside it.

import AppKit
import CoreGraphics
import Foundation

let tileTop = CGColor(red: 0.886, green: 0.494, blue: 0.353, alpha: 1)  // warm terracotta
let tileBottom = CGColor(red: 0.729, green: 0.353, blue: 0.239, alpha: 1)
let ink = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

/// Apple's squircle is close enough to a rounded rect at this radius, and
/// a rounded rect is exact at every size.
func tilePath(in rect: CGRect) -> CGPath {
    CGPath(
        roundedRect: rect, cornerWidth: rect.width * 0.2237,
        cornerHeight: rect.width * 0.2237, transform: nil)
}

func drawIcon(size: CGFloat, into context: CGContext) {
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // The tile, inset so the icon has the breathing room macOS expects.
    let margin = size * 0.085
    let tile = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    context.saveGState()
    context.addPath(tilePath(in: tile))
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [tileTop, tileBottom] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: tile.minX, y: tile.maxY),
        end: CGPoint(x: tile.maxX, y: tile.minY),
        options: [])
    context.restoreGState()

    // Content box inside the tile.
    let inset = tile.width * 0.21
    let box = tile.insetBy(dx: inset, dy: inset)

    // Transcript lines, longest first, right of the chevron. Below 33
    // points three lines and the gaps between them are four grey smears,
    // so the small sizes carry two heavier ones instead — the icon says
    // the same thing with fewer strokes rather than the same strokes
    // unreadably.
    let small = size <= 32
    let widths: [CGFloat] = small ? [1.0, 0.62] : [1.0, 0.78, 0.52]
    let alphas: [CGFloat] = small ? [1.0, 0.8] : [1.0, 0.86, 0.66]
    let lineHeight = box.height * (small ? 0.22 : 0.155)
    let gap = box.height * (small ? 0.2 : 0.16)
    let chevronWidth = box.width * 0.30
    let linesLeft = box.minX + chevronWidth + box.width * 0.14
    let linesWidth = box.maxX - linesLeft
    let stackHeight =
        lineHeight * CGFloat(widths.count) + gap * CGFloat(widths.count - 1)
    var y = box.midY + stackHeight / 2 - lineHeight

    for (fraction, alpha) in zip(widths, alphas) {
        let bar = CGRect(
            x: linesLeft, y: y, width: linesWidth * fraction, height: lineHeight)
        context.setFillColor(ink.copy(alpha: alpha)!)
        context.addPath(
            CGPath(
                roundedRect: bar, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2,
                transform: nil))
        context.fillPath()
        y -= lineHeight + gap
    }

    // The prompt chevron, weighted to stay legible at 16pt.
    let stroke = box.width * (small ? 0.16 : 0.135)
    let armHeight = stackHeight * 0.62
    let left = box.minX + stroke * 0.5
    context.setStrokeColor(ink)
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.beginPath()
    context.move(to: CGPoint(x: left, y: box.midY + armHeight / 2))
    context.addLine(to: CGPoint(x: left + chevronWidth - stroke, y: box.midY))
    context.addLine(to: CGPoint(x: left, y: box.midY - armHeight / 2))
    context.strokePath()
}

func render(size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawIcon(size: CGFloat(size), into: context)
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

// MARK: Build

let root = URL(filePath: FileManager.default.currentDirectoryPath)
let resources = root.appending(path: "Resources")
let iconset = root.appending(path: "dist/AppIcon.iconset")
try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The set macOS asks for: each nominal size at 1x and 2x.
for nominal in [16, 32, 128, 256, 512] {
    try writePNG(
        render(size: nominal), to: iconset.appending(path: "icon_\(nominal)x\(nominal).png"))
    try writePNG(
        render(size: nominal * 2),
        to: iconset.appending(path: "icon_\(nominal)x\(nominal)@2x.png"))
}

let icns = resources.appending(path: "AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(icns.path)")

if CommandLine.arguments.contains("--preview") {
    // A strip of the sizes that matter, side by side, for looking at.
    let sizes = [512, 128, 64, 32, 16]
    let pad = 24
    let width = sizes.reduce(0, +) + pad * (sizes.count + 1)
    let height = 512 + pad * 2
    let sheet = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    sheet.setFillColor(CGColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1))
    sheet.fill(CGRect(x: 0, y: 0, width: width, height: height))
    var x = pad
    for size in sizes {
        sheet.draw(
            render(size: size),
            in: CGRect(x: x, y: pad, width: size, height: size))
        x += size + pad
    }
    let preview = root.appending(path: "dist/icon-preview.png")
    try writePNG(sheet.makeImage()!, to: preview)
    print("Wrote \(preview.path)")
}
