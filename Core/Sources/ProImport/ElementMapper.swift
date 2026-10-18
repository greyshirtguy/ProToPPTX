// ElementMapper: one thing on a ProPresenter slide (a text box, a shape, a picture) as
// the Deck's item.
//
// What ProPresenter keeps of an element and where it goes (KNOWN from the protos; the
// conventions marked A GUESS were judged against the slide pictures ProPresenter
// exported of the maintainer's presentations):
//
// - bounds, in slide units from the top left: the item's frame. rotation, in degrees:
//   A GUESS that it is clockwise, as everything on a screen with y down.
// - opacity (0...1), flip, hidden (a hidden element is left out).
// - path: the shape. Rectangles, ellipses and rounded rectangles become the same in
//   PowerPoint; any other shape becomes a polygon of its points (curves are not
//   followed: A GUESS that nobody's slides depend on them).
// - fill, stroke, shadow and feather each have an `enable`; one that is not enabled is
//   kept in the file but not drawn, and is left out here. (KNOWN: the maintainer's
//   files have blue fills and white strokes, not enabled, under every text box.)
// - A fill that is a picture or a video: a Picture or Video item when the element has
//   no words, a shape filled with the picture when it has.
// - text: the words, from the RTF (RTFReader), with what ProPresenter keeps beside the
//   RTF laid on top: capitalization and gradient fills over ranges of the text, an
//   outline (stroke_width, as macOS's text system counts it: percent of the font size,
//   negative for filled and outlined), the text's shadow, margins, vertical alignment,
//   and how the text is fitted (scale_behavior).
//
// Shadows: ProPresenter's angle is A GUESS to be counted as on paper (anticlockwise
// from the right, so 315 is down and to the right); PowerPoint counts clockwise, so the
// direction is 360 less the angle. Opacity is the colour's alpha.

import CoreText
import DeckModel
import DeckPreview
import Foundation
import ProFormat

struct ElementMapper {
    let source: ProSource
    let notes: NoteCollector
    /// Fonts the presentation's own descriptions give a family for, by PostScript name:
    /// the fallback for a font that is not installed here.
    let familiesFromFile: [String: String]

    /// The items one element becomes (none, if nothing of it would be seen).
    func items(_ slideElement: RVData_Slide.Element, slide: Int) -> [Item] {
        let g = slideElement.element
        if g.hidden { return [] }
        let frame = Rect(x: g.bounds.origin.x, y: g.bounds.origin.y, width: g.bounds.size.width, height: g.bounds.size.height)
        let name = g.name.isEmpty ? "Element" : g.name
        let flipH = g.flipMode == .horizontal || g.flipMode == .both
        let flipV = g.flipMode == .vertical || g.flipMode == .both
        // KNOWN: elements ProPresenter made from a PowerPoint slide say 100 for fully
        // opaque; its own say 1.
        let opacity = min(max(g.opacity, 0), 1)

        let text = g.hasText ? textBody(g.text, frame: frame, slide: slide) : nil
        let hasWords = text.map { !$0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false

        // A picture or a video with no words on it.
        if g.fill.enable, case .media(let media)? = g.fill.fillType, !hasWords {
            let found = deckMedia(media, slide: slide)
            switch found.kind {
            case .image:
                let drawing = media.image.drawing
                return [.picture(Picture(
                    name: name, frame: frame, rotation: g.rotation, media: found,
                    scale: Self.scaleMode(drawing.scaleBehavior), crop: Self.crop(drawing),
                    opacity: opacity, flipHorizontal: flipH != drawing.flippedHorizontally, flipVertical: flipV != drawing.flippedVertically
                ))]
            case .video:
                return [.video(Video(
                    name: name, frame: frame, media: found,
                    loops: media.video.transport.playbackBehavior == .loop,
                    muted: media.video.audio.volume == 0 && media.video.hasAudio
                ))]
            case .audio:
                return []
            }
        }

        let fill = self.fill(g.fill, slide: slide)
        let line: Line? = g.stroke.enable && g.stroke.width > 0
            ? Line(width: g.stroke.width, color: Self.color(g.stroke.color), dashes: Self.dashes(g.stroke))
            : nil
        guard hasWords || fill != nil || line != nil else { return [] }

        return [.shape(Shape(
            name: name, frame: frame, rotation: g.rotation, flipHorizontal: flipH, flipVertical: flipV,
            geometry: Self.geometry(g.path), fill: fill, line: line,
            shadow: g.shadow.enable ? Self.shadow(g.shadow) : nil,
            softEdge: g.feather.enable ? g.feather.radius * min(frame.width, frame.height) : 0,
            opacity: opacity,
            text: hasWords ? text : nil
        ))]
    }

    // MARK: - Text

    private func textBody(_ t: RVData_Graphics.Text, frame: Rect, slide: Int) -> TextBody? {
        guard !t.rtfData.isEmpty else { return nil }
        var doc = RTFReader.read(t.rtfData)
        let a = t.attributes

        // Over the whole text: capitalization, an outline, the text's shadow, and a
        // gradient fill given with no range.
        let wholeCaps = Self.capitalization(a.capitalization)
        let outlineWidth = abs(a.strokeWidth)
        let outlineColor = Self.color(a.strokeColor)
        let shadow = t.shadow.enable ? Self.shadow(t.shadow) : nil
        var wholeGradient: Gradient?
        if case .textGradientFill(let gf)? = a.fill, !a.customAttributes.contains(where: { $0.attribute.isGradient }) {
            wholeGradient = Self.gradient(gf.gradient)
        }
        for p in doc.paragraphs.indices {
            for r in doc.paragraphs[p].runs.indices {
                modify(&doc.paragraphs[p].runs[r].style)
            }
            modify(&doc.paragraphs[p].endStyle)
        }
        func modify(_ style: inout RunStyle) {
            if wholeCaps != .none { style.capitalization = wholeCaps }
            if outlineWidth > 0 { style.outline = Line(width: outlineWidth / 100 * style.size, color: outlineColor) }
            if let shadow { style.shadow = shadow }
            if let wholeGradient { style.fill = .gradient(wholeGradient) }
            resolveFont(&style, slide: slide)
        }

        // Over ranges of it.
        for custom in a.customAttributes {
            let start = Int(custom.range.start), end = Int(custom.range.end)
            guard end > start else { continue }
            switch custom.attribute {
            case .capitalization(let c)?:
                let caps = Self.capitalization(c)
                Self.apply(to: &doc, start: start, end: end) { $0.capitalization = caps }
            case .textGradientFill(let gf)?:
                let gradient = Self.gradient(gf.gradient)
                Self.apply(to: &doc, start: start, end: end) { $0.fill = .gradient(gradient) }
            default:
                break
            }
        }

        if t.transform != .none {
            notes.add(.simplified, "Text set to show one word or one line at a time is shown as written", slide: slide)
        }

        // KNOWN (measured against ProPresenter's exported slides, 2026-10-18): the words
        // start 5 units in from each edge of the box beyond its margins: macOS's text
        // container keeps 5 points clear at either end of every line, and ProPresenter
        // keeps the same at the top.
        let pad = Self.textPadding
        let insets = Insets(left: t.margins.left + pad, top: t.margins.top + pad, right: t.margins.right + pad, bottom: t.margins.bottom + pad)
        var body = TextBody(paragraphs: doc.paragraphs, insets: insets, verticalAlignment: Self.vertical(t.verticalAlignment))
        switch t.scaleBehavior {
        case .scaleFontDown, .scaleFontUpDown:
            body.autofit = .shrink(fontScale: TextLayout.shrinkFactor(of: body, in: frame))
        case .adjustContainerHeight:
            body.autofit = .resizeShape
        case .scaleFontUp:
            notes.add(.simplified, "Text set to grow to fill its box is shown at its own size", slide: slide)
        default:
            break
        }
        return body
    }

    /// Fills in the family and the bold and italic switches PowerPoint will name the font
    /// by (FontCatalog says why they are not simply the family macOS shows).
    private func resolveFont(_ style: inout RunStyle, slide: Int) {
        // KNOWN: macOS reads RTF's \b and \i as "the bold (italic) face of this font's
        // family", and so does ProPresenter: "CMGSans-Regular" with \b is drawn in CMG
        // Sans Bold. So the face is changed first, and named after.
        if let face = FontCatalog.face(postScriptName: style.fontName, bold: style.bold, italic: style.italic) {
            style.fontName = face.postScriptName
            style.fontFamily = face.officeTypeface
            style.bold = face.officeBold
            style.italic = face.officeItalic
            return
        }
        // Not installed here: the family the presentation gives, else a guess from the
        // name ("Montserrat-ExtraBold" is of the family "Montserrat"), and RTF's own
        // bold and italic.
        style.fontFamily = familiesFromFile[style.fontName]
            ?? String(style.fontName.split(separator: "-").first ?? Substring(style.fontName))
        notes.add(.missingFont, "The font \(style.fontName) is not installed on this Mac: PowerPoint will show another font until it is", slide: slide)
    }

    /// Lays `change` on the runs between two places in ProPresenter's count of the text,
    /// splitting runs where a range starts or ends inside one.
    static func apply(to doc: inout RTFDocument, start: Int, end: Int, _ change: (inout RunStyle) -> Void) {
        let starts = doc.paragraphStarts
        for p in doc.paragraphs.indices {
            var at = starts[p]
            var runs: [Run] = []
            for run in doc.paragraphs[p].runs {
                let units = Array(run.text.utf16)
                let runStart = at, runEnd = at + units.count
                at = runEnd
                let from = max(start, runStart), to = min(end, runEnd)
                guard from < to else { runs.append(run); continue }
                let cuts = [0, from - runStart, to - runStart, units.count]
                for k in 0..<3 where cuts[k + 1] > cuts[k] {
                    var piece = Run(text: String(decoding: units[cuts[k]..<cuts[k + 1]], as: UTF16.self), style: run.style)
                    if k == 1 { change(&piece.style) }
                    runs.append(piece)
                }
            }
            doc.paragraphs[p].runs = runs
        }
    }

    /// What ProPresenter keeps clear inside a text box's margins, on every side.
    static let textPadding = 5.0

    // MARK: - Fills, lines, shadows

    private func fill(_ f: RVData_Graphics.Fill, slide: Int) -> Fill? {
        guard f.enable else { return nil }
        switch f.fillType {
        case .color(let c)?:
            let color = Self.color(c)
            return color.alpha > 0 ? .solid(color) : nil
        case .gradient(let g)?:
            return .gradient(Self.gradient(g))
        case .media(let m)?:
            let found = deckMedia(m, slide: slide)
            return found.kind == .image ? .picture(found, Self.scaleMode(m.image.drawing.scaleBehavior)) : nil
        case .backgroundEffect?:
            notes.add(.simplified, "A blur or invert behind an element is left out", slide: slide)
            return nil
        case nil:
            return nil
        }
    }

    /// The Deck's media for ProPresenter's, found on this Mac or noted as missing.
    func deckMedia(_ m: RVData_Media, slide: Int) -> Media {
        let kind: Media.Kind
        var natural: Size?
        switch m.typeProperties {
        case .video(let v)?:
            kind = .video
            natural = Self.size(v.drawing.naturalSize)
        case .audio?:
            kind = .audio
        case .image(let i)?:
            kind = .image
            natural = Self.size(i.drawing.naturalSize)
        default:
            kind = .image
        }
        let found = source.locate(m)
        let name = ProSource.fileName(of: m)
        if case .missing = found {
            notes.add(.missingMedia, "The media file \(name) could not be found", slide: slide)
        }
        return Media(kind: kind, source: found, fileName: name, naturalSize: natural)
    }

    static func size(_ s: RVData_Graphics.Size) -> Size? {
        s.width > 0 && s.height > 0 ? Size(width: s.width, height: s.height) : nil
    }

    static func color(_ c: RVData_Color) -> Color {
        Color(red: Double(c.red), green: Double(c.green), blue: Double(c.blue), alpha: Double(c.alpha))
    }

    static func shadow(_ s: RVData_Graphics.Shadow) -> Shadow {
        let base = color(s.color)
        var direction = (360 - s.angle).truncatingRemainder(dividingBy: 360)
        if direction < 0 { direction += 360 }
        return Shadow(color: base.withAlpha(base.alpha * s.opacity), direction: direction, distance: s.offset, blurRadius: s.radius)
    }

    /// ProPresenter's gradient. KNOWN (from the title of one of the maintainer's slides,
    /// against ProPresenter's picture of it): the angle is counted as for shadows,
    /// anticlockwise from the right, with the first stop at the tail; and stops whose
    /// positions are all the same (all nought, as ProPresenter saves a gradient nobody
    /// moved the stops of) are spread evenly. A stop's blend point (where between it and
    /// the next the colour is half way) other than the middle is made by a stop of the
    /// halfway colour there, which is as near as PowerPoint comes.
    static func gradient(_ g: RVData_Graphics.Gradient) -> Gradient {
        var angle = (360 - g.angle).truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        var positions = g.stops.map { min(max($0.position, 0), 1) }
        if positions.count > 1, Set(positions).count == 1 {
            positions = positions.indices.map { Double($0) / Double(positions.count - 1) }
        }
        var stops: [Gradient.Stop] = []
        for (k, stop) in g.stops.enumerated() {
            let c = color(stop.color)
            stops.append(Gradient.Stop(color: c, position: positions[k]))
            if k + 1 < g.stops.count, stop.blendPoint > 0.01, stop.blendPoint < 0.99, abs(stop.blendPoint - 0.5) > 0.01 {
                let next = color(g.stops[k + 1].color)
                let half = Color(red: (c.red + next.red) / 2, green: (c.green + next.green) / 2, blue: (c.blue + next.blue) / 2, alpha: (c.alpha + next.alpha) / 2)
                stops.append(Gradient.Stop(color: half, position: positions[k] + (positions[k + 1] - positions[k]) * stop.blendPoint))
            }
        }
        return Gradient(kind: g.type == .radial ? .radial : .linear(angle: angle), stops: stops)
    }

    static func dashes(_ s: RVData_Graphics.Stroke) -> [Double] {
        switch s.style {
        case .squareDash: return [1, 1]
        case .shortDash: return [3, 1]
        case .longDash: return [8, 3]
        default: return s.pattern.isEmpty ? [] : s.pattern
        }
    }

    static func geometry(_ path: RVData_Graphics.Path) -> Geometry {
        switch path.shape.type {
        case .rectangle, .unknown:
            return .rectangle
        case .ellipse:
            return .ellipse
        case .roundedRectangle:
            // A GUESS: roundness 1 is fully round ends.
            return .roundedRectangle(cornerFraction: min(max(path.shape.roundedRectangle.roundness, 0), 1) * 0.5)
        default:
            let points = path.points.map { Point(x: $0.point.x, y: $0.point.y) }
            return points.count >= 3 ? .polygon(points) : .rectangle
        }
    }

    static func scaleMode(_ s: RVData_Media.ScaleBehavior) -> ScaleMode {
        switch s {
        case .fill: return .fill
        case .stretch: return .stretch
        default: return .fit
        }
    }

    /// A GUESS: crop insets are in pixels of the picture's own size.
    static func crop(_ d: RVData_Media.DrawingProperties) -> Insets {
        guard d.cropEnable, d.naturalSize.width > 0, d.naturalSize.height > 0 else { return .zero }
        let w = d.naturalSize.width, h = d.naturalSize.height
        return Insets(left: d.cropInsets.left / w, top: d.cropInsets.top / h, right: d.cropInsets.right / w, bottom: d.cropInsets.bottom / h)
    }

    static func capitalization(_ c: RVData_Graphics.Text.Attributes.Capitalization) -> RunStyle.Capitalization {
        switch c {
        case .allCaps: return .allCaps
        case .smallCaps: return .smallCaps
        default: return .none
        }
    }

    static func vertical(_ v: RVData_Graphics.Text.VerticalAlignment) -> TextBody.VerticalAlignment {
        switch v {
        case .middle: return .middle
        case .bottom: return .bottom
        default: return .top
        }
    }
}

private extension Optional where Wrapped == RVData_Graphics.Text.Attributes.CustomAttribute.OneOf_Attribute {
    var isGradient: Bool {
        if case .textGradientFill? = self { return true }
        return false
    }
}
