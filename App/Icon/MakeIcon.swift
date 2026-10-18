// MakeIcon: the app's icon (ProToPPTX.icns), made from the maintainer's picture of it.
//
//     App/Icon/make-icon.sh        (runs this, then iconutil)
//
// The picture (ProToPPTX-source.png, given by the maintainer on 2026-10-19) is the icon
// on a white page, with a soft shadow round it. An icon needs it alone, on nothing,
// at Apple's sizes. So this:
//
//   1. finds the icon's body: the box round every dark pixel (the body is near black,
//      the page near white);
//   2. finds the shape of its corners: Apple's "continuous" rounded square, whose radius
//      is the one whose edge best matches where the body's edge actually runs near a
//      corner (measured row by row);
//   3. cuts the body out along that shape, a pixel inside it, so that none of the white
//      page shows at the edge;
//   4. puts it on Apple's grid for a Mac icon: a body 824 pixels square in a picture of
//      1024, with a soft shadow below, as macOS's own icons have;
//   5. writes that picture, which make-icon.sh turns into every size an .icns holds.
//
// Run with the Swift that comes with Xcode: swift App/Icon/MakeIcon.swift <in> <out.png>

import AppKit
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count == 3, let picture = NSImage(contentsOfFile: arguments[1]) else {
    print("usage: swift MakeIcon.swift <picture.png> <icon-1024.png>")
    exit(2)
}
var whole = NSRect(origin: .zero, size: picture.size)
let source = picture.cgImage(forProposedRect: &whole, context: nil, hints: nil)!
let W = source.width, H = source.height
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// The picture's pixels, top row first.
let page = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: sRGB,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
page.draw(source, in: CGRect(x: 0, y: 0, width: W, height: H))
let pixels = page.data!.bindMemory(to: UInt8.self, capacity: W * H * 4)
func isDark(_ x: Int, _ y: Int) -> Bool {
    let i = (y * W + x) * 4
    return (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3 < 128
}

// 1. The body.
var left = W, right = 0, top = H, bottom = 0
for y in 0..<H {
    for x in 0..<W where isDark(x, y) {
        left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
    }
}
let body = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
print("body: \(Int(body.width)) × \(Int(body.height)) at \(left), \(top)")

// 2. The corners: where the body's edge runs, in from its left, at each depth below its
// top, against where a continuous rounded square of each radius would have it.
let depths = Array(stride(from: 2, through: Int(body.height * 0.3), by: 3))
let measured = depths.map { d -> Double in
    var x = left
    while x < left + Int(body.width) / 2, !isDark(x, top + d) { x += 1 }
    return Double(x - left)
}
func edge(_ shape: Path, atDepth d: Double, width: Double) -> Double {
    // The first point along the row (from the left) that is inside the shape.
    var x = 0.0
    while x < width / 2, !shape.contains(CGPoint(x: x + 0.5, y: d + 0.5)) { x += 0.5 }
    return x
}
var bestRadius = 0.0, bestError = Double.infinity
for fraction in stride(from: 0.15, through: 0.32, by: 0.0025) {
    let radius = fraction * body.width
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: CGRect(origin: .zero, size: body.size))
    let error = zip(depths, measured).reduce(0.0) { $0 + abs(edge(shape, atDepth: Double($1.0), width: body.width) - $1.1) }
    if error < bestError { bestError = error; bestRadius = fraction }
}
print("corner radius: \(String(format: "%.4f", bestRadius)) of the side (mean miss \(String(format: "%.2f", bestError / Double(depths.count))) px)")

// 3 and 4. The body, cut out along its shape a pixel inside, drawn 824 square in 1024,
// over its shadow.
let size = 1024, side = 824.0, margin = (1024 - 824) / 2.0
let icon = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
icon.interpolationQuality = .high
let target = CGRect(x: margin, y: margin, width: side, height: side)
let inset = side / body.width // one pixel of the picture, at the icon's size
let outline = RoundedRectangle(cornerRadius: bestRadius * side, style: .continuous).path(in: target.insetBy(dx: inset, dy: inset)).cgPath

// The shadow: the shape, filled, casting a soft shadow down (y is up in this context).
icon.saveGState()
icon.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
icon.addPath(outline)
icon.setFillColor(CGColor(gray: 0.06, alpha: 1))
icon.fillPath()
icon.restoreGState()

// The body itself over it, clipped to the shape. (The picture's rows run top down and
// the context's bottom up: cropping the picture and drawing it into the target box
// keeps it the right way up.)
let crop = source.cropping(to: body)!
icon.saveGState()
icon.addPath(outline)
icon.clip()
icon.draw(crop, in: target)
icon.restoreGState()

// 5.
let out = URL(fileURLWithPath: arguments[2])
try! NSBitmapImageRep(cgImage: icon.makeImage()!).representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
