// The small values a Deck is made of: sizes, points, colours, insets, and media.
//
// Plain structs rather than CoreGraphics' own, so that the module needs nothing but
// Foundation and the values compare and hash the same everywhere.

import Foundation
import ZipKit

public struct Size: Sendable, Hashable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct Point: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A box, measured from the slide's top left corner, y downwards.
public struct Rect: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: Point, size: Size) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public var size: Size { Size(width: width, height: height) }

    /// The largest box of the given shape that fits inside this one, centred (`fit`), or
    /// the smallest that covers it (`fill`), or this box itself (`stretch`).
    public func placing(_ content: Size, _ mode: ScaleMode) -> Rect {
        guard content.width > 0, content.height > 0, mode != .stretch else { return self }
        let sx = width / content.width, sy = height / content.height
        let s = mode == .fit ? min(sx, sy) : max(sx, sy)
        let w = content.width * s, h = content.height * s
        return Rect(x: x + (width - w) / 2, y: y + (height - h) / 2, width: w, height: h)
    }
}

public struct Insets: Sendable, Hashable, Codable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double

    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public static let zero = Insets(left: 0, top: 0, right: 0, bottom: 0)
}

/// An sRGB colour with alpha, each 0...1.
public struct Color: Sendable, Hashable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = Color(red: 0, green: 0, blue: 0)
    public static let white = Color(red: 1, green: 1, blue: 1)

    /// "RRGGBB", as PowerPoint writes a colour.
    public var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    public func withAlpha(_ a: Double) -> Color { Color(red: red, green: green, blue: blue, alpha: a) }
}

// MARK: - Media

/// A picture, video or sound used by a slide, and where its bytes are.
public struct Media: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable { case image, video, audio }

    public var kind: Kind
    public var source: MediaSource
    /// The file's own name, as ProPresenter knew it ("Background.png").
    public var fileName: String
    /// Its size in pixels, when known.
    public var naturalSize: Size?
    /// A video's still (a PNG), shown before it plays and wherever it cannot be.
    /// Made by Conversion before the deck is written.
    public var still: MediaSource?
    /// A video's length in seconds, when known: PowerPoint wants it to start a video
    /// by itself.
    public var duration: Double?

    public init(kind: Kind, source: MediaSource, fileName: String, naturalSize: Size? = nil, still: MediaSource? = nil, duration: Double? = nil) {
        self.kind = kind
        self.source = source
        self.fileName = fileName
        self.naturalSize = naturalSize
        self.still = still
        self.duration = duration
    }

    /// A video's still, as a picture of its own.
    public var stillPicture: Media? {
        still.map { Media(kind: .image, source: $0, fileName: (fileName as NSString).deletingPathExtension + " (still).png", naturalSize: naturalSize) }
    }

    /// The file's extension, lower case ("png").
    public var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }

    public var isMissing: Bool {
        if case .missing = source { return true }
        return false
    }
}

/// Where a media file's bytes are to be had.
public enum MediaSource: Sendable, Hashable {
    /// A file on this Mac.
    case file(URL)
    /// An entry in a zip archive on this Mac (a .probundle).
    case zipEntry(archive: URL, path: String)
    /// Bytes already in memory (a still made from a video, say), with a name that tells
    /// one such apart from another.
    case data(Data, id: String)
    /// Not found: the path the presentation gave for it.
    case missing(String)

    public enum LoadError: Error, CustomStringConvertible {
        case missing(String)

        public var description: String {
            switch self {
            case .missing(let path): return "The media file \(path) could not be found."
            }
        }
    }

    /// The bytes. A file is mapped rather than read, so a large video costs nothing until
    /// it is written out.
    public func load() throws -> Data {
        switch self {
        case .file(let url):
            return try Data(contentsOf: url, options: .alwaysMapped)
        case .zipEntry(let archive, let path):
            let zip = try ZipReader(url: archive)
            guard let entry = zip.entry(path) else { throw LoadError.missing(path) }
            return try zip.contents(of: entry)
        case .data(let data, _):
            return data
        case .missing(let path):
            throw LoadError.missing(path)
        }
    }
}
