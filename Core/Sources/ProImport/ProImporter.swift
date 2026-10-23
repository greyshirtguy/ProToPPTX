// ProImporter: a .pro or .probundle read into a Deck, slide for slide as ProPresenter
// would show them, with the options the person chose.
//
// For each slide, in play order (PlayOrder), back to front:
//
//   1. The colour under everything: black, as ProPresenter's output is where nothing
//      is drawn; or the presentation's background colour, if it has one turned on.
//   2. The background media: the slide's own media cue's, or, with "keep background
//      media" on, the one left on screen by an earlier slide (MediaLayers).
//   3. A slide's own background colour, if it draws one. It is part of the slide
//      layer, which is above the media in ProPresenter, so it covers the media; when
//      there is no media it simply becomes the slide's colour.
//   4. Foreground media of the slide's own cue (MediaLayers says why it is put here).
//   5. The slide's elements, from the last the slide lists to the first: ProPresenter
//      lists them front to back (ElementMapper).
//
// Notes go to the speaker notes, and the slide's group and name to the preview's
// caption. ProPresenter's groups become PowerPoint's sections, unless they say nothing:
// a sermon whose groups are all called "Group", or nothing, gets none.

import DeckModel
import Foundation
import ProFormat

public struct ImportResult: Sendable {
    public var deck: Deck
    public var notes: [ConversionNote]
    /// The arrangement whose order was followed, if one was.
    public var arrangement: String?

    public init(deck: Deck, notes: [ConversionNote], arrangement: String?) {
        self.deck = deck
        self.notes = notes
        self.arrangement = arrangement
    }
}

public enum ProImporter {
    /// A .pro or .probundle file. `workspaceFolder` is the workspace it is in, if it is
    /// in one: media named "in the workspace" is looked for there first.
    public static func read(_ url: URL, workspaceFolder: URL? = nil, arrangement: String? = nil, options: ConversionOptions) throws -> ImportResult {
        try read(ProSource(url: url, workspaceFolder: workspaceFolder), arrangement: arrangement, options: options)
    }

    /// A presentation ProPresenter keeps other than as a file (in a database
    /// workspace), already read. `name` is what to call it if it has no name.
    public static func read(_ presentation: RVData_Presentation, name: String, workspaceFolder: URL?, arrangement: String? = nil, options: ConversionOptions) throws -> ImportResult {
        try read(ProSource(presentation: presentation, name: name, workspaceFolder: workspaceFolder), arrangement: arrangement, options: options)
    }

    /// `arrangement`, an arrangement's id, is the one a playlist's item chose; it is
    /// followed in place of the presentation's own, if the options say to follow one.
    static func read(_ source: ProSource, arrangement chosen: String?, options: ConversionOptions) throws -> ImportResult {
        let presentation = source.presentation
        let collector = NoteCollector()

        var (played, arrangement) = PlayOrder.cues(of: presentation, followArrangement: options.followArrangement, chosen: chosen)
        if options.skipDisabledSlides { played = played.filter(\.cue.isEnabled) }

        let mapper = ElementMapper(source: source, notes: collector, familiesFromFile: familyNames(in: presentation))
        let size = slideSize(presentation, played)
        var deck = Deck(size: size, title: presentation.name.isEmpty ? source.name : presentation.name)

        var underColor = Color.black
        if presentation.background.isEnabled, case .color(let c)? = presentation.background.fill {
            underColor = ElementMapper.color(c)
        }

        var layers = MediaLayers()
        for (k, item) in played.enumerated() {
            let number = k + 1
            let shown = layers.click(item.cue, slideNumber: number)
            var slide = Slide(backgroundColor: underColor)
            let base = presentationSlide(of: item.cue)

            // The background media.
            if let cue = shown.own ?? (options.carryBackgroundForward ? shown.live : nil) {
                let media = mapper.deckMedia(cue.media, slide: number)
                if media.kind != .audio {
                    slide.background = BackgroundMedia(
                        media: media, scale: scale(of: cue.media),
                        isCarriedOver: shown.own == nil, fromSlide: cue.slideNumber
                    )
                }
            }

            // The slide's own colour.
            if let base, base.baseSlide.drawsBackgroundColor {
                let color = ElementMapper.color(base.baseSlide.backgroundColor)
                if slide.background == nil {
                    slide.backgroundColor = color
                } else if color.alpha > 0 {
                    slide.items.append(.shape(Shape(name: "Slide colour", frame: Rect(x: 0, y: 0, width: size.width, height: size.height), fill: .solid(color))))
                }
            }

            // Foreground media.
            if let cue = shown.foreground {
                let media = mapper.deckMedia(cue.media, slide: number)
                let whole = Rect(x: 0, y: 0, width: size.width, height: size.height)
                switch media.kind {
                case .image:
                    slide.items.append(.picture(Picture(name: "Foreground media", frame: whole, media: media, scale: scale(of: cue.media))))
                case .video:
                    slide.items.append(.video(video(cue, media: media, frame: whole)))
                case .audio:
                    break
                }
            }

            // The slide's own elements. KNOWN (from the slide pictures ProPresenter
            // exported, 2026-10-18): a slide lists its elements front to back, the
            // first on top. A Deck lists them back to front.
            if let base {
                for element in base.baseSlide.elements.reversed() {
                    slide.items.append(contentsOf: mapper.items(element, slide: number))
                }
                if options.includeNotes, !base.notes.rtfData.isEmpty {
                    let doc = RTFReader.read(base.notes.rtfData)
                    slide.notes = doc.paragraphs.map { $0.runs.map(\.text).joined() }.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            for macro in shown.macros {
                collector.add(.macro, "The macro \"\(macro)\" is not followed: if it changes the background, check these slides", slide: number)
            }
            for sound in shown.audio {
                collector.add(.audio, "The sound \(sound) is not put into the deck", slide: number)
            }
            if !item.cue.isEnabled {
                collector.add(.simplified, "Slides turned off in ProPresenter are included", slide: number)
            }

            slide.caption = caption(item, slide)
            deck.slides.append(slide)
        }

        if options.groupsAsSections {
            deck.sections = sections(played)
        }
        return ImportResult(deck: deck, notes: collector.all, arrangement: arrangement)
    }

    // MARK: -

    /// What the preview says under a slide: its group (when the group has a name worth
    /// showing) and its first line of words, or the slide's own name when it has none.
    /// (Slides ProPresenter made from a PowerPoint are named "Slide rId4 2 1", and
    /// slides made from a picture by the picture's file name: the words say more.)
    private static func caption(_ item: PlayedCue, _ slide: Slide) -> String {
        var words = ""
        for case .shape(let shape) in slide.items.reversed() {
            if let text = shape.text?.plainText.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                words = text.trimmingCharacters(in: .whitespaces)
                break
            }
        }
        let label = !words.isEmpty ? words : (item.cue.name.isEmpty ? "Slide \(item.indexInGroup + 1)" : item.cue.name)
        let group = item.groupName.trimmingCharacters(in: .whitespaces)
        return group.isEmpty || group.lowercased() == "group" ? label : "\(group) · \(label)"
    }

    static func presentationSlide(of cue: RVData_Cue) -> RVData_PresentationSlide? {
        for action in cue.actions where action.type == .presentationSlide {
            if case .presentation(let slide)? = action.slide.slide { return slide }
        }
        return nil
    }

    /// The size of the slides: the first one's that says, else 1920 × 1080.
    private static func slideSize(_ presentation: RVData_Presentation, _ played: [PlayedCue]) -> Size {
        let all = played.map(\.cue) + presentation.cues
        for cue in all {
            if let s = presentationSlide(of: cue)?.baseSlide.size, s.width > 0, s.height > 0 {
                return Size(width: s.width, height: s.height)
            }
        }
        return Size(width: 1920, height: 1080)
    }

    private static func scale(of media: RVData_Media) -> ScaleMode {
        switch media.typeProperties {
        case .video(let v)?: return ElementMapper.scaleMode(v.drawing.scaleBehavior)
        case .image(let i)?: return ElementMapper.scaleMode(i.drawing.scaleBehavior)
        default: return .fit
        }
    }

    private static func video(_ cue: MediaCue, media: Media, frame: Rect) -> Video {
        let loops = cue.action.video.playbackBehavior == .loop || cue.media.video.transport.playbackBehavior == .loop
        return Video(name: "Foreground media", frame: frame, media: media, scale: scale(of: cue.media), loops: loops)
    }

    private static func sections(_ played: [PlayedCue]) -> [Section] {
        var result: [Section] = []
        var lastOccurrence = -1
        for (k, item) in played.enumerated() where item.groupOccurrence != lastOccurrence {
            lastOccurrence = item.groupOccurrence
            result.append(Section(name: item.groupName, firstSlide: k))
        }
        let meaningful = result.contains { !$0.name.isEmpty && $0.name.lowercased() != "group" }
        guard meaningful else { return [] }
        return result.map { Section(name: $0.name.isEmpty ? "Untitled" : $0.name, firstSlide: $0.firstSlide) }
    }

    /// Every font the presentation's own descriptions name, with its family.
    private static func familyNames(in presentation: RVData_Presentation) -> [String: String] {
        var result: [String: String] = [:]
        for cue in presentation.cues {
            guard let slide = presentationSlide(of: cue) else { continue }
            for element in slide.baseSlide.elements where element.element.hasText {
                let a = element.element.text.attributes
                if !a.font.name.isEmpty, !a.font.family.isEmpty { result[a.font.name] = a.font.family }
                for custom in a.customAttributes {
                    if case .originalFont(let f)? = custom.attribute, !f.name.isEmpty, !f.family.isEmpty { result[f.name] = f.family }
                }
            }
        }
        return result
    }
}
