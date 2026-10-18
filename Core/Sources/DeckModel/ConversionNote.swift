// ConversionNote: something the person should know about a conversion: what could not
// be carried over, or was carried over by a guess, and on which slides.
//
// Notes are collected while a presentation is read and written, and one note is made of
// many: "The font X is not installed" once, with every slide it is on, not once a slide.
// The window lists them beside the preview; the command line prints them.

import Foundation

public struct ConversionNote: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// A picture or video the presentation names could not be found.
        case missingMedia
        /// A font is not installed here: PowerPoint will show another until it is.
        case missingFont
        /// A macro was on a slide: what it does is not in the presentation.
        case macro
        /// A sound cue: not put into the deck.
        case audio
        /// Something ProPresenter does that PowerPoint cannot, left out or simplified.
        case simplified
    }

    public var kind: Kind
    public var message: String
    /// Slide numbers, from 1, in the deck as written.
    public var slides: [Int]

    public var id: String { "\(kind.rawValue):\(message)" }

    public init(kind: Kind, message: String, slides: [Int] = []) {
        self.kind = kind
        self.message = message
        self.slides = slides
    }

    /// "slide 3", "slides 2, 5 and 9".
    public var slidesText: String {
        let s = slides.sorted()
        guard !s.isEmpty else { return "" }
        if s.count == 1 { return "slide \(s[0])" }
        return "slides " + s.dropLast().map(String.init).joined(separator: ", ") + " and \(s.last!)"
    }
}

/// Gathers notes, merging those that say the same thing.
public final class NoteCollector: @unchecked Sendable {
    private var order: [String] = []
    private var notes: [String: ConversionNote] = [:]
    private let lock = NSLock()

    public init() {}

    public func add(_ kind: ConversionNote.Kind, _ message: String, slide: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(kind.rawValue):\(message)"
        if notes[key] == nil {
            notes[key] = ConversionNote(kind: kind, message: message)
            order.append(key)
        }
        if let slide, !notes[key]!.slides.contains(slide) { notes[key]!.slides.append(slide) }
    }

    public var all: [ConversionNote] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { notes[$0] }
    }
}
