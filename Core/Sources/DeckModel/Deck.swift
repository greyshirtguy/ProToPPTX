// Deck: what goes on the PowerPoint slides, said without PowerPoint's XML and without
// ProPresenter's protobufs.
//
// Why there is a middle: the reader of ProPresenter's files (ProImport) and the writer
// of PowerPoint's (PPTXWriter) are each hard enough without knowing about the other.
// ProImport turns a presentation into a Deck; PPTXWriter turns a Deck into a .pptx;
// DeckPreview draws a Deck's slide into a picture, so that the window can show what
// will be written, and the tests can look at it.
//
// Units: every length is in the units of the ProPresenter slide it came from: its
// pixels, 1920 across on a 1080p slide. A font size is in the same units, because a
// ProPresenter font size of 72 is 72 of those pixels tall on screen. The writer scales
// all of it to the size of the PowerPoint slide in one place (PPTXWriter/Units.swift).
//
// Colours are sRGB, 0...1 each, with alpha. Angles are degrees, clockwise.
//
// Everything here is a plain value: nothing in it reads a file until it is asked to
// (MediaSource.load), so a Deck can be made, looked at and thrown away cheaply.

import Foundation

/// A whole slide show.
public struct Deck: Sendable, Equatable {
    /// The size of every slide, in slide units (1920 × 1080 for a 1080p presentation).
    public var size: Size
    /// The title written into the file's properties.
    public var title: String
    public var slides: [Slide]
    /// PowerPoint's sections: a name and the slide each starts at. Optional; PowerPoint
    /// shows them in its slide list, which is where ProPresenter's groups go.
    public var sections: [Section]

    public init(size: Size, title: String, slides: [Slide] = [], sections: [Section] = []) {
        self.size = size
        self.title = title
        self.slides = slides
        self.sections = sections
    }
}

public struct Section: Sendable, Equatable {
    public var name: String
    public var firstSlide: Int

    public init(name: String, firstSlide: Int) {
        self.name = name
        self.firstSlide = firstSlide
    }
}

/// One slide.
public struct Slide: Sendable, Equatable {
    /// The colour under everything, if the slide has one of its own.
    public var backgroundColor: Color?
    /// What fills the slide from behind: the media ProPresenter would have on its
    /// background layer while this slide is up. See `BackgroundMedia`.
    public var background: BackgroundMedia?
    /// What is drawn on the slide, back to front.
    public var items: [Item]
    /// The speaker notes, as plain text.
    public var notes: String
    /// What the window's preview says under the slide: where it came from in
    /// ProPresenter ("Group · Slide name"). Not written to the file.
    public var caption: String

    public init(backgroundColor: Color? = nil, background: BackgroundMedia? = nil, items: [Item] = [], notes: String = "", caption: String = "") {
        self.backgroundColor = backgroundColor
        self.background = background
        self.items = items
        self.notes = notes
        self.caption = caption
    }
}

/// The media behind a slide, and why it is there.
public struct BackgroundMedia: Sendable, Equatable {
    public var media: Media
    /// How it is fitted to the slide.
    public var scale: ScaleMode
    /// True when this slide had no media cue of its own and the media is the one left on
    /// screen by an earlier slide (the "keep background media" option).
    public var isCarriedOver: Bool
    /// The number (from 1) of the slide whose cue put it there, in the deck as written.
    public var fromSlide: Int?

    public init(media: Media, scale: ScaleMode, isCarriedOver: Bool = false, fromSlide: Int? = nil) {
        self.media = media
        self.scale = scale
        self.isCarriedOver = isCarriedOver
        self.fromSlide = fromSlide
    }
}

/// How a picture or video is fitted into the box it is given.
public enum ScaleMode: String, Sendable, Equatable, Codable {
    /// All of it shows, as large as fits; the rest of the box is left empty.
    case fit
    /// The box is filled; what does not fit is cut off.
    case fill
    /// Stretched to the box, whatever its shape.
    case stretch
}

/// A thing on a slide.
public enum Item: Sendable, Equatable {
    case shape(Shape)
    case picture(Picture)
    case video(Video)
}

// MARK: - Shapes and text

public struct Shape: Sendable, Equatable {
    public var name: String
    public var frame: Rect
    /// Degrees, clockwise, about the centre.
    public var rotation: Double
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public var geometry: Geometry
    public var fill: Fill?
    public var line: Line?
    public var shadow: Shadow?
    /// The width of a soft edge, in slide units; 0 for none.
    public var softEdge: Double
    /// 0...1, applied to the whole shape.
    public var opacity: Double
    public var text: TextBody?

    public init(
        name: String, frame: Rect, rotation: Double = 0, flipHorizontal: Bool = false, flipVertical: Bool = false,
        geometry: Geometry = .rectangle, fill: Fill? = nil, line: Line? = nil, shadow: Shadow? = nil,
        softEdge: Double = 0, opacity: Double = 1, text: TextBody? = nil
    ) {
        self.name = name
        self.frame = frame
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.geometry = geometry
        self.fill = fill
        self.line = line
        self.shadow = shadow
        self.softEdge = softEdge
        self.opacity = opacity
        self.text = text
    }
}

public enum Geometry: Sendable, Equatable {
    case rectangle
    /// Corner radius as a fraction of the shorter side (0...0.5).
    case roundedRectangle(cornerFraction: Double)
    case ellipse
    /// A closed path of points in 0...1 of the frame (straight lines between them).
    case polygon([Point])
}

public enum Fill: Sendable, Equatable {
    case solid(Color)
    case gradient(Gradient)
    /// A picture filling the shape.
    case picture(Media, ScaleMode)
}

public struct Gradient: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case linear(angle: Double)
        case radial
    }

    public struct Stop: Sendable, Equatable {
        public var color: Color
        /// 0...1 along the gradient.
        public var position: Double

        public init(color: Color, position: Double) {
            self.color = color
            self.position = position
        }
    }

    public var kind: Kind
    public var stops: [Stop]

    public init(kind: Kind, stops: [Stop]) {
        self.kind = kind
        self.stops = stops
    }
}

public struct Line: Sendable, Equatable {
    public var width: Double
    public var color: Color
    /// Dash and gap lengths as multiples of the width; empty for a solid line.
    public var dashes: [Double]

    public init(width: Double, color: Color, dashes: [Double] = []) {
        self.width = width
        self.color = color
        self.dashes = dashes
    }
}

public struct Shadow: Sendable, Equatable {
    public var color: Color
    /// The direction the shadow falls, in degrees, clockwise from the right (so 45 is
    /// down and to the right, as PowerPoint counts).
    public var direction: Double
    public var distance: Double
    public var blurRadius: Double

    public init(color: Color, direction: Double, distance: Double, blurRadius: Double) {
        self.color = color
        self.direction = direction
        self.distance = distance
        self.blurRadius = blurRadius
    }
}

public struct TextBody: Sendable, Equatable {
    public enum VerticalAlignment: Sendable, Equatable { case top, middle, bottom }

    public enum Autofit: Sendable, Equatable {
        /// The text keeps its size and may run out of the box.
        case none
        /// The text is drawn smaller to fit the box, by this factor (1 for not at all
        /// yet); PowerPoint's "Shrink text on overflow".
        case shrink(fontScale: Double)
        /// The box grows to fit the text; PowerPoint's "Resize shape to fit text".
        case resizeShape
    }

    public var paragraphs: [Paragraph]
    public var insets: Insets
    public var verticalAlignment: VerticalAlignment
    public var autofit: Autofit
    /// Whether lines wrap at the box's edge.
    public var wraps: Bool

    public init(paragraphs: [Paragraph], insets: Insets = .zero, verticalAlignment: VerticalAlignment = .top, autofit: Autofit = .none, wraps: Bool = true) {
        self.paragraphs = paragraphs
        self.insets = insets
        self.verticalAlignment = verticalAlignment
        self.autofit = autofit
        self.wraps = wraps
    }

    /// The words, with paragraphs on lines of their own.
    public var plainText: String {
        paragraphs.map { $0.runs.map(\.text).joined() }.joined(separator: "\n")
    }
}

public struct Paragraph: Sendable, Equatable {
    public enum Alignment: Sendable, Equatable { case left, center, right, justified }

    public enum LineSpacing: Sendable, Equatable {
        /// A multiple of the font's own line height (1 is single). As ProPresenter lays
        /// it out: the lines are that far apart, and the extra space is below each line,
        /// the last one included, not above it. (macOS's own text system puts it above;
        /// DeckPreview and PPTXWriter each make up the difference.)
        case multiple(Double)
        /// A fixed line height, in slide units.
        case exactly(Double)
        /// At least this line height, in slide units.
        case atLeast(Double)
    }

    public enum Bullet: Sendable, Equatable {
        case character(String)
        /// A number in a style PowerPoint knows ("arabicPeriod", "alphaLcParenR", ...),
        /// starting at the given number.
        case number(scheme: String, startAt: Int)
    }

    public var alignment: Alignment
    public var lineSpacing: LineSpacing?
    /// Extra space between lines, in slide units, beyond `lineSpacing`
    /// (Cocoa's lineSpacing; PowerPoint has no such thing and the writer folds it in).
    public var extraLeading: Double
    public var spaceBefore: Double
    public var spaceAfter: Double
    /// Where wrapped lines start, from the box's left inset.
    public var leftIndent: Double
    /// Where the first line starts, relative to `leftIndent` (negative for a hanging indent).
    public var firstLineIndent: Double
    public var rightIndent: Double
    public var bullet: Bullet?
    /// Tab stops, in slide units from the left inset.
    public var tabStops: [Double]
    /// The distance between tab stops after the last of `tabStops`; 0 for the default of
    /// whatever draws it.
    public var defaultTabInterval: Double
    /// The runs of text. A line break inside a paragraph is "\u{2028}" in a run's text.
    public var runs: [Run]
    /// The style of the paragraph's end, which gives an empty paragraph its height.
    public var endStyle: RunStyle

    public init(
        alignment: Alignment = .left, lineSpacing: LineSpacing? = nil, extraLeading: Double = 0,
        spaceBefore: Double = 0, spaceAfter: Double = 0, leftIndent: Double = 0, firstLineIndent: Double = 0,
        rightIndent: Double = 0, bullet: Bullet? = nil, tabStops: [Double] = [], defaultTabInterval: Double = 0,
        runs: [Run] = [], endStyle: RunStyle = RunStyle()
    ) {
        self.alignment = alignment
        self.lineSpacing = lineSpacing
        self.extraLeading = extraLeading
        self.spaceBefore = spaceBefore
        self.spaceAfter = spaceAfter
        self.leftIndent = leftIndent
        self.firstLineIndent = firstLineIndent
        self.rightIndent = rightIndent
        self.bullet = bullet
        self.tabStops = tabStops
        self.defaultTabInterval = defaultTabInterval
        self.runs = runs
        self.endStyle = endStyle
    }
}

public struct Run: Sendable, Equatable {
    public var text: String
    public var style: RunStyle

    public init(text: String, style: RunStyle) {
        self.text = text
        self.style = style
    }
}

public struct RunStyle: Sendable, Equatable {
    public enum Capitalization: Sendable, Equatable { case none, allCaps, smallCaps }

    /// The PostScript name of the font ("HelveticaNeue-Bold"): what the preview draws
    /// with, and what the writer works out PowerPoint's name for the font from.
    public var fontName: String
    /// The family ("Helvetica Neue"), when known.
    public var fontFamily: String
    public var size: Double
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var underlineColor: Color?
    public var strikethrough: Bool
    public var fill: TextFill
    /// An outline drawn round each letter.
    public var outline: Line?
    public var shadow: Shadow?
    /// Extra space after each character, in slide units (negative to tighten).
    public var characterSpacing: Double
    /// Raised (positive) or lowered (negative) from the baseline, in slide units.
    public var baselineOffset: Double
    /// 1 for superscript, -1 for subscript, 0 for neither.
    public var superscript: Int
    public var capitalization: Capitalization
    /// A highlight behind the letters.
    public var highlight: Color?

    public init(
        fontName: String = "Helvetica", fontFamily: String = "Helvetica", size: Double = 12, bold: Bool = false, italic: Bool = false,
        underline: Bool = false, underlineColor: Color? = nil, strikethrough: Bool = false, fill: TextFill = .solid(.black),
        outline: Line? = nil, shadow: Shadow? = nil, characterSpacing: Double = 0, baselineOffset: Double = 0,
        superscript: Int = 0, capitalization: Capitalization = .none, highlight: Color? = nil
    ) {
        self.fontName = fontName
        self.fontFamily = fontFamily
        self.size = size
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.underlineColor = underlineColor
        self.strikethrough = strikethrough
        self.fill = fill
        self.outline = outline
        self.shadow = shadow
        self.characterSpacing = characterSpacing
        self.baselineOffset = baselineOffset
        self.superscript = superscript
        self.capitalization = capitalization
        self.highlight = highlight
    }
}

public enum TextFill: Sendable, Equatable {
    case solid(Color)
    case gradient(Gradient)

    /// One colour that stands for the fill, for things that can only take one.
    public var representativeColor: Color {
        switch self {
        case .solid(let c): return c
        case .gradient(let g): return g.stops.first?.color ?? .white
        }
    }
}

// MARK: - Pictures and video

public struct Picture: Sendable, Equatable {
    public var name: String
    public var frame: Rect
    public var rotation: Double
    public var media: Media
    public var scale: ScaleMode
    /// Fractions cut from each side of the picture before it is fitted (0...1).
    public var crop: Insets
    public var opacity: Double
    public var flipHorizontal: Bool
    public var flipVertical: Bool

    public init(name: String, frame: Rect, rotation: Double = 0, media: Media, scale: ScaleMode = .stretch, crop: Insets = .zero, opacity: Double = 1, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.name = name
        self.frame = frame
        self.rotation = rotation
        self.media = media
        self.scale = scale
        self.crop = crop
        self.opacity = opacity
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }
}

public struct Video: Sendable, Equatable {
    public var name: String
    public var frame: Rect
    public var media: Media
    /// How it is fitted into its frame.
    public var scale: ScaleMode
    public var loops: Bool
    /// Starts by itself when the slide comes up, as it would in ProPresenter.
    public var playsAutomatically: Bool
    public var muted: Bool

    public init(name: String, frame: Rect, media: Media, scale: ScaleMode = .fit, loops: Bool = false, playsAutomatically: Bool = true, muted: Bool = false) {
        self.name = name
        self.frame = frame
        self.media = media
        self.scale = scale
        self.loops = loops
        self.playsAutomatically = playsAutomatically
        self.muted = muted
    }
}
