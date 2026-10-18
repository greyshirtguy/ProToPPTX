// XML: the little needed to write Office Open XML as text.
//
// The parts are written as strings, by hand, rather than through a DOM: each is small,
// its shape is fixed by the standard, and a string can be read in a test as it will be
// in the file. Everything that comes from a presentation (words, names, file names)
// goes through `escape`, which also drops the characters XML 1.0 cannot hold at all.

import Foundation

enum XML {
    static let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"

    // The namespaces every part names.
    static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let p14 = "http://schemas.microsoft.com/office/powerpoint/2010/main"
    static let relationships = "http://schemas.openxmlformats.org/package/2006/relationships"

    /// `xmlns:a="…" xmlns:r="…" xmlns:p="…"`, for a part's root element.
    static let presentationNamespaces = #"xmlns:a="\#(a)" xmlns:r="\#(r)" xmlns:p="\#(p)""#

    /// Text made safe for an attribute or an element's content.
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                let v = scalar.value
                // Not allowed in XML 1.0 at all: the other control characters, the
                // surrogates' places, and U+FFFE and U+FFFF.
                if v < 0x20 || (0xD800...0xDFFF).contains(v) || v == 0xFFFE || v == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// One relationship of a part's .rels.
    struct Relationship {
        let id: String
        let type: String
        let target: String
        var external = false
    }

    static func relationships(_ list: [Relationship]) -> String {
        var s = header + #"<Relationships xmlns="\#(relationships)">"#
        for rel in list {
            s += #"<Relationship Id="\#(rel.id)" Type="\#(rel.type)" Target="\#(escape(rel.target))""#
            if rel.external { s += #" TargetMode="External""# }
            s += "/>"
        }
        return s + "</Relationships>"
    }

    enum RelType {
        static let officeDocument = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
        static let coreProperties = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
        static let extendedProperties = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties"
        static let slideMaster = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster"
        static let slideLayout = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout"
        static let slide = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"
        static let notesMaster = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster"
        static let notesSlide = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide"
        static let theme = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme"
        static let presProps = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/presProps"
        static let viewProps = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/viewProps"
        static let tableStyles = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/tableStyles"
        static let image = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
        static let video = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/video"
        static let audio = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/audio"
        static let media = "http://schemas.microsoft.com/office/2007/relationships/media"
    }
}
