#!/usr/bin/env swift
// Scripts/make-icon.swift
// Draws AppIcon.icns. No binary asset is committed; the icon is reproducible
// from source. Usage: swift Scripts/make-icon.swift <output-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Computes the graphite background as a raw RGBA buffer rather than through
// NSGradient/CGGradient. Both dither by default — they add per-pixel noise
// to hide 8-bit banding — which is fine on screen but turns this flat
// two-colour diagonal fill into effectively incompressible PNG data: it took
// the .icns from an expected ~150 KB to over 1.3 MB, and there is no public
// CGContext API to turn dithering off (CGContextSetAllowsDither is not
// exposed to Swift). Computing the linear ramp by hand and writing it
// directly into the bitmap sidesteps the dithering pass entirely; the colour
// range here (0.29 → 0.14 luminance) is narrow enough that the plain,
// undithered ramp shows no visible banding at any icon size.
func gradientImage(pixels: Int, angleDegrees: Double,
                    start: (Double, Double, Double), end: (Double, Double, Double)) -> CGImage {
    let bytesPerPixel = 4
    let bytesPerRow = bytesPerPixel * pixels
    var data = [UInt8](repeating: 0, count: bytesPerRow * pixels)
    let angle = angleDegrees * .pi / 180
    let dx = cos(angle), dy = sin(angle)
    let c = Double(pixels) / 2
    // Project all four corners onto the gradient axis so the ramp spans
    // exactly the square, matching NSGradient's "fill the whole rect" angle
    // semantics instead of an arbitrary fixed span.
    var minT = Double.greatestFiniteMagnitude, maxT = -Double.greatestFiniteMagnitude
    for corner in [(0.0, 0.0), (Double(pixels), 0.0), (0.0, Double(pixels)), (Double(pixels), Double(pixels))] {
        let t = (corner.0 - c) * dx + (corner.1 - c) * dy
        minT = min(minT, t)
        maxT = max(maxT, t)
    }
    for y in 0..<pixels {
        for x in 0..<pixels {
            let t = (Double(x) - c) * dx + (Double(y) - c) * dy
            let f = (t - minT) / (maxT - minT)
            let r = start.0 + (end.0 - start.0) * f
            let g = start.1 + (end.1 - start.1) * f
            let b = start.2 + (end.2 - start.2) * f
            let off = y * bytesPerRow + x * bytesPerPixel
            data[off + 0] = UInt8(max(0, min(255, (r * 255).rounded())))
            data[off + 1] = UInt8(max(0, min(255, (g * 255).rounded())))
            data[off + 2] = UInt8(max(0, min(255, (b * 255).rounded())))
            data[off + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(data) as CFData)!
    return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false,
                    intent: .defaultIntent)!
}

// Renders straight into a pixel-exact NSBitmapImageRep rather than going
// through NSImage(size:flipped:drawingHandler:). That convenience initialiser
// rasterises at the screen's backing scale factor (2x on this Retina host)
// and resamples down to the requested pixel size when the TIFF/PNG
// representation is pulled — the resample injects further per-pixel noise.
// Drawing directly into a bitmap-backed NSGraphicsContext is 1:1, no resample.
func draw(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                isPlanar: false, colorSpaceName: .deviceRGB,
                                bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)

    // macOS's icon grid does not fill the canvas: on a 1024pt tile the rounded
    // rect is 824pt square, centred, with a 185.4pt corner radius. That inset
    // is what makes icons line up optically beside each other in Finder, the
    // Dock and Login Items. Drawn edge to edge, this icon rendered visibly
    // larger than every neighbour.
    let inset = size * 100 / 1024
    let rect = canvas.insetBy(dx: inset, dy: inset)
    let radius = rect.width * 185.4 / 824

    // Rounded-rect graphite background, matching macOS icon geometry. The
    // clip still comes from Core Graphics (antialiased rounded corners); only
    // the gradient fill inside it is hand-computed.
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()
    // Drawn across the whole canvas and clipped, rather than generated at the
    // inset rect's fractional pixel size and resampled into it -- resampling
    // is the noise this hand-computed ramp exists to avoid.
    let background = gradientImage(pixels: px, angleDegrees: -70,
                                    start: (0.29, 0.29, 0.32), end: (0.14, 0.14, 0.15))
    ctx.draw(background, in: canvas)

    // Waveform: five rounded bars, symmetric about the centre.
    // Values are half-length as a fraction of the rounded rect (not the
    // canvas, so the art keeps its proportions inside the inset badge); the
    // tallest bar (0.31 → 62% of the badge height) leaves margin at top/bottom
    // so it reads as a rounded bar, not a column that gets clipped square by
    // the badge's edges.
    let heights: [CGFloat] = [0.085, 0.21, 0.31, 0.17, 0.055]
    let barWidth = rect.width * 0.077
    let gap = rect.width * 0.153
    let totalWidth = CGFloat(heights.count - 1) * gap
    NSColor(calibratedWhite: 0.96, alpha: 1).setStroke()
    for (i, h) in heights.enumerated() {
        let x = rect.midX - totalWidth / 2 + CGFloat(i) * gap
        let bar = NSBezierPath()
        bar.lineWidth = barWidth
        bar.lineCapStyle = .round
        bar.move(to: NSPoint(x: x, y: rect.midY - rect.width * h))
        bar.line(to: NSPoint(x: x, y: rect.midY + rect.width * h))
        bar.stroke()
    }

    NSGraphicsContext.current?.flushGraphics()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try png.write(to: url)
}

// The exact set `iconutil` requires.
let sizes: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),
                           (256,1),(256,2),(512,1),(512,2)]
for (pt, scale) in sizes {
    let px = CGFloat(pt * scale)
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try write(draw(size: px), to: iconset.appendingPathComponent(name))
}
print("wrote \(iconset.path)")
