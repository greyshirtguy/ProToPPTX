// PPTXWriter: a deck made here is written, read back as a zip, and every XML part in it
// parses; the parts PowerPoint needs are there and point where they should.

import DeckModel
import Foundation
import Testing
import TestSupport
@testable import PPTXWriter
import ZipKit

@Suite struct PPTXWriterTests {
    static func sampleDeck() -> Deck {
        let style = RunStyle(fontName: "Helvetica", fontFamily: "Helvetica", size: 72, fill: .solid(.white))
        let body = TextBody(paragraphs: [
            Paragraph(alignment: .center, runs: [Run(text: "Amazing grace & <how> sweet", style: style)], endStyle: style),
            Paragraph(lineSpacing: .multiple(1.5), runs: [Run(text: "the sound\u{2028}that saved", style: style)], endStyle: style),
        ], insets: Insets(left: 5, top: 5, right: 5, bottom: 5), verticalAlignment: .middle, autofit: .shrink(fontScale: 0.8))
        var first = Slide(items: [.shape(Shape(name: "Words", frame: Rect(x: 100, y: 100, width: 1720, height: 880), text: body))], notes: "Say this\nthen that")
        first.backgroundColor = Color(red: 0.1, green: 0.2, blue: 0.3)
        let second = Slide(items: [.shape(Shape(name: "Box", frame: Rect(x: 0, y: 0, width: 960, height: 540), geometry: .roundedRectangle(cornerFraction: 0.1),
                                                fill: .gradient(Gradient(kind: .linear(angle: 90), stops: [.init(color: .black, position: 0), .init(color: .white, position: 1)])),
                                                line: Line(width: 4, color: .white), shadow: Shadow(color: .black, direction: 45, distance: 5, blurRadius: 5)))])
        return Deck(size: Size(width: 1920, height: 1080), title: "Sample", slides: [first, second], sections: [Section(name: "One", firstSlide: 0), Section(name: "Two", firstSlide: 1)])
    }

    @Test func writesAWholePackage() throws {
        let folder = try TestFiles.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sample.pptx")
        try PPTXWriter.write(Self.sampleDeck(), to: url, options: ConversionOptions(), notes: NoteCollector())

        let zip = try ZipReader(url: url)
        let paths = Set(zip.entries.map(\.path))
        for needed in ["[Content_Types].xml", "_rels/.rels", "ppt/presentation.xml", "ppt/_rels/presentation.xml.rels",
                       "ppt/slides/slide1.xml", "ppt/slides/slide2.xml", "ppt/slideMasters/slideMaster1.xml",
                       "ppt/slideLayouts/slideLayout1.xml", "ppt/theme/theme1.xml", "ppt/notesSlides/notesSlide1.xml",
                       "ppt/notesMasters/notesMaster1.xml", "docProps/core.xml", "docProps/app.xml"] {
            #expect(paths.contains(needed), "\(needed) is missing")
        }
        #expect(!paths.contains("ppt/notesSlides/notesSlide2.xml"))

        for entry in zip.entries where entry.path.hasSuffix(".xml") || entry.path.hasSuffix(".rels") {
            let data = try zip.contents(of: entry)
            let parser = XMLParser(data: data)
            #expect(parser.parse(), "\(entry.path) is not well-formed: \(String(describing: parser.parserError))")
            #expect(OOXMLLint.problems(in: String(decoding: data, as: UTF8.self)) == [], "\(entry.path)")
        }

        let presentation = String(decoding: try zip.contents(of: zip.entry("ppt/presentation.xml")!), as: UTF8.self)
        #expect(presentation.contains(#"<p:sldSz cx="12192000" cy="6858000"/>"#))
        #expect(presentation.contains(#"<p14:section name="Two""#))
        let slide = String(decoding: try zip.contents(of: zip.entry("ppt/slides/slide1.xml")!), as: UTF8.self)
        #expect(slide.contains("Amazing grace &amp; &lt;how&gt; sweet"))
        #expect(slide.contains("<a:br>"))
        #expect(slide.contains(#"<a:normAutofit fontScale="80000"/>"#))
        #expect(slide.contains(#"sz="3600""#)) // 72 units on a 1080 slide is 36 points
        #expect(slide.contains(#"<a:srgbClr val="1A334D"/>"#))
    }

    @Test func unitsScaleToTheStandardSlide() {
        let units = Units(deckSize: Size(width: 1920, height: 1080))
        #expect(units.emu(1920) == 12_192_000)
        #expect(units.fontSize(42) == 2100)
        #expect(Units.angle(-90) == 270 * 60_000)
    }

    /// Text that reaches left of its margin (RTF's \\li-100, which ProPresenter writes)
    /// and a list numbered from 2: margins stay at nought or more, the box's inset takes
    /// the difference, and the list's paragraphs share their start.
    @Test func textLeftOfItsMarginAndListsStayValid() throws {
        let style = RunStyle(fontName: "Helvetica", fontFamily: "Helvetica", size: 60, fill: .solid(.white))
        func p(_ text: String, left: Double, first: Double, bullet: Paragraph.Bullet? = nil) -> Paragraph {
            Paragraph(leftIndent: left, firstLineIndent: first, bullet: bullet, tabStops: [1], runs: [Run(text: text, style: style)], endStyle: style)
        }
        let body = TextBody(paragraphs: [
            p("Title", left: -5, first: 5),
            p("one", left: 200, first: -200, bullet: .number(scheme: "arabicPeriod", startAt: 2)),
            p("two", left: 200, first: -200, bullet: .number(scheme: "arabicPeriod", startAt: 3)),
        ], insets: Insets(left: 5, top: 5, right: 5, bottom: 5))
        let deck = Deck(size: Size(width: 1920, height: 1080), title: "Lists", slides: [Slide(items: [.shape(Shape(name: "Words", frame: Rect(x: 0, y: 0, width: 1000, height: 500), text: body))])])
        let folder = try TestFiles.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("lists.pptx")
        try PPTXWriter.write(deck, to: url, options: ConversionOptions(), notes: NoteCollector())
        let zip = try ZipReader(url: url)
        let slide = String(decoding: try zip.contents(of: zip.entry("ppt/slides/slide1.xml")!), as: UTF8.self)
        #expect(OOXMLLint.problems(in: slide) == [])
        #expect(slide.contains(#"lIns="0""#))                 // 5 - 5
        #expect(slide.contains(#"marL="1301750""#))           // 200 + 5, in EMU
        #expect(slide.contains(#"<a:tab pos="38100""#))       // 1 + 5
        #expect(slide.components(separatedBy: #"startAt="2""#).count == 3)
        #expect(!slide.contains(#"startAt="3""#))
    }
}
