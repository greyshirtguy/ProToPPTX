// MediaRegistry: the media files of a deck, each put into the .pptx once.
//
// A background carried over to twenty slides is one picture in the file, which twenty
// slides point to: the registry gives each media file its part name ("image3.png") the
// first time a slide asks for it, and the same name every time after.
//
// Pictures are read when first asked for, to learn their size in pixels (the writer needs
// it to fit a picture as ProPresenter would) and to check they can be read at all.
// Pictures in a format PowerPoint may not show (HEIC, WebP, PSD, and anything else
// ImageIO reads that is not PNG, JPEG, GIF, BMP or TIFF) are turned into PNG. Videos and
// sounds are not read until the file is written, and are put in as they are.

import DeckModel
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZipKit

struct MediaPart {
    /// The part's file name in ppt/media.
    let name: String
    let pixelSize: Size?
}

final class MediaRegistry {
    private struct Entry {
        let part: MediaPart
        let source: MediaSource
        /// Bytes already in hand (a picture turned into PNG); otherwise read at writing.
        let data: Data?
    }

    private var byKey: [String: Entry] = [:]
    private var order: [String] = []
    private var imageCount = 0
    private var mediaCount = 0

    static let pictureTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff"]

    func part(for media: Media) throws -> MediaPart {
        let key = "\(media.source.hashValue):\(media.fileName)"
        if let found = byKey[key] { return found.part }

        let entry: Entry
        switch media.kind {
        case .image:
            let original = try media.source.load()
            guard let image = CGImageSourceCreateWithData(original as CFData, nil),
                  CGImageSourceGetCount(image) > 0 else {
                throw MediaSource.LoadError.missing(media.fileName)
            }
            let size = Self.pixelSize(image)
            imageCount += 1
            var ext = media.fileExtension
            var data: Data? = original
            if !Self.pictureTypes.contains(ext) {
                data = Self.png(image) ?? original
                ext = "png"
            }
            if ext == "jpeg" { ext = "jpg" }
            if ext == "tif" { ext = "tiff" }
            entry = Entry(part: MediaPart(name: "image\(imageCount).\(ext)", pixelSize: size), source: media.source, data: data)
        case .video, .audio:
            if case .missing(let path) = media.source { throw MediaSource.LoadError.missing(path) }
            mediaCount += 1
            let ext = media.fileExtension.isEmpty ? (media.kind == .video ? "mov" : "m4a") : media.fileExtension
            entry = Entry(part: MediaPart(name: "media\(mediaCount).\(ext)", pixelSize: media.naturalSize), source: media.source, data: nil)
        }
        byKey[key] = entry
        order.append(key)
        return entry.part
    }

    /// The extensions used, for [Content_Types].xml.
    var extensions: Set<String> {
        Set(order.compactMap { byKey[$0].map { ($0.part.name as NSString).pathExtension.lowercased() } })
    }

    /// Writes every media file into the archive, as it is (they are compressed already).
    func write(into zip: ZipWriter) throws {
        for key in order {
            guard let entry = byKey[key] else { continue }
            let data = try entry.data ?? entry.source.load()
            try zip.add(path: "ppt/media/\(entry.part.name)", data: data, packing: .store)
        }
    }

    static func contentType(_ ext: String) -> String {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        case "wmv": return "video/x-ms-wmv"
        case "avi": return "video/x-msvideo"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    private static func pixelSize(_ source: CGImageSource) -> Size? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              var h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        // A picture taken on its side says so, and is shown turned.
        if let o = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(o) { swap(&w, &h) }
        return Size(width: w, height: h)
    }

    private static func png(_ source: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
