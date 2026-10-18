// SlideRenderer: a Deck's slide drawn into a picture.
//
// What it is for: the window shows the slides as they will be written, before they are
// (with what was carried over marked), and the tests draw them to compare with the
// pictures ProPresenter exported of the same slides. It draws what the Deck says, not
// what PowerPoint will make of the .pptx: the two are close, and the Deck is what this
// app controls. Gradients through letters, soft edges and the finer points of shadows
// are left out; everything that decides where things are and what they say is drawn.
//
// Pictures are decoded once and kept (`ImageCache`), because a carried background is
// the same picture on slide after slide.

import AppKit
import DeckModel
import Foundation

public final class SlideRenderer: @unchecked Sendable {
    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()

    public init() {
        cache.countLimit = 64
    }

    /// The slide as a picture `pixelWidth` across, the slide's own shape.
    public func render(_ slide: Slide, deckSize: Size, pixelWidth: Int) -> CGImage? {
        let scale = Double(pixelWidth) / deckSize.width
        let pixelHeight = max(1, Int((deckSize.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Top-left origin, y down, in slide units.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
        let ns = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        defer { NSGraphicsContext.restoreGraphicsState() }

        let whole = CGRect(x: 0, y: 0, width: deckSize.width, height: deckSize.height)
        context.setFillColor(cg(slide.backgroundColor ?? .black))
        context.fill(whole)

        if let background = slide.background {
            drawMedia(background.media.stillPicture ?? background.media, in: Rect(x: 0, y: 0, width: deckSize.width, height: deckSize.height), mode: background.scale, crop: .zero, context: context)
        }
        for item in slide.items {
            switch item {
            case .shape(let shape): draw(shape, context: context, pixelScale: scale)
            case .picture(let picture): draw(picture, context: context)
            case .video(let video):
                drawMedia(video.media.stillPicture ?? video.media, in: video.frame, mode: video.scale, crop: .zero, context: context)
            }
        }
        return context.makeImage()
    }

    // MARK: - Pieces

    private func draw(_ picture: DeckModel.Picture, context: CGContext) {
        context.saveGState()
        rotate(context, frame: picture.frame, degrees: picture.rotation, flipH: picture.flipHorizontal, flipV: picture.flipVertical)
        context.setAlpha(CGFloat(picture.opacity))
        drawMedia(picture.media, in: picture.frame, mode: picture.scale, crop: picture.crop, context: context)
        context.restoreGState()
    }

    private func draw(_ shape: Shape, context: CGContext, pixelScale: Double) {
        context.saveGState()
        defer { context.restoreGState() }
        rotate(context, frame: shape.frame, degrees: shape.rotation, flipH: shape.flipHorizontal, flipV: shape.flipVertical)
        context.setAlpha(CGFloat(shape.opacity))
        let rect = cgRect(shape.frame)
        let path = self.path(shape.geometry, rect)

        if let s = shape.shadow, shape.fill != nil {
            let r = s.direction * .pi / 180
            // The context is flipped, so +y here is down on the slide; shadow offsets
            // are given in the device's unflipped space, hence the minus.
            context.setShadow(offset: CGSize(width: cos(r) * s.distance * pixelScale, height: -sin(r) * s.distance * pixelScale),
                              blur: CGFloat(s.blurRadius * pixelScale), color: cg(s.color))
        }
        switch shape.fill {
        case .solid(let c) where shape.softEdge > 0:
            // A soft edge, roughly: the shape, shrunk by half the edge, drawn far off the
            // picture with a blurred shadow of itself falling where it should be.
            let inner = self.path(shape.geometry, rect.insetBy(dx: CGFloat(shape.softEdge / 2), dy: CGFloat(shape.softEdge / 2)))
            let away = CGFloat(100_000)
            context.saveGState()
            context.setShadow(offset: CGSize(width: away * CGFloat(pixelScale), height: 0), blur: CGFloat(shape.softEdge * pixelScale), color: cg(c))
            context.translateBy(x: -away, y: 0)
            context.addPath(inner)
            context.setFillColor(cg(c))
            context.fillPath()
            context.restoreGState()
        case .solid(let c):
            context.addPath(path)
            context.setFillColor(cg(c))
            context.fillPath()
        case .gradient(let g):
            context.saveGState()
            context.addPath(path)
            context.clip()
            drawGradient(g, in: rect, context: context)
            context.restoreGState()
        case .picture(let media, let mode):
            context.saveGState()
            context.addPath(path)
            context.clip()
            drawMedia(media, in: shape.frame, mode: mode, crop: .zero, context: context)
            context.restoreGState()
        case nil:
            break
        }
        context.setShadow(offset: .zero, blur: 0, color: nil)
        if let line = shape.line, line.width > 0 {
            context.addPath(path)
            context.setStrokeColor(cg(line.color))
            context.setLineWidth(CGFloat(line.width))
            if !line.dashes.isEmpty { context.setLineDash(phase: 0, lengths: line.dashes.map { CGFloat($0 * line.width) }) }
            context.strokePath()
        }
        if let text = shape.text { draw(text, in: shape.frame) }
    }

    private func draw(_ body: TextBody, in frame: Rect) {
        var fontScale = 1.0
        if case .shrink(let s) = body.autofit { fontScale = s }
        let string = TextLayout.attributedString(body, scale: fontScale)
        let width = frame.width - body.insets.left - body.insets.right
        let available = frame.height - body.insets.top - body.insets.bottom
        guard width > 0 else { return }
        let height = TextLayout.height(of: body, width: width, fontScale: fontScale)
        var y = frame.y + body.insets.top
        switch body.verticalAlignment {
        case .top: break
        case .middle: y += (available - height) / 2
        case .bottom: y += available - height
        }
        string.draw(with: NSRect(x: frame.x + body.insets.left, y: y, width: width, height: max(height, available)),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private func drawGradient(_ g: Gradient, in rect: CGRect, context: CGContext) {
        guard !g.stops.isEmpty, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let colors = g.stops.map { cg($0.color) } as CFArray
        let locations = g.stops.map { CGFloat($0.position) }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) else { return }
        switch g.kind {
        case .linear(let angle):
            // Clockwise from the right, across the box through its centre.
            let r = CGFloat(angle * .pi / 180)
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let across: CGFloat = abs(cos(r)) * rect.width
            let down: CGFloat = abs(sin(r)) * rect.height
            let half = (across + down) / 2
            let d = CGPoint(x: cos(r) * half, y: sin(r) * half)
            context.drawLinearGradient(gradient, start: CGPoint(x: c.x - d.x, y: c.y - d.y), end: CGPoint(x: c.x + d.x, y: c.y + d.y),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radial:
            let c = CGPoint(x: rect.midX, y: rect.midY)
            context.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: max(rect.width, rect.height) / 2,
                                       options: [.drawsAfterEndLocation])
        }
    }

    private func drawMedia(_ media: Media, in frame: Rect, mode: ScaleMode, crop: Insets, context: CGContext) {
        guard let image = image(media), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // Missing, or a video with no still yet: a grey box saying so.
            context.setFillColor(CGColor(gray: 0.25, alpha: 1))
            context.fill(cgRect(frame))
            let label = media.isMissing ? "Missing: \(media.fileName)" : (media.kind == .video ? "▶ \(media.fileName)" : media.fileName)
            let size = max(12, frame.height / 18)
            (label as NSString).draw(in: NSRect(x: frame.x + size, y: frame.y + size, width: frame.width - 2 * size, height: frame.height - 2 * size),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.white])
            return
        }
        var source = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        if crop != .zero {
            source = CGRect(x: source.width * crop.left, y: source.height * crop.top,
                            width: source.width * (1 - crop.left - crop.right), height: source.height * (1 - crop.top - crop.bottom))
        }
        let cropped = crop == .zero ? cgImage : (cgImage.cropping(to: source.integral) ?? cgImage)
        let target = frame.placing(Size(width: source.width, height: source.height), mode)
        context.saveGState()
        context.clip(to: cgRect(frame))
        // The context is flipped: draw the image upside down so that it comes out right.
        context.translateBy(x: CGFloat(target.x), y: CGFloat(target.y + target.height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        context.restoreGState()
    }

    private func image(_ media: Media) -> NSImage? {
        guard media.kind == .image else { return nil }
        let key = "\(media.source.hashValue)-\(media.fileName)" as NSString
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = try? media.source.load(), let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private func rotate(_ context: CGContext, frame: Rect, degrees: Double, flipH: Bool, flipV: Bool) {
        guard degrees != 0 || flipH || flipV else { return }
        let c = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        context.translateBy(x: c.x, y: c.y)
        context.rotate(by: CGFloat(degrees * .pi / 180))
        context.scaleBy(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
        context.translateBy(x: -c.x, y: -c.y)
    }

    private func path(_ geometry: Geometry, _ rect: CGRect) -> CGPath {
        switch geometry {
        case .rectangle:
            return CGPath(rect: rect, transform: nil)
        case .roundedRectangle(let f):
            let r = min(rect.width, rect.height) * CGFloat(f)
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)
        case .polygon(let points):
            let p = CGMutablePath()
            for (k, pt) in points.enumerated() {
                let q = CGPoint(x: rect.minX + rect.width * pt.x, y: rect.minY + rect.height * pt.y)
                if k == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            p.closeSubpath()
            return p
        }
    }

    private func cgRect(_ r: Rect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.width, height: r.height) }

    private func cg(_ c: DeckModel.Color) -> CGColor {
        CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }
}
