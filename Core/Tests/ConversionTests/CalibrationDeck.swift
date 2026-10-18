// The calibration deck: text boxes in several fonts, sizes, line spacings and vertical
// alignments, written as a .pptx and drawn by DeckPreview (which lays text out exactly
// as ProPresenter does: measured against its exported slides, 2026-10-18). PowerPoint's
// pictures of the .pptx are then compared with the preview's, to learn where PowerPoint
// puts lines that ProPresenter puts elsewhere (PPTXWriter/TextFit.swift has what was
// learnt).
//
// Not a test of anything by itself: it runs only when PROTOPPTX_CALIBRATION_OUT names a
// folder to write into.
//
//     PROTOPPTX_CALIBRATION_OUT=/some/folder swift test --filter CalibrationDeck

import AppKit
import Conversion
import DeckModel
import DeckPreview
import Foundation
import PPTXWriter
import Testing

@Suite struct CalibrationDeck {
    static let fonts = ["Helvetica", "CMGSans-Regular", "HelveticaNeue", "Georgia"]
    static let sizes = [60.0, 120.0]
    static let multiples = [1.0, 1.5, 2.0, 0.8]
    static let anchors: [TextBody.VerticalAlignment] = [.top, .middle]

    @Test func write() throws {
        guard let path = ProcessInfo.processInfo.environment["PROTOPPTX_CALIBRATION_OUT"] else { return }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var deck = Deck(size: Size(width: 1920, height: 1080), title: "Calibration")
        var index: [String] = []
        for anchor in Self.anchors {
            for size in Self.sizes {
                for m in Self.multiples {
                    var slide = Slide(backgroundColor: .black)
                    for (k, font) in Self.fonts.enumerated() {
                        let style = RunStyle(fontName: font, fontFamily: FontCatalog.face(postScriptName: font)?.officeTypeface ?? font, size: size, fill: .solid(.white))
                        let lines = (0..<3).map { _ in Paragraph(lineSpacing: m == 1 ? nil : .multiple(m), runs: [Run(text: "HHH", style: style)], endStyle: style) }
                        let body = TextBody(paragraphs: lines, insets: Insets(left: 5, top: 5, right: 5, bottom: 5), verticalAlignment: anchor)
                        slide.items.append(.shape(Shape(name: font, frame: Rect(x: 40 + Double(k) * 470, y: 100, width: 440, height: 880), text: body)))
                    }
                    deck.slides.append(slide)
                    index.append("\(deck.slides.count)\t\(anchor)\t\(size)\t\(m)")
                }
            }
        }
        let notes = NoteCollector()
        try PPTXWriter.write(deck, to: folder.appendingPathComponent("calibration.pptx"), options: ConversionOptions(), notes: notes)
        let renderer = SlideRenderer()
        let previews = folder.appendingPathComponent("preview")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        for (k, slide) in deck.slides.enumerated() {
            let image = try #require(renderer.render(slide, deckSize: deck.size, pixelWidth: 1920))
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: previews.appendingPathComponent("\(k + 1).png"))
        }
        try (index.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("index.tsv"), atomically: true, encoding: .utf8)
    }
}
