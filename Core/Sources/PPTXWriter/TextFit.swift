// TextFit: where PowerPoint will put a text box's lines, and what to write so that it
// puts them where ProPresenter does.
//
// What was measured (2026-10-18), with a deck of text boxes in four fonts (Helvetica,
// CMG Sans, Helvetica Neue, Georgia), two sizes, four line spacings and two vertical
// alignments, drawn by PowerPoint 16 for the Mac and by DeckPreview (which lays text out
// as ProPresenter does, pixel for pixel against ProPresenter's exported slides):
//
// - ProPresenter (macOS's text system) spaces lines by each font's own line height
//   (1.2 × the size for Helvetica, 1.22 for CMG Sans, 1.14 for Georgia), times the
//   paragraph's multiple, with the extra space below each line; the first baseline is
//   the font's own distance down.
// - PowerPoint, given its line spacing as a percentage, spaces lines 1.2 × the size ×
//   the percentage, whatever the font, and puts the first baseline 0.9 × the size × the
//   percentage down. (Given none, it uses the font's metrics in a way that differs from
//   macOS's by a few pixels either way; so a percentage is always written.) Centred or
//   bottom-aligned, the block it centres is its lines' spacing added up, less 0.4 × the
//   size × (the percentage − 1) when that is more than nothing: found by fitting, true
//   to within 4 pixels of a 1080-pixel slide over the fonts and sizes tried.
//
// So each paragraph's percentage is chosen to give ProPresenter's distance between its
// lines exactly, and the difference that remains, where the first line starts, is made
// up by moving the text area: the top inset grows by it and the bottom one shrinks by
// it, so the area keeps its height and the box keeps its place, its size and its
// alignment for whoever edits it in PowerPoint. (The difference can be more than the
// inset; PowerPoint takes an inset less than nought, and keeps it, as the deck's
// pictures show.)

import DeckModel
import DeckPreview
import Foundation

struct TextFit {
    /// For each paragraph, PowerPoint's line spacing as a fraction of its "single"
    /// (1.2 × the font size).
    let spacing: [Double]
    /// How far to move the text down (up, if less than nought), in slide units.
    let shift: Double

    init(_ body: TextBody, frame: Rect) {
        var fontScale = 1.0
        if case .shrink(let f) = body.autofit { fontScale = f }

        spacing = body.paragraphs.map { p in
            let styles = p.runs.isEmpty ? [p.endStyle] : p.runs.map(\.style)
            let largest = styles.max { $0.size < $1.size } ?? p.endStyle
            let size = max(largest.size, 0.1)
            let natural = TextLayout.lineHeightRatio(largest) * size
            var pitch: Double
            switch p.lineSpacing {
            case .multiple(let m)?: pitch = m * natural
            case .exactly(let h)?: pitch = h
            case .atLeast(let h)?: pitch = max(h, natural)
            case nil: pitch = natural
            }
            pitch += p.extraLeading
            return pitch / (1.2 * size)
        }

        let width = frame.width - body.insets.left - body.insets.right
        let available = frame.height - body.insets.top - body.insets.bottom
        let laid = TextLayout.lines(of: body, width: width, fontScale: fontScale)
        guard let first = laid.lines.first, let last = laid.lines.last else {
            shift = 0
            return
        }

        // Where ProPresenter puts the first baseline, from the top of the text area.
        let pro: Double
        switch body.verticalAlignment {
        case .top: pro = first.baseline
        case .middle: pro = (available - laid.height) / 2 + first.baseline
        case .bottom: pro = available - laid.height + first.baseline
        }

        // Where PowerPoint will.
        let spacing = self.spacing
        func m(_ line: TextLayout.Line) -> Double { spacing.indices.contains(line.paragraph) ? spacing[line.paragraph] : 1 }
        let top = 0.9 * m(first) * first.largestSize
        var height = laid.lines.reduce(0) { $0 + 1.2 * m($1) * $1.largestSize }
        height -= 0.4 * max(0, m(last) - 1) * last.largestSize
        for (k, p) in body.paragraphs.enumerated() {
            if k > 0 { height += p.spaceBefore }
            if k < body.paragraphs.count - 1 { height += p.spaceAfter }
        }
        let powerPoint: Double
        switch body.verticalAlignment {
        case .top: powerPoint = top
        case .middle: powerPoint = (available - height) / 2 + top
        case .bottom: powerPoint = available - height + top
        }
        shift = pro - powerPoint
    }
}
