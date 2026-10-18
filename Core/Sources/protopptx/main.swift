// protopptx: the command line. For now it has only what development needs: `convert`
// with the default options, and `preview`, which draws the slides as the window would.
// The command line that is to come, with every option the window has, is described in
// docs/OPTIONS.md.

import AppKit
import Conversion
import DeckModel
import DeckPreview
import Foundation

let args = CommandLine.arguments

func usage() -> Never {
    print("""
    usage: protopptx convert <presentation.pro|.probundle> [-o <output.pptx>] [options]
           protopptx preview <presentation.pro|.probundle> <folder for pictures> [options]
    options: --no-carry-backgrounds  --backgrounds-as-pictures  --include-disabled
             --no-notes  --no-sections  --ignore-arrangement  --videos embed|stillOnly|leaveOut
    """)
    exit(2)
}

guard args.count >= 3 else { usage() }
let input = URL(fileURLWithPath: args[2])

// The options, one flag each, as docs/OPTIONS.md lists them.
var options = ConversionOptions()
var k = 3
while k < args.count {
    switch args[k] {
    case "--no-carry-backgrounds": options.carryBackgroundForward = false
    case "--backgrounds-as-pictures": options.backgroundPlacement = .pictureAtBack
    case "--include-disabled": options.skipDisabledSlides = false
    case "--no-notes": options.includeNotes = false
    case "--no-sections": options.groupsAsSections = false
    case "--ignore-arrangement": options.followArrangement = false
    case "--videos":
        k += 1
        guard k < args.count, let v = ConversionOptions.VideoHandling(rawValue: args[k]) else { usage() }
        options.videos = v
    case "-o": k += 1
    default: if args[1] != "preview" || k != 3 { usage() }
    }
    k += 1
}

do {
    switch args[1] {
    case "convert":
        var output = input.deletingLastPathComponent().appendingPathComponent(Converter.defaultOutputName(for: input))
        if let o = args.firstIndex(of: "-o"), o + 1 < args.count { output = URL(fileURLWithPath: args[o + 1]) }
        let notes = try Converter.convert(input, to: output, options: options)
        print("Wrote \(output.path)")
        for note in notes { print("  \(note.message)\(note.slides.isEmpty ? "" : " (\(note.slidesText))")") }
    case "preview":
        guard args.count >= 4 else { usage() }
        let folder = URL(fileURLWithPath: args[3])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = try Converter.load(input, options: options)
        let renderer = SlideRenderer()
        for (k, slide) in result.deck.slides.enumerated() {
            guard let image = renderer.render(slide, deckSize: result.deck.size, pixelWidth: 1920) else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("\(k + 1).png"))
            let bg = slide.background.map { "\($0.media.fileName)\($0.isCarriedOver ? " (carried from \($0.fromSlide ?? 0))" : "")" } ?? "-"
            print("\(k + 1)\t\(slide.caption)\tbackground: \(bg)\titems: \(slide.items.count)")
        }
        for note in result.notes { print("  \(note.message)\(note.slides.isEmpty ? "" : " (\(note.slidesText))")") }
    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("protopptx: \(error)\n".utf8))
    exit(1)
}
