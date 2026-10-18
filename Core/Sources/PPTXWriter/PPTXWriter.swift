// PPTXWriter: a Deck written out as a PowerPoint file (.pptx, Office Open XML).
//
// The file is a zip of XML parts and media. Which parts there are, and how they point to
// each other, is fixed by the standard; what is in them is made by SlideXML (each slide)
// and FixedParts (the rest). The file is written beside where it is to go and moved into
// place when it is whole, so a file that was there before is never left half written.
//
// Sections (PowerPoint's way of grouping slides, where ProPresenter's groups go) are an
// extension PowerPoint 2010 added; PowerPoint and Keynote read them, and anything that
// does not simply ignores them.

import DeckModel
import Foundation
import ZipKit

public enum PPTXWriter {
    /// Writes the deck to `url`, replacing what is there. What could not be put in is
    /// added to `notes`.
    public static func write(_ deck: Deck, to url: URL, options: ConversionOptions, notes: NoteCollector) throws {
        let units = Units(deckSize: deck.size)
        let language = Self.language()
        let media = MediaRegistry()
        let withNotes = options.includeNotes && deck.slides.contains { !$0.notes.isEmpty }

        var slideParts: [(xml: String, rels: String, notes: String?)] = []
        for (k, slide) in deck.slides.enumerated() {
            var writer = SlideXML(units: units, deckSize: deck.size, options: options, language: language, media: media, notes: notes, slideNumber: k + 1)
            let xml = try writer.xml(for: slide)
            var rels = writer.relationships
            var notesXML: String?
            if withNotes, !slide.notes.isEmpty {
                notesXML = FixedParts.notesSlide(text: slide.notes, language: language)
                rels.append(XML.Relationship(id: "rId\(rels.count + 1)", type: XML.RelType.notesSlide, target: "../notesSlides/notesSlide\(k + 1).xml"))
            }
            slideParts.append((xml, XML.relationships(rels), notesXML))
        }

        // Written next to the destination, then moved over it.
        let folder = url.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let zip = try ZipWriter(url: temporary)

        try zip.add(path: "[Content_Types].xml", data: Data(contentTypes(deck, slideParts.map { $0.notes != nil }, withNotes, media.extensions).utf8), packing: .deflate)
        try zip.add(path: "_rels/.rels", data: Data(XML.relationships([
            .init(id: "rId1", type: XML.RelType.officeDocument, target: "ppt/presentation.xml"),
            .init(id: "rId2", type: XML.RelType.coreProperties, target: "docProps/core.xml"),
            .init(id: "rId3", type: XML.RelType.extendedProperties, target: "docProps/app.xml"),
        ]).utf8), packing: .deflate)
        try zip.add(path: "docProps/core.xml", data: Data(FixedParts.coreProperties(title: deck.title).utf8), packing: .deflate)
        try zip.add(path: "docProps/app.xml", data: Data(FixedParts.appProperties(slideCount: deck.slides.count).utf8), packing: .deflate)

        // The presentation and what it points to.
        var presentationRels: [XML.Relationship] = [.init(id: "rId1", type: XML.RelType.slideMaster, target: "slideMasters/slideMaster1.xml")]
        var slideList = ""
        for k in deck.slides.indices {
            let rid = "rId\(presentationRels.count + 1)"
            presentationRels.append(.init(id: rid, type: XML.RelType.slide, target: "slides/slide\(k + 1).xml"))
            slideList += #"<p:sldId id="\#(256 + k)" r:id="\#(rid)"/>"#
        }
        var notesMasterList = ""
        if withNotes {
            let rid = "rId\(presentationRels.count + 1)"
            presentationRels.append(.init(id: rid, type: XML.RelType.notesMaster, target: "notesMasters/notesMaster1.xml"))
            notesMasterList = #"<p:notesMasterIdLst><p:notesMasterId r:id="\#(rid)"/></p:notesMasterIdLst>"#
        }
        for (type, target) in [(XML.RelType.presProps, "presProps.xml"), (XML.RelType.viewProps, "viewProps.xml"),
                               (XML.RelType.theme, "theme/theme1.xml"), (XML.RelType.tableStyles, "tableStyles.xml")] {
            presentationRels.append(.init(id: "rId\(presentationRels.count + 1)", type: type, target: target))
        }
        let width = units.emu(deck.size.width), height = Int(Units.slideHeightEMU)
        let presentation = XML.header + #"<p:presentation \#(XML.presentationNamespaces) saveSubsetFonts="1">"#
            + #"<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>"# + notesMasterList
            + (slideList.isEmpty ? "" : "<p:sldIdLst>\(slideList)</p:sldIdLst>")
            + #"<p:sldSz cx="\#(width)" cy="\#(height)"/><p:notesSz cx="6858000" cy="9144000"/>"#
            + sectionList(deck) + "</p:presentation>"
        try zip.add(path: "ppt/presentation.xml", data: Data(presentation.utf8), packing: .deflate)
        try zip.add(path: "ppt/_rels/presentation.xml.rels", data: Data(XML.relationships(presentationRels).utf8), packing: .deflate)
        try zip.add(path: "ppt/presProps.xml", data: Data(FixedParts.presProps.utf8), packing: .deflate)
        try zip.add(path: "ppt/viewProps.xml", data: Data(FixedParts.viewProps.utf8), packing: .deflate)
        try zip.add(path: "ppt/tableStyles.xml", data: Data(FixedParts.tableStyles.utf8), packing: .deflate)
        try zip.add(path: "ppt/theme/theme1.xml", data: Data(FixedParts.theme(name: "ProToPPTX").utf8), packing: .deflate)
        try zip.add(path: "ppt/slideMasters/slideMaster1.xml", data: Data(FixedParts.slideMaster.utf8), packing: .deflate)
        try zip.add(path: "ppt/slideMasters/_rels/slideMaster1.xml.rels", data: Data(XML.relationships([
            .init(id: "rId1", type: XML.RelType.slideLayout, target: "../slideLayouts/slideLayout1.xml"),
            .init(id: "rId2", type: XML.RelType.theme, target: "../theme/theme1.xml"),
        ]).utf8), packing: .deflate)
        try zip.add(path: "ppt/slideLayouts/slideLayout1.xml", data: Data(FixedParts.slideLayout.utf8), packing: .deflate)
        try zip.add(path: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", data: Data(XML.relationships([
            .init(id: "rId1", type: XML.RelType.slideMaster, target: "../slideMasters/slideMaster1.xml"),
        ]).utf8), packing: .deflate)
        if withNotes {
            try zip.add(path: "ppt/notesMasters/notesMaster1.xml", data: Data(FixedParts.notesMaster.utf8), packing: .deflate)
            try zip.add(path: "ppt/notesMasters/_rels/notesMaster1.xml.rels", data: Data(XML.relationships([
                .init(id: "rId1", type: XML.RelType.theme, target: "../theme/theme2.xml"),
            ]).utf8), packing: .deflate)
            try zip.add(path: "ppt/theme/theme2.xml", data: Data(FixedParts.theme(name: "Notes").utf8), packing: .deflate)
        }

        for (k, part) in slideParts.enumerated() {
            try zip.add(path: "ppt/slides/slide\(k + 1).xml", data: Data(part.xml.utf8), packing: .deflate)
            try zip.add(path: "ppt/slides/_rels/slide\(k + 1).xml.rels", data: Data(part.rels.utf8), packing: .deflate)
            if let notesXML = part.notes {
                try zip.add(path: "ppt/notesSlides/notesSlide\(k + 1).xml", data: Data(notesXML.utf8), packing: .deflate)
                try zip.add(path: "ppt/notesSlides/_rels/notesSlide\(k + 1).xml.rels", data: Data(XML.relationships([
                    .init(id: "rId1", type: XML.RelType.notesMaster, target: "../notesMasters/notesMaster1.xml"),
                    .init(id: "rId2", type: XML.RelType.slide, target: "../slides/slide\(k + 1).xml"),
                ]).utf8), packing: .deflate)
            }
        }
        try media.write(into: zip)
        try zip.finish()

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: url)
        }
    }

    // MARK: -

    private static func contentTypes(_ deck: Deck, _ hasNotes: [Bool], _ withNotes: Bool, _ extensions: Set<String>) -> String {
        let ct = "application/vnd.openxmlformats-officedocument.presentationml"
        var s = XML.header + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
        s += #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
        s += #"<Default Extension="xml" ContentType="application/xml"/>"#
        for ext in extensions.sorted() {
            s += #"<Default Extension="\#(ext)" ContentType="\#(MediaRegistry.contentType(ext))"/>"#
        }
        s += #"<Override PartName="/ppt/presentation.xml" ContentType="\#(ct).presentation.main+xml"/>"#
        s += #"<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="\#(ct).slideMaster+xml"/>"#
        s += #"<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="\#(ct).slideLayout+xml"/>"#
        for k in deck.slides.indices {
            s += #"<Override PartName="/ppt/slides/slide\#(k + 1).xml" ContentType="\#(ct).slide+xml"/>"#
            if hasNotes[k] { s += #"<Override PartName="/ppt/notesSlides/notesSlide\#(k + 1).xml" ContentType="\#(ct).notesSlide+xml"/>"# }
        }
        if withNotes {
            s += #"<Override PartName="/ppt/notesMasters/notesMaster1.xml" ContentType="\#(ct).notesMaster+xml"/>"#
            s += #"<Override PartName="/ppt/theme/theme2.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>"#
        }
        s += #"<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>"#
        s += #"<Override PartName="/ppt/presProps.xml" ContentType="\#(ct).presProps+xml"/>"#
        s += #"<Override PartName="/ppt/viewProps.xml" ContentType="\#(ct).viewProps+xml"/>"#
        s += #"<Override PartName="/ppt/tableStyles.xml" ContentType="\#(ct).tableStyles+xml"/>"#
        s += #"<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>"#
        s += #"<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>"#
        return s + "</Types>"
    }

    /// PowerPoint's sections, each slide in exactly one, the first starting at slide 1.
    private static func sectionList(_ deck: Deck) -> String {
        let sections = deck.sections.filter { $0.firstSlide < deck.slides.count }.sorted { $0.firstSlide < $1.firstSlide }
        guard !sections.isEmpty, !deck.slides.isEmpty else { return "" }
        var list = ""
        for (k, section) in sections.enumerated() {
            let start = k == 0 ? 0 : section.firstSlide
            let end = k + 1 < sections.count ? sections[k + 1].firstSlide : deck.slides.count
            let ids = (start..<max(start, end)).map { #"<p14:sldId id="\#(256 + $0)"/>"# }.joined()
            list += #"<p14:section name="\#(XML.escape(section.name))" id="{\#(UUID().uuidString)}"><p14:sldIdLst>\#(ids)</p14:sldIdLst></p14:section>"#
        }
        return #"<p:extLst><p:ext uri="{521415D9-36F7-43E2-AB2F-B90AF26B5E84}"><p14:sectionLst xmlns:p14="\#(XML.p14)">\#(list)</p14:sectionLst></p:ext></p:extLst>"#
    }

    /// The language words are marked as being in, for PowerPoint's spelling checker:
    /// this Mac's ("en-AU").
    static func language() -> String {
        let l = Locale.current
        if let code = l.language.languageCode?.identifier, let region = l.region?.identifier { return "\(code)-\(region)" }
        return "en-US"
    }
}
