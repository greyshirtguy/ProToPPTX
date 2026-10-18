// TextLayout: a Deck text box as macOS's text system lays it out, for drawing it into
// the preview and for measuring it.
//
// Measuring is what ProImport uses it for: ProPresenter's "scale text down to fit"
// shrinks the words of a box until they fit, at the moment they are drawn, and does not
// save the size it drew them at. To give PowerPoint the same size (its "shrink text on
// overflow", with the factor written into the file), the words are laid out here at
// their full size, and smaller, until they fit. ProPresenter draws with macOS's own
// text system too, so the two should agree closely; PowerPoint's own layout of the
// same words differs a little, which is why the factor is written as PowerPoint's
// autofit (which it may adjust when the text is edited) and not baked into the sizes.
//
// Fonts are found by their PostScript names. One that is not installed on this Mac
// is drawn in Helvetica of the same size; the name is kept in the Deck regardless.

import AppKit
import DeckModel
import Foundation

public enum TextLayout {
    /// The words of a text box as an attributed string, with every size multiplied by
    /// `scale` (the box's shrink factor times the pixels per slide unit of the picture).
    public static func attributedString(_ body: TextBody, scale: Double = 1) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (k, paragraph) in body.paragraphs.enumerated() {
            let style = paragraphStyle(paragraph, scale: scale)
            if let bullet = paragraph.bullet {
                let marker: String
                switch bullet {
                case .character(let c): marker = c
                // Each numbered paragraph carries its own number (RTFReader reads it from
                // the marker macOS wrote), so it is drawn as it is.
                case .number(_, let number): marker = "\(number)."
                }
                let first = paragraph.runs.first?.style ?? paragraph.endStyle
                result.append(NSAttributedString(string: marker + "\t", attributes: attributes(first, scale: scale, paragraph: style)))
            }
            for run in paragraph.runs {
                let text = run.style.capitalization == .allCaps ? run.text.uppercased() : run.text
                result.append(NSAttributedString(string: text, attributes: attributes(run.style, scale: scale, paragraph: style)))
            }
            if k < body.paragraphs.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: attributes(paragraph.runs.last?.style ?? paragraph.endStyle, scale: scale, paragraph: style)))
            } else if paragraph.runs.isEmpty {
                // An empty last paragraph still has the height of a line, as macOS lays
                // it out; a zero-width space stands for it.
                result.append(NSAttributedString(string: "\u{200B}", attributes: attributes(paragraph.endStyle, scale: scale, paragraph: style)))
            }
        }
        return result
    }

    /// The height the words take when laid out at this width, in the same units.
    public static func height(of body: TextBody, width: Double, fontScale: Double = 1) -> Double {
        let string = attributedString(body, scale: fontScale)
        guard string.length > 0, width > 0 else { return 0 }
        let rect = string.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return Double(rect.height)
    }

    /// One line of a laid-out text box.
    public struct Line: Sendable, Equatable {
        /// Which paragraph of the box it is in.
        public var paragraph: Int
        /// The largest font size on it, in the units laid out (the shrink factor applied).
        public var largestSize: Double
        /// Where its baseline is, from the top of the text.
        public var baseline: Double
    }

    /// The words of a box laid out at this width, line by line, and the height of the
    /// whole, as ProPresenter lays them out: what PPTXWriter needs to put PowerPoint's
    /// lines in the same places.
    public static func lines(of body: TextBody, width: Double, fontScale: Double = 1) -> (lines: [Line], height: Double) {
        let string = attributedString(body, scale: fontScale)
        guard string.length > 0, width > 0 else { return ([], 0) }
        let storage = NSTextStorage(attributedString: string)
        let manager = NSLayoutManager()
        manager.usesFontLeading = true
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        // Where each paragraph starts in the string (a bullet's marker and the line breaks
        // between paragraphs included), to tell which paragraph a line is in.
        let text = string.string as NSString
        var starts: [Int] = [0]
        var search = NSRange(location: 0, length: text.length)
        while true {
            let r = text.range(of: "\n", options: [], range: search)
            if r.location == NSNotFound { break }
            starts.append(r.location + 1)
            search = NSRange(location: r.location + 1, length: text.length - r.location - 1)
        }

        var lines: [Line] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, glyphs, _ in
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            var largest = 0.0
            string.enumerateAttribute(.font, in: characters) { value, _, _ in
                if let f = value as? NSFont { largest = max(largest, Double(f.pointSize)) }
            }
            let paragraph = max(0, (starts.lastIndex { $0 <= characters.location }) ?? 0)
            // The line's baseline, not a raised superscript's: the first character on it
            // that is not moved off the baseline says where it is.
            var glyph = glyphs.location
            var rise = 0.0
            if let found = (characters.location..<NSMaxRange(characters)).first(where: {
                ((string.attribute(.baselineOffset, at: $0, effectiveRange: nil) as? Double) ?? 0) == 0
            }) {
                glyph = manager.glyphIndexForCharacter(at: found)
            } else {
                rise = (string.attribute(.baselineOffset, at: characters.location, effectiveRange: nil) as? Double) ?? 0
            }
            let baseline = Double(rect.minY) + Double(manager.location(forGlyphAt: glyph).y) + rise
            lines.append(Line(paragraph: min(paragraph, body.paragraphs.count - 1), largestSize: largest, baseline: baseline))
        }
        let height = Double(string.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        return (lines, height)
    }

    /// The height macOS gives one line of this font, as a multiple of its size: what
    /// ProPresenter's "single" line spacing is for it (1.2 for Helvetica, 1.22 for CMG
    /// Sans, 1.14 for Georgia).
    public static func lineHeightRatio(_ style: RunStyle) -> Double {
        let size = max(style.size, 1)
        return Double(NSLayoutManager().defaultLineHeight(for: font(style, size: size))) / size
    }

    /// The factor (0...1) by which ProPresenter's "scale text down to fit" would shrink
    /// the words of a box of this size: 1 if they fit as they are.
    public static func shrinkFactor(of body: TextBody, in frame: Rect) -> Double {
        let width = frame.width - body.insets.left - body.insets.right
        let available = frame.height - body.insets.top - body.insets.bottom
        guard width > 0, available > 0 else { return 1 }
        if height(of: body, width: width) <= available + 0.5 { return 1 }
        var low = 0.05, high = 1.0
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if height(of: body, width: width, fontScale: mid) <= available + 0.5 { low = mid } else { high = mid }
        }
        return low
    }

    // MARK: - Attributes

    public static func font(_ style: RunStyle, size: Double) -> NSFont {
        if let font = NSFont(name: style.fontName, size: size) { return font }
        let fallback = NSFont(name: "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size)
        var traits: NSFontTraitMask = []
        if style.bold { traits.insert(.boldFontMask) }
        if style.italic { traits.insert(.italicFontMask) }
        return traits.isEmpty ? fallback : NSFontManager.shared.convert(fallback, toHaveTrait: traits)
    }

    /// The font with its small capitals turned on (lower case as small capitals).
    static func smallCaps(_ font: NSFont) -> NSFont {
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [[.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector]]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: features])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    static func nsColor(_ c: DeckModel.Color) -> NSColor {
        NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    private static func attributes(_ style: RunStyle, scale: Double, paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [:]
        var size = style.size * scale
        // KNOWN (against ProPresenter's exported slides): ProPresenter draws a superscript
        // small and raised, and the line it is on keeps its height, where AppKit's own
        // superscript would make the line taller. A GUESS at the size and the rise, from
        // the look of verse numbers in its pictures: 0.6 of the size, raised 0.38.
        var rise = style.baselineOffset * scale
        if style.superscript != 0 {
            rise += style.superscript > 0 ? 0.38 * size : -0.12 * size
            size *= 0.6
        }
        a[.font] = style.capitalization == .smallCaps ? smallCaps(font(style, size: size)) : font(style, size: size)
        a[.foregroundColor] = nsColor(averageColor(style.fill))
        a[.paragraphStyle] = paragraph
        if style.characterSpacing != 0 { a[.kern] = style.characterSpacing * scale }
        if rise != 0 { a[.baselineOffset] = rise }
        if style.underline {
            a[.underlineStyle] = NSUnderlineStyle.single.rawValue
            if let c = style.underlineColor { a[.underlineColor] = nsColor(c) }
        }
        if style.strikethrough { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let outline = style.outline, style.size > 0 {
            // Negative: drawn filled as well as outlined. In percent of the font size.
            a[.strokeWidth] = -(outline.width / style.size) * 100
            a[.strokeColor] = nsColor(outline.color)
        }
        if let s = style.shadow {
            let shadow = NSShadow()
            let radians = s.direction * .pi / 180
            // An NSShadow's offset is measured with y up, flipped picture or not.
            shadow.shadowOffset = NSSize(width: cos(radians) * s.distance * scale, height: -sin(radians) * s.distance * scale)
            shadow.shadowBlurRadius = s.blurRadius * scale
            shadow.shadowColor = nsColor(s.color)
            a[.shadow] = shadow
        }
        if let h = style.highlight { a[.backgroundColor] = nsColor(h) }
        return a
    }

    /// One colour for a gradient fill: the middle of its stops (the preview does not draw
    /// gradients through letters).
    private static func averageColor(_ fill: TextFill) -> DeckModel.Color {
        switch fill {
        case .solid(let c): return c
        case .gradient(let g):
            guard !g.stops.isEmpty else { return .white }
            let n = Double(g.stops.count)
            return DeckModel.Color(
                red: g.stops.map(\.color.red).reduce(0, +) / n,
                green: g.stops.map(\.color.green).reduce(0, +) / n,
                blue: g.stops.map(\.color.blue).reduce(0, +) / n,
                alpha: g.stops.map(\.color.alpha).reduce(0, +) / n
            )
        }
    }

    /// The height macOS gives a line of the paragraph's largest font.
    private static func naturalLineHeight(_ p: Paragraph, scale: Double) -> Double {
        let styles = p.runs.isEmpty ? [p.endStyle] : p.runs.map(\.style)
        let largest = styles.max { $0.size < $1.size } ?? p.endStyle
        let f = font(largest, size: largest.size * scale)
        return Double(NSLayoutManager().defaultLineHeight(for: f))
    }

    private static func paragraphStyle(_ p: Paragraph, scale: Double) -> NSParagraphStyle {
        let s = NSMutableParagraphStyle()
        switch p.alignment {
        case .left: s.alignment = .left
        case .center: s.alignment = .center
        case .right: s.alignment = .right
        case .justified: s.alignment = .justified
        }
        switch p.lineSpacing {
        case .multiple(let m) where m > 1:
            // As extra leading below each line, as ProPresenter places it (Deck says
            // more); the same distance between lines as macOS's own multiple.
            s.lineSpacing += (m - 1) * naturalLineHeight(p, scale: scale)
        case .multiple(let m): s.lineHeightMultiple = m
        case .exactly(let h): s.minimumLineHeight = h * scale; s.maximumLineHeight = h * scale
        case .atLeast(let h): s.minimumLineHeight = h * scale
        case nil: break
        }
        s.lineSpacing += p.extraLeading * scale
        s.paragraphSpacingBefore = p.spaceBefore * scale
        s.paragraphSpacing = p.spaceAfter * scale
        s.headIndent = p.leftIndent * scale
        s.firstLineHeadIndent = (p.leftIndent + p.firstLineIndent) * scale
        s.tailIndent = -p.rightIndent * scale
        // Only the stops the text gives, then the default interval: macOS's own default
        // stops end at 336 points, after which a tab breaks the line.
        var stops = p.tabStops.filter { $0 > 0 }.map { NSTextTab(textAlignment: .left, location: $0 * scale) }
        if p.bullet != nil, p.leftIndent > 0 { stops.append(NSTextTab(textAlignment: .left, location: p.leftIndent * scale)) }
        s.tabStops = stops.sorted { $0.location < $1.location }
        s.defaultTabInterval = (p.defaultTabInterval > 0 ? p.defaultTabInterval : 72) * scale
        return s
    }
}
