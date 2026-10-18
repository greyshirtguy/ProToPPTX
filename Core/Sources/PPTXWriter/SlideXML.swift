// SlideXML: one Deck slide as a PowerPoint slide part.
//
// What goes where, back to front:
//
//   - The slide's background (p:bg): its colour, or, with the "as the slide's
//     background" option, its background picture, where it cannot be clicked on while
//     the words are edited. A picture whose shape is not the slide's, set to fit, would
//     be stretched there, so it goes in as a picture at the back instead (as do videos,
//     which a background cannot hold).
//   - Each item as a shape (p:sp: shapes and text boxes), a picture (p:pic), or a
//     video (a p:pic with the video attached, its still as the picture).
//
// Text: every run carries its own font, size, colour and the rest, so nothing depends
// on the theme. Where ProPresenter and PowerPoint lay text out differently, it is made
// up here, and each such place says what it makes up for and how it was measured
// (ProPresenter's exported slides, against PowerPoint's own pictures of the deck).

import DeckModel
import Foundation

struct SlideXML {
    let units: Units
    let deckSize: Size
    let options: ConversionOptions
    let language: String
    let media: MediaRegistry
    let notes: NoteCollector
    let slideNumber: Int

    /// Relationships of the slide part; rId1 is its layout.
    private(set) var relationships: [XML.Relationship] = [
        XML.Relationship(id: "rId1", type: XML.RelType.slideLayout, target: "../slideLayouts/slideLayout1.xml"),
    ]
    private var nextShapeID = 2
    private var videoTimings: [(shapeID: Int, video: Video)] = []

    init(units: Units, deckSize: Size, options: ConversionOptions, language: String, media: MediaRegistry, notes: NoteCollector, slideNumber: Int) {
        self.units = units
        self.deckSize = deckSize
        self.options = options
        self.language = language
        self.media = media
        self.notes = notes
        self.slideNumber = slideNumber
    }

    mutating func addRelationship(type: String, target: String) -> String {
        let id = "rId\(relationships.count + 1)"
        relationships.append(XML.Relationship(id: id, type: type, target: target))
        return id
    }

    private mutating func shapeID() -> Int {
        defer { nextShapeID += 1 }
        return nextShapeID
    }

    // MARK: - The slide

    mutating func xml(for slide: Slide) throws -> String {
        var tree = ""
        let whole = Rect(x: 0, y: 0, width: deckSize.width, height: deckSize.height)
        var background = #"<a:solidFill>\#(color(slide.backgroundColor ?? .black))</a:solidFill>"#

        if let bg = slide.background, !bg.media.isMissing {
            switch bg.media.kind {
            case .image:
                if let part = try? media.part(for: bg.media) {
                    if options.backgroundPlacement == .slideBackground, let fill = backgroundFill(part, bg.scale) {
                        let rid = addRelationship(type: XML.RelType.image, target: "../media/\(part.name)")
                        background = fill.replacingOccurrences(of: "RID", with: rid)
                    } else {
                        tree += try picture(Picture(name: bg.isCarriedOver ? "Background (carried over)" : "Background", frame: whole, media: bg.media, scale: bg.scale))
                    }
                } else {
                    notes.add(.missingMedia, "The media file \(bg.media.fileName) could not be read", slide: slideNumber)
                }
            case .video:
                if options.videos != .leaveOut {
                    tree += try video(Video(name: "Background video", frame: whole, media: bg.media, scale: bg.scale, loops: true))
                }
            case .audio:
                break
            }
        }

        for item in slide.items {
            switch item {
            case .shape(let shape): tree += try self.shape(shape)
            case .picture(let picture): tree += try self.picture(picture)
            case .video(let v): if options.videos != .leaveOut { tree += try video(v) }
            }
        }

        return XML.header + #"<p:sld \#(XML.presentationNamespaces)><p:cSld><p:bg><p:bgPr>\#(background)<a:effectLst/></p:bgPr></p:bg>"#
            + #"<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"#
            + #"<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>"#
            + tree + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>" + timing() + "</p:sld>"
    }

    /// The slide background's picture fill, with "RID" where its relationship goes, or
    /// nil if the picture would be stretched out of shape there.
    private func backgroundFill(_ part: MediaPart, _ mode: ScaleMode) -> String? {
        var source = ""
        if let size = part.pixelSize, size.width > 0, size.height > 0 {
            let pictureAspect = size.width / size.height
            let slideAspect = deckSize.width / deckSize.height
            let near = abs(pictureAspect / slideAspect - 1) < 0.01
            switch mode {
            case .stretch: break
            case .fit where !near: return nil
            case .fill where !near:
                // Cut what spills over, from both sides equally.
                if pictureAspect > slideAspect {
                    let cut = (1 - slideAspect / pictureAspect) / 2
                    source = #"<a:srcRect l="\#(Units.percent(cut))" r="\#(Units.percent(cut))"/>"#
                } else {
                    let cut = (1 - pictureAspect / slideAspect) / 2
                    source = #"<a:srcRect t="\#(Units.percent(cut))" b="\#(Units.percent(cut))"/>"#
                }
            default: break
            }
        }
        return #"<a:blipFill dpi="0" rotWithShape="1"><a:blip r:embed="RID"/>\#(source)<a:stretch><a:fillRect/></a:stretch></a:blipFill>"#
    }

    // MARK: - Shapes

    private mutating func shape(_ s: Shape) throws -> String {
        let id = shapeID()
        var spPr = xfrm(s.frame, rotation: s.rotation, flipH: s.flipHorizontal, flipV: s.flipVertical) + geometry(s.geometry, s.frame)
        switch s.fill {
        case .solid(let c)?: spPr += #"<a:solidFill>\#(color(c, opacity: s.opacity))</a:solidFill>"#
        case .gradient(let g)?: spPr += gradientFill(g, opacity: s.opacity)
        case .picture(let m, _)?:
            if let part = try? media.part(for: m) {
                let rid = addRelationship(type: XML.RelType.image, target: "../media/\(part.name)")
                let alpha = s.opacity < 1 ? #"<a:alphaModFix amt="\#(Units.percent(s.opacity))"/>"# : ""
                spPr += #"<a:blipFill dpi="0" rotWithShape="1"><a:blip r:embed="\#(rid)">\#(alpha)</a:blip><a:stretch><a:fillRect/></a:stretch></a:blipFill>"#
            } else {
                spPr += "<a:noFill/>"
            }
        case nil: spPr += "<a:noFill/>"
        }
        if let line = s.line {
            spPr += #"<a:ln w="\#(units.emu(line.width))"><a:solidFill>\#(color(line.color, opacity: s.opacity))</a:solidFill>\#(dash(line))</a:ln>"#
        } else {
            spPr += "<a:ln><a:noFill/></a:ln>"
        }
        var effects = ""
        if let shadow = s.shadow { effects += outerShadow(shadow, opacity: s.opacity) }
        if s.softEdge > 0 { effects += #"<a:softEdge rad="\#(units.emu(s.softEdge))"/>"# }
        if !effects.isEmpty { spPr += "<a:effectLst>\(effects)</a:effectLst>" }

        let isTextBox = s.text != nil && s.fill == nil && s.line == nil
        var xml = #"<p:sp><p:nvSpPr><p:cNvPr id="\#(id)" name="\#(XML.escape(s.name))"/><p:cNvSpPr\#(isTextBox ? #" txBox="1""# : "")/><p:nvPr/></p:nvSpPr>"#
        xml += "<p:spPr>\(spPr)</p:spPr>"
        xml += textBody(s.text, frame: s.frame, opacity: s.opacity)
        return xml + "</p:sp>"
    }

    private func xfrm(_ r: Rect, rotation: Double, flipH: Bool, flipV: Bool) -> String {
        var attributes = ""
        if rotation != 0 { attributes += #" rot="\#(Units.angle(rotation))""# }
        if flipH { attributes += #" flipH="1""# }
        if flipV { attributes += #" flipV="1""# }
        return #"<a:xfrm\#(attributes)><a:off x="\#(units.emu(r.x))" y="\#(units.emu(r.y))"/><a:ext cx="\#(max(0, units.emu(r.width)))" cy="\#(max(0, units.emu(r.height)))"/></a:xfrm>"#
    }

    private func geometry(_ g: Geometry, _ frame: Rect) -> String {
        switch g {
        case .rectangle:
            return #"<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>"#
        case .ellipse:
            return #"<a:prstGeom prst="ellipse"><a:avLst/></a:prstGeom>"#
        case .roundedRectangle(let f):
            return #"<a:prstGeom prst="roundRect"><a:avLst><a:gd name="adj" fmla="val \#(Units.percent(f))"/></a:avLst></a:prstGeom>"#
        case .polygon(let points):
            let size = 100_000
            var path = ""
            for (k, p) in points.enumerated() {
                let pt = #"<a:pt x="\#(Int((p.x * Double(size)).rounded()))" y="\#(Int((p.y * Double(size)).rounded()))"/>"#
                path += k == 0 ? "<a:moveTo>\(pt)</a:moveTo>" : "<a:lnTo>\(pt)</a:lnTo>"
            }
            return #"<a:custGeom><a:avLst/><a:gdLst/><a:ahLst/><a:cxnLst/><a:rect l="0" t="0" r="r" b="b"/><a:pathLst><a:path w="\#(size)" h="\#(size)">\#(path)<a:close/></a:path></a:pathLst></a:custGeom>"#
        }
    }

    private func dash(_ line: Line) -> String {
        guard line.dashes.count >= 2 else { return "" }
        let ratio = line.dashes[0] / max(line.dashes[1], 0.01)
        let preset = ratio >= 2.5 ? "lgDash" : (ratio >= 1.5 ? "dash" : "sysDash")
        return #"<a:prstDash val="\#(preset)"/>"#
    }

    // MARK: - Text

    private func textBody(_ body: TextBody?, frame: Rect, opacity: Double) -> String {
        guard let body else { return "" }
        let anchor: String
        switch body.verticalAlignment {
        case .top: anchor = "t"
        case .middle: anchor = "ctr"
        case .bottom: anchor = "b"
        }
        let fit: String
        switch body.autofit {
        case .none: fit = "<a:noAutofit/>"
        case .shrink(let s) where s < 0.999: fit = #"<a:normAutofit fontScale="\#(Units.percent(s))"/>"#
        case .shrink: fit = "<a:normAutofit/>"
        case .resizeShape: fit = "<a:spAutoFit/>"
        }
        // PowerPoint's lines put where ProPresenter's are (TextFit says how).
        let fitted = TextFit(body, frame: frame)
        let i = body.insets
        var xml = #"<p:txBody><a:bodyPr wrap="\#(body.wraps ? "square" : "none")" lIns="\#(units.emu(i.left))" tIns="\#(units.emu(i.top + fitted.shift))" rIns="\#(units.emu(i.right))" bIns="\#(units.emu(i.bottom - fitted.shift))" rtlCol="0" anchor="\#(anchor)">\#(fit)</a:bodyPr><a:lstStyle/>"#
        for (k, paragraph) in body.paragraphs.enumerated() { xml += self.paragraph(paragraph, spacing: fitted.spacing[k], opacity: opacity) }
        if body.paragraphs.isEmpty { xml += #"<a:p><a:endParaRPr lang="\#(language)"/></a:p>"# }
        return xml + "</p:txBody>"
    }

    private func paragraph(_ p: Paragraph, spacing: Double, opacity: Double) -> String {
        var attributes = ""
        switch p.alignment {
        case .left: attributes += #" algn="l""#
        case .center: attributes += #" algn="ctr""#
        case .right: attributes += #" algn="r""#
        case .justified: attributes += #" algn="just""#
        }
        if p.leftIndent != 0 { attributes += #" marL="\#(units.emu(p.leftIndent))""# }
        if p.firstLineIndent != 0 { attributes += #" indent="\#(units.emu(p.firstLineIndent))""# }
        if p.rightIndent > 0 { attributes += #" marR="\#(units.emu(p.rightIndent))""# }
        if p.defaultTabInterval > 0 { attributes += #" defTabSz="\#(units.emu(p.defaultTabInterval))""# }

        var inner = #"<a:lnSpc><a:spcPct val="\#(Units.percent(spacing))"/></a:lnSpc>"#
        if p.spaceBefore > 0 { inner += #"<a:spcBef><a:spcPts val="\#(units.centipoints(p.spaceBefore))"/></a:spcBef>"# }
        if p.spaceAfter > 0 { inner += #"<a:spcAft><a:spcPts val="\#(units.centipoints(p.spaceAfter))"/></a:spcAft>"# }
        switch p.bullet {
        case .character(let c)?: inner += #"<a:buFontTx/><a:buChar char="\#(XML.escape(c))"/>"#
        case .number(let scheme, let start)?: inner += #"<a:buFontTx/><a:buAutoNum type="\#(scheme)"\#(start != 1 ? #" startAt="\#(start)""# : "")/>"#
        case nil: inner += "<a:buNone/>"
        }
        if !p.tabStops.isEmpty {
            inner += "<a:tabLst>" + p.tabStops.map { #"<a:tab pos="\#(units.emu($0))" algn="l"/>"# }.joined() + "</a:tabLst>"
        }

        var xml = "<a:p><a:pPr\(attributes)>\(inner)</a:pPr>"
        for run in p.runs {
            // A line break inside a paragraph is its own element in PowerPoint. (A
            // vertical tab is PowerPoint's own line break, which slides ProPresenter made
            // from a PowerPoint may still have.)
            let pieces = run.text.split(omittingEmptySubsequences: false) { $0 == "\u{2028}" || $0 == "\u{0B}" }
            for (k, piece) in pieces.enumerated() {
                if k > 0 { xml += "<a:br>\(runProperties(run.style, opacity: opacity, tag: "a:rPr"))</a:br>" }
                if !piece.isEmpty {
                    xml += "<a:r>\(runProperties(run.style, opacity: opacity, tag: "a:rPr"))<a:t>\(XML.escape(String(piece)))</a:t></a:r>"
                }
            }
        }
        xml += runProperties(p.runs.last?.style ?? p.endStyle, opacity: opacity, tag: "a:endParaRPr")
        return xml + "</a:p>"
    }

    private func runProperties(_ s: RunStyle, opacity: Double, tag: String) -> String {
        var attributes = #" lang="\#(language)" sz="\#(units.fontSize(s.size))""#
        attributes += s.bold ? #" b="1""# : #" b="0""#
        attributes += s.italic ? #" i="1""# : #" i="0""#
        if s.underline { attributes += #" u="sng""# }
        if s.strikethrough { attributes += #" strike="sngStrike""# }
        switch s.capitalization {
        case .allCaps: attributes += #" cap="all""#
        case .smallCaps: attributes += #" cap="small""#
        case .none: break
        }
        if s.characterSpacing != 0 { attributes += #" spc="\#(units.centipoints(s.characterSpacing))""# }
        if s.superscript != 0 {
            attributes += #" baseline="\#(s.superscript > 0 ? 30000 : -25000)""#
        } else if s.baselineOffset != 0, s.size > 0 {
            attributes += #" baseline="\#(Units.percent(s.baselineOffset / s.size))""#
        }
        attributes += #" dirty="0""#

        var inner = ""
        if let outline = s.outline {
            inner += #"<a:ln w="\#(units.emu(outline.width))"><a:solidFill>\#(color(outline.color, opacity: opacity))</a:solidFill></a:ln>"#
        }
        switch s.fill {
        case .solid(let c): inner += "<a:solidFill>\(color(c, opacity: opacity))</a:solidFill>"
        case .gradient(let g): inner += gradientFill(g, opacity: opacity)
        }
        if let shadow = s.shadow { inner += "<a:effectLst>\(outerShadow(shadow, opacity: opacity))</a:effectLst>" }
        if let h = s.highlight { inner += "<a:highlight>\(color(h))</a:highlight>" }
        if s.underline, let c = s.underlineColor { inner += "<a:uFill><a:solidFill>\(color(c, opacity: opacity))</a:solidFill></a:uFill>" }
        let face = XML.escape(s.fontFamily.isEmpty ? s.fontName : s.fontFamily)
        inner += #"<a:latin typeface="\#(face)"/><a:cs typeface="\#(face)"/>"#
        return "<\(tag)\(attributes)>\(inner)</\(tag)>"
    }

    // MARK: - Colours and effects

    private func color(_ c: Color, opacity: Double = 1) -> String {
        let alpha = c.alpha * opacity
        if alpha >= 0.9995 { return #"<a:srgbClr val="\#(c.hex)"/>"# }
        return #"<a:srgbClr val="\#(c.hex)"><a:alpha val="\#(Units.percent(alpha))"/></a:srgbClr>"#
    }

    private func gradientFill(_ g: Gradient, opacity: Double) -> String {
        var stops = g.stops
        if stops.count == 1 { stops.append(Gradient.Stop(color: stops[0].color, position: 1)) }
        if stops.isEmpty { stops = [Gradient.Stop(color: .white, position: 0), Gradient.Stop(color: .white, position: 1)] }
        let list = stops.map { #"<a:gs pos="\#(Units.percent($0.position))">\#(color($0.color, opacity: opacity))</a:gs>"# }.joined()
        let path: String
        switch g.kind {
        case .linear(let angle): path = #"<a:lin ang="\#(Units.angle(angle))" scaled="0"/>"#
        case .radial: path = #"<a:path path="circle"><a:fillToRect l="50000" t="50000" r="50000" b="50000"/></a:path>"#
        }
        return #"<a:gradFill flip="none" rotWithShape="1"><a:gsLst>\#(list)</a:gsLst>\#(path)</a:gradFill>"#
    }

    private func outerShadow(_ s: Shadow, opacity: Double) -> String {
        #"<a:outerShdw blurRad="\#(units.emu(s.blurRadius))" dist="\#(units.emu(s.distance))" dir="\#(Units.angle(s.direction))" algn="ctr" rotWithShape="0">\#(color(s.color, opacity: opacity))</a:outerShdw>"#
    }

    // MARK: - Pictures and video

    private mutating func picture(_ pic: Picture) throws -> String {
        guard !pic.media.isMissing, let part = try? media.part(for: pic.media) else {
            if !pic.media.isMissing { notes.add(.missingMedia, "The media file \(pic.media.fileName) could not be read", slide: slideNumber) }
            return ""
        }
        let rid = addRelationship(type: XML.RelType.image, target: "../media/\(part.name)")
        let id = shapeID()
        let size = part.pixelSize ?? pic.media.naturalSize
        var frame = pic.frame
        var source = ""
        var cropped = pic.crop
        if let size, size.width > 0, size.height > 0 {
            let visible = Size(width: size.width * (1 - cropped.left - cropped.right), height: size.height * (1 - cropped.top - cropped.bottom))
            switch pic.scale {
            case .fit:
                frame = pic.frame.placing(visible, .fit)
            case .fill:
                // Cut what spills over the frame, half from each side.
                let shown = pic.frame.placing(visible, .fill)
                let cutX = (shown.width - pic.frame.width) / shown.width / 2 * (1 - cropped.left - cropped.right)
                let cutY = (shown.height - pic.frame.height) / shown.height / 2 * (1 - cropped.top - cropped.bottom)
                cropped = Insets(left: cropped.left + cutX, top: cropped.top + cutY, right: cropped.right + cutX, bottom: cropped.bottom + cutY)
            case .stretch:
                break
            }
        }
        if cropped != .zero {
            source = #"<a:srcRect l="\#(Units.percent(cropped.left))" t="\#(Units.percent(cropped.top))" r="\#(Units.percent(cropped.right))" b="\#(Units.percent(cropped.bottom))"/>"#
        }
        let alpha = pic.opacity < 1 ? #"<a:alphaModFix amt="\#(Units.percent(pic.opacity))"/>"# : ""
        return #"<p:pic><p:nvPicPr><p:cNvPr id="\#(id)" name="\#(XML.escape(pic.name))" descr="\#(XML.escape(pic.media.fileName))"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>"#
            + #"<p:blipFill><a:blip r:embed="\#(rid)">\#(alpha)</a:blip>\#(source)<a:stretch><a:fillRect/></a:stretch></p:blipFill>"#
            + "<p:spPr>\(xfrm(frame, rotation: pic.rotation, flipH: pic.flipHorizontal, flipV: pic.flipVertical))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
    }

    private mutating func video(_ v: Video) throws -> String {
        guard !v.media.isMissing else { return "" }
        // Fitted as a picture is: placed whole, or filling the frame with what spills
        // over cut off (PowerPoint crops a video as it does a picture).
        var frame = v.frame
        var crop = ""
        if let size = v.media.naturalSize, size.width > 0, size.height > 0 {
            switch v.scale {
            case .fit: frame = v.frame.placing(size, .fit)
            case .fill:
                let shown = v.frame.placing(size, .fill)
                let cutX = (shown.width - v.frame.width) / shown.width / 2
                let cutY = (shown.height - v.frame.height) / shown.height / 2
                if cutX > 0.0005 || cutY > 0.0005 {
                    crop = #"<a:srcRect l="\#(Units.percent(cutX))" t="\#(Units.percent(cutY))" r="\#(Units.percent(cutX))" b="\#(Units.percent(cutY))"/>"#
                }
            case .stretch: break
            }
        }

        // Only a still, by choice or for want of the video's length.
        if options.videos == .stillOnly {
            guard let still = v.media.stillPicture else { return "" }
            return try picture(Picture(name: v.name, frame: v.frame, media: still, scale: v.scale))
        }
        guard let still = v.media.stillPicture, let posterPart = try? media.part(for: still), let videoPart = try? media.part(for: v.media) else {
            notes.add(.missingMedia, "The video \(v.media.fileName) could not be read", slide: slideNumber)
            return ""
        }
        let linkID = addRelationship(type: XML.RelType.video, target: "../media/\(videoPart.name)")
        let mediaID = addRelationship(type: XML.RelType.media, target: "../media/\(videoPart.name)")
        let posterID = addRelationship(type: XML.RelType.image, target: "../media/\(posterPart.name)")
        let id = shapeID()
        if v.playsAutomatically { videoTimings.append((id, v)) }
        return #"<p:pic><p:nvPicPr><p:cNvPr id="\#(id)" name="\#(XML.escape(v.name))" descr="\#(XML.escape(v.media.fileName))"><a:hlinkClick r:id="" action="ppaction://media"/></p:cNvPr>"#
            + #"<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr><a:videoFile r:link="\#(linkID)"/>"#
            + #"<p:extLst><p:ext uri="{DAA4B4D4-6D71-4841-9C94-3DE7FCFB9230}"><p14:media xmlns:p14="\#(XML.p14)" r:embed="\#(mediaID)"/></p:ext></p:extLst></p:nvPr></p:nvPicPr>"#
            + #"<p:blipFill><a:blip r:embed="\#(posterID)"/>\#(crop)<a:stretch><a:fillRect/></a:stretch></p:blipFill>"#
            + "<p:spPr>\(xfrm(frame, rotation: 0, flipH: false, flipV: false))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
    }

    /// Starts each video by itself when the slide comes up ("Start: Automatically"), and
    /// loops those that loop: the timing PowerPoint itself writes for that. Its nodes are
    /// numbered in the order they are written, as PowerPoint numbers them.
    private func timing() -> String {
        guard !videoTimings.isEmpty else { return "" }
        // 1 and 2 are the root and the main sequence; 3 and 4 the click it waits for.
        var id = 5
        var calls = ""
        for (k, entry) in videoTimings.enumerated() {
            let ms = Int(((entry.video.media.duration ?? 0) * 1000).rounded())
            let duration = ms > 0 ? "\(ms)" : "indefinite"
            let node = k == 0 ? "afterEffect" : "withEffect"
            calls += #"<p:par><p:cTn id="\#(id)" presetID="1" presetClass="mediacall" presetSubtype="0" fill="hold" nodeType="\#(node)"><p:stCondLst><p:cond delay="0"/></p:stCondLst>"#
                + #"<p:childTnLst><p:cmd type="call" cmd="playFrom(0.0)"><p:cBhvr><p:cTn id="\#(id + 1)" dur="\#(duration)" fill="hold"/><p:tgtEl><p:spTgt spid="\#(entry.shapeID)"/></p:tgtEl></p:cBhvr></p:cmd></p:childTnLst></p:cTn></p:par>"#
            id += 2
        }
        var nodes = ""
        for entry in videoTimings {
            let repeatCount = entry.video.loops ? #" repeatCount="indefinite""# : ""
            let mute = entry.video.muted ? #" mute="1""# : ""
            nodes += #"<p:video><p:cMediaNode vol="80000"\#(mute)><p:cTn id="\#(id)"\#(repeatCount) fill="hold" display="0"><p:stCondLst><p:cond delay="indefinite"/></p:stCondLst></p:cTn>"#
                + #"<p:tgtEl><p:spTgt spid="\#(entry.shapeID)"/></p:tgtEl></p:cMediaNode></p:video>"#
            id += 1
        }
        return #"<p:timing><p:tnLst><p:par><p:cTn id="1" dur="indefinite" restart="never" nodeType="tmRoot"><p:childTnLst>"#
            + #"<p:seq concurrent="1" nextAc="seek"><p:cTn id="2" dur="indefinite" nodeType="mainSeq"><p:childTnLst>"#
            + #"<p:par><p:cTn id="3" fill="hold"><p:stCondLst><p:cond delay="indefinite"/><p:cond evt="onBegin" delay="0"><p:tn val="2"/></p:cond></p:stCondLst>"#
            + #"<p:childTnLst><p:par><p:cTn id="4" fill="hold"><p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>\#(calls)</p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>"#
            + #"</p:childTnLst></p:cTn><p:prevCondLst><p:cond evt="onPrev" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:prevCondLst>"#
            + #"<p:nextCondLst><p:cond evt="onNext" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:nextCondLst></p:seq>"#
            + nodes + "</p:childTnLst></p:cTn></p:par></p:tnLst></p:timing>"
    }
}
