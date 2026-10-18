// RTFReader: Cocoa RTF, as ProPresenter writes it, read into Deck's paragraphs.
//
// The samples are written as ProPresenter writes them (the shapes were taken from the
// maintainer's files; the words are made up). A backslash, "u" and four digits is never
// typed into this file: it would arrive as one character. Such text is built from pieces.

import DeckModel
import Foundation
import Testing
@testable import ProImport

@Suite struct RTFReaderTests {
    static let header = #"{\rtf1\ansi\ansicpg1252\cocoartf2870"# + "\n" + #"\cocoatextscaling0\cocoaplatform0"#

    @Test func fontsColoursSizesAndParagraphs() {
        let rtf = Self.header + #"{\fonttbl\f0\fswiss\fcharset0 Helvetica-Bold;\f1\fnil\fcharset0 CMGSans-Light;}"# + "\n"
            + #"{\colortbl;\red255\green255\blue255;\red254\green219\blue79;}"# + "\n"
            + #"{\*\expandedcolortbl;;\cssrgb\c100000\c87843\c38039\c50000;}"# + "\n"
            + #"\deftab2880"# + "\n" + #"\pard\pardeftab2880\sl360\slmult1\qc\partightenfactor0"# + "\n\n"
            + #"\f0\b\fs120 \cf2 Grace\cf0  and \f1\b0\fs101 \fsmilli50625 peace\"# + "\n"
            + #"second line}"#
        let doc = RTFReader.read(rtf)
        #expect(doc.fontNames == ["Helvetica-Bold", "CMGSans-Light"])
        #expect(doc.paragraphs.count == 2)
        let first = doc.paragraphs[0]
        #expect(first.alignment == .center)
        #expect(first.lineSpacing == .multiple(1.5))
        #expect(first.defaultTabInterval == 144)
        #expect(first.runs.map(\.text) == ["Grace", " and ", "peace"])
        #expect(first.runs[0].style.fontName == "Helvetica-Bold")
        #expect(first.runs[0].style.size == 60)
        #expect(first.runs[0].style.bold)
        #expect(first.runs[0].style.fill == .solid(Color(red: 1, green: 0.87843, blue: 0.38039, alpha: 0.5)))
        #expect(first.runs[1].style.fill == .solid(.black))
        #expect(first.runs[2].style.fontName == "CMGSans-Light")
        #expect(first.runs[2].style.size == 50.625)
        #expect(doc.paragraphs[1].runs.map(\.text) == ["second line"])
    }

    @Test func unicodeEscapesAndCodePage() {
        let u = "\\" + "u"
        let rtf = Self.header + #"{\fonttbl\f0\fnil Helvetica;}{\colortbl;}"# + "\n"
            + #"\f0 It\'92s "# + #"\uc0"# + u + "8232 " + "next " + u + "-10179 " + u + "-8704 " + #"\~end}"#
        let doc = RTFReader.read(rtf)
        #expect(doc.paragraphs.count == 1)
        // U+2019, a line separator, a surrogate pair (U+1F600), a no-break space.
        #expect(doc.paragraphs[0].runs.map(\.text).joined() == "It\u{2019}s \u{2028}next \u{1F600}\u{00A0}end")
    }

    @Test func characterSpacingBaselineAndUnderline() {
        let rtf = Self.header + #"{\fonttbl\f0\fnil Helvetica;}"# + "\n"
            + #"\f0\fs100 \kerning1\expnd36\expndtw180 wide\expnd0\expndtw0  \super 2\nosupersub  \ul under\ulnone  \up10 up}"#
        let runs = RTFReader.read(rtf).paragraphs[0].runs
        #expect(runs[0].text == "wide")
        #expect(runs[0].style.characterSpacing == 9)
        #expect(runs.first { $0.text == "2" }?.style.superscript == 1)
        #expect(runs.first { $0.text == "under" }?.style.underline == true)
        #expect(runs.first { $0.text == "up" }?.style.baselineOffset == 5)
    }

    @Test func listsBecomeBullets() {
        let rtf = Self.header + #"{\fonttbl\f0\fnil Helvetica;}"# + "\n"
            + #"{\*\listtable{\list\listtemplateid1\listhybrid{\listlevel\levelnfc0{\leveltext\leveltemplateid1\'02\'00.;}{\levelnumbers\'01;}\fi-360\li720\lin720 }{\listname ;}\listid1}}"# + "\n"
            + #"\pard\tx20\tx4000\li4000\fi-4000\pardirnatural\partightenfactor0"# + "\n"
            + #"\ls1\ilvl0\f0\fs100 {\listtext\#t1.\#t}First\"# + "\n" + #"{\listtext\#t2.\#t}Second}"#
        let doc = RTFReader.read(rtf)
        #expect(doc.paragraphs.count == 2)
        #expect(doc.paragraphs[0].bullet == .number(scheme: "arabicPeriod", startAt: 1))
        #expect(doc.paragraphs[1].bullet == .number(scheme: "arabicPeriod", startAt: 2))
        #expect(doc.paragraphs[0].runs.map(\.text).joined() == "First")
        #expect(doc.paragraphs[0].leftIndent == 200)
        #expect(doc.paragraphs[0].firstLineIndent == -200)
        // The marker ("\t1.\t") counts in ProPresenter's places, before the words.
        #expect(doc.markerLengths == [4, 4])
        #expect(doc.paragraphStarts == [4, 14])
    }

    @Test func emptyTextIsOneEmptyParagraph() {
        let rtf = Self.header + #"{\fonttbl}"# + "\n" + #"{\colortbl;\red255\green255\blue255;}"# + "\n" + #"{\*\expandedcolortbl;;}"# + "\n}"
        let doc = RTFReader.read(rtf)
        #expect(doc.paragraphs.count == 1)
        #expect(doc.paragraphs[0].runs.isEmpty)
    }

    @Test func rangesSplitRuns() {
        let rtf = Self.header + #"{\fonttbl\f0\fnil Helvetica;}"# + "\n" + #"\f0 Think big\"# + "\n" + #"start small}"#
        var doc = RTFReader.read(rtf)
        // "big" (6..<9) and "start" (10..<15): the break between paragraphs counts one.
        ElementMapper.apply(to: &doc, start: 6, end: 9) { $0.capitalization = .allCaps }
        ElementMapper.apply(to: &doc, start: 10, end: 15) { $0.underline = true }
        #expect(doc.paragraphs[0].runs.map(\.text) == ["Think ", "big"])
        #expect(doc.paragraphs[0].runs[1].style.capitalization == .allCaps)
        #expect(doc.paragraphs[0].runs[0].style.capitalization == RunStyle.Capitalization.none)
        #expect(doc.paragraphs[1].runs.map(\.text) == ["start", " small"])
        #expect(doc.paragraphs[1].runs[0].style.underline)
    }

    @Test func notRTFIsPlainWords() {
        let doc = RTFReader.read("just words\nand more")
        #expect(doc.paragraphs.map { $0.runs.map(\.text).joined() } == ["just words", "and more"])
    }
}

extension RTFReaderTests {
    /// The empty line after a final break keeps the size and spacing in force at the end,
    /// not those from before the document began.
    @Test func lastEmptyParagraphKeepsTheStyleInForce() {
        let rtf = Self.header + #"{\fonttbl\f0\fnil Helvetica;}"# + "\n"
            + #"\pard\sb100\sa100\qc\f0\fs130 words\"# + "\n}"
        let doc = RTFReader.read(rtf)
        #expect(doc.paragraphs.count == 2)
        #expect(doc.paragraphs[1].endStyle.size == 65)
        #expect(doc.paragraphs[1].spaceBefore == 5)
        #expect(doc.paragraphs[1].alignment == .center)
    }
}
