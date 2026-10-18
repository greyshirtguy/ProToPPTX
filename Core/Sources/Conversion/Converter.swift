// Converter: the one thing the window and the command line both call.
//
// A presentation is read into a Deck (ProImport), which the window can draw
// (DeckPreview) before anything is written, and written out as a .pptx (PPTXWriter).
// Between the two, each video is given a still and its length (VideoStills), which
// PowerPoint needs and ProPresenter's file does not keep. Everything either front end
// can choose is in ConversionOptions, so the two cannot drift apart.

import DeckModel
import DeckPreview
import Foundation
import PPTXWriter
import ProImport

public enum Converter {
    /// Reads a presentation into a Deck, with notes on what could not be carried over.
    /// Videos are given their stills, so that the preview can show them.
    public static func load(_ url: URL, options: ConversionOptions) throws -> ImportResult {
        var result = try ProImporter.read(url, options: options)
        result.deck = VideoStills.prepare(result.deck)
        return result
    }

    /// Writes a deck read by `load` to a .pptx, and returns every note: the reading's
    /// and the writing's.
    public static func write(_ loaded: ImportResult, to output: URL, options: ConversionOptions) throws -> [ConversionNote] {
        let collector = NoteCollector()
        for note in loaded.notes {
            if note.slides.isEmpty {
                collector.add(note.kind, note.message)
            } else {
                for slide in note.slides { collector.add(note.kind, note.message, slide: slide) }
            }
        }
        try PPTXWriter.write(loaded.deck, to: output, options: options, notes: collector)
        return collector.all
    }

    /// Reads and writes in one go.
    @discardableResult
    public static func convert(_ input: URL, to output: URL, options: ConversionOptions) throws -> [ConversionNote] {
        try write(load(input, options: options), to: output, options: options)
    }

    /// The name a converted presentation is given by default: its own, as a .pptx.
    public static func defaultOutputName(for input: URL) -> String {
        input.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespaces) + ".pptx"
    }
}
