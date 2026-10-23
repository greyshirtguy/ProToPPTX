// Converter: the one thing the window and the command line both call.
//
// A presentation (a file, or one in a ProPresenter workspace: Workspaces) is read into
// a Deck (ProImport), which the window can draw
// (DeckPreview) before anything is written, and written out as a .pptx (PPTXWriter).
// Between the two, each video is given a still and its length (VideoStills), which
// PowerPoint needs and ProPresenter's file does not keep. Everything either front end
// can choose is in ConversionOptions, so the two cannot drift apart.

import DeckModel
import DeckPreview
import Foundation
import PPTXWriter
import ProImport
import Workspaces

public enum Converter {
    /// Reads a presentation file into a Deck, with notes on what could not be carried
    /// over. Videos are given their stills, so that the preview can show them.
    public static func load(_ url: URL, options: ConversionOptions) throws -> ImportResult {
        try load(.file(url), options: options)
    }

    /// Reads a presentation, a file or one in a workspace, into a Deck. `arrangement`
    /// is the arrangement a playlist's item chose, if it chose one.
    public static func load(_ ref: PresentationRef, arrangement: String? = nil, options: ConversionOptions) throws -> ImportResult {
        var result: ImportResult
        switch ref.location {
        case .file(let url):
            result = try ProImporter.read(url, workspaceFolder: ref.workspaceFolder, arrangement: arrangement, options: options)
        case .document(let store, let id):
            guard ref.isAvailable else { throw WorkspaceError.notAvailable(ref.name) }
            let presentation = try WorkspaceReader.presentation(store: store, id: id)
            result = try ProImporter.read(presentation, name: ref.name, workspaceFolder: ref.workspaceFolder, arrangement: arrangement, options: options)
        }
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

    /// Gives a deck made by hand (in a test) what `load` gives a read one: its videos'
    /// stills and lengths.
    public static func prepareForTest(_ loaded: ImportResult) throws -> ImportResult {
        var result = loaded
        result.deck = VideoStills.prepare(result.deck)
        return result
    }

    /// The name a converted presentation is given by default: its own, as a .pptx.
    public static func defaultOutputName(for input: URL) -> String {
        defaultOutputName(named: input.deletingPathExtension().lastPathComponent)
    }

    /// The same, for a presentation known by its name: the name, as a .pptx, with what a
    /// file's name cannot have ("/" and ":") put as "-".
    public static func defaultOutputName(named name: String) -> String {
        var safe = name.trimmingCharacters(in: .whitespaces)
        for bad in ["/", ":"] { safe = safe.replacingOccurrences(of: bad, with: "-") }
        if safe.hasPrefix(".") { safe = "-" + safe.dropFirst() }
        return (safe.isEmpty ? "Presentation" : safe) + ".pptx"
    }
}
