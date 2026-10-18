// A deck with videos in it, to open in PowerPoint and see that it takes them: one as a
// slide's background, carried on to the next slide, and one in a box of its own.
// Runs only when PROTOPPTX_VIDEO is a video file and PROTOPPTX_VIDEO_OUT a folder.

import Conversion
import DeckModel
import Foundation
import PPTXWriter
import ProImport
import Testing

@Suite struct VideoDeck {
    @Test func write() throws {
        let env = ProcessInfo.processInfo.environment
        guard let video = env["PROTOPPTX_VIDEO"], let out = env["PROTOPPTX_VIDEO_OUT"] else { return }
        let media = Media(kind: .video, source: .file(URL(fileURLWithPath: video)), fileName: (video as NSString).lastPathComponent)
        let style = RunStyle(fontName: "Helvetica-Bold", fontFamily: "Helvetica", size: 90, bold: true, fill: .solid(.white))
        func words(_ s: String) -> Item {
            .shape(Shape(name: "Words", frame: Rect(x: 100, y: 800, width: 1720, height: 200),
                         text: TextBody(paragraphs: [Paragraph(alignment: .center, runs: [Run(text: s, style: style)], endStyle: style)])))
        }
        var deck = Deck(size: Size(width: 1920, height: 1080), title: "Video test", slides: [
            Slide(background: BackgroundMedia(media: media, scale: .fill), items: [words("A background video")]),
            Slide(background: BackgroundMedia(media: media, scale: .fill, isCarriedOver: true, fromSlide: 1), items: [words("Carried on")]),
            Slide(items: [.video(Video(name: "Video", frame: Rect(x: 480, y: 100, width: 960, height: 540), media: media, loops: false)), words("A video in a box")]),
        ])
        let loaded = ImportResult(deck: deck, notes: [], arrangement: nil)
        deck = try Converter.prepareForTest(loaded).deck
        #expect(deck.slides[0].background?.media.still != nil, "no still was made of the video")
        #expect((deck.slides[0].background?.media.duration ?? 0) > 0, "the video's length was not found")
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let notes = try Converter.write(ImportResult(deck: deck, notes: [], arrangement: nil), to: URL(fileURLWithPath: out).appendingPathComponent("video.pptx"), options: ConversionOptions())
        #expect(notes.isEmpty, "\(notes)")
    }
}
