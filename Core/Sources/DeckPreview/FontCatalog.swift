// FontCatalog: what this Mac knows of a font, found by its PostScript name.
//
// Why: ProPresenter names a font by its PostScript name ("CMGSans-BoldCn",
// "HelveticaNeue-Bold"); PowerPoint names it by a family and two switches, bold and
// italic. The family PowerPoint (like every Office program) means is the font's
// "legacy" family, the one in name ID 1 of its name table, in which a family has at
// most four faces: regular, bold, italic and bold italic. Every other face is a family
// of its own there: "CMG Sans Bold Condensed" is family "CMG Sans Bold Cn" or the like,
// whatever its maker wrote. CoreText's own "family name" is the newer, typographic
// family (name ID 16, "CMG Sans"), which PowerPoint would not find the right face by.
// So the name table is read here for IDs 1 and 2.
//
// A font that is not installed on this Mac is not in the catalogue; the caller falls
// back to what the presentation itself says of it.

import AppKit
import CoreText
import Foundation

public struct FontFace: Sendable, Equatable {
    public var postScriptName: String
    /// The typographic family ("CMG Sans").
    public var family: String
    /// The full name ("CMG Sans Bold Condensed").
    public var fullName: String
    /// The family Office goes by (name ID 1).
    public var legacyFamily: String
    /// "Regular", "Bold", "Italic" or "Bold Italic" (name ID 2), as Office reads it.
    public var legacySubfamily: String

    public var isBold: Bool { legacySubfamily.localizedCaseInsensitiveContains("bold") }
    public var isItalic: Bool {
        legacySubfamily.localizedCaseInsensitiveContains("italic") || legacySubfamily.localizedCaseInsensitiveContains("oblique")
    }

    /// Whether the legacy names follow Office's rule of four faces to a family. Apple's
    /// own fonts often do not: Helvetica Neue's name ID 2 says "Condensed Black" or
    /// "Medium", which no family-and-switches can select.
    var hasOfficeStyle: Bool {
        ["regular", "bold", "italic", "bold italic", "oblique", "bold oblique", "roman", "normal"]
            .contains(legacySubfamily.lowercased())
    }

    /// The name PowerPoint finds this face by: its legacy family, or, when that does not
    /// follow Office's rule (`hasOfficeStyle`), its full name ("Helvetica Neue Condensed
    /// Black", which PowerPoint for the Mac lists as a font of its own).
    public var officeTypeface: String { hasOfficeStyle ? legacyFamily : fullName }
    /// PowerPoint's bold and italic switches for the face, beside `officeTypeface`.
    public var officeBold: Bool { hasOfficeStyle && isBold }
    public var officeItalic: Bool { hasOfficeStyle && isItalic }
}

public enum FontCatalog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: FontFace?] = [:]

    /// The face macOS draws for this font with RTF's bold and italic switches: the font
    /// itself if it is bold (italic) already or the switch is off, else its family's bold
    /// (italic) face, if the family has one. Nil if the font is not installed.
    public static func face(postScriptName name: String, bold: Bool, italic: Bool) -> FontFace? {
        guard let plain = face(postScriptName: name) else { return nil }
        let wantBold = bold && !plain.isBold && !isBoldByWeight(name)
        let wantItalic = italic && !plain.isItalic
        guard wantBold || wantItalic, let font = NSFont(name: name, size: 12) else { return plain }
        var traits: NSFontTraitMask = []
        if wantBold { traits.insert(.boldFontMask) }
        if wantItalic { traits.insert(.italicFontMask) }
        let converted = NSFontManager.shared.convert(font, toHaveTrait: traits)
        guard let convertedName = converted.fontDescriptor.postscriptName, convertedName != name else { return plain }
        return face(postScriptName: convertedName) ?? plain
    }

    /// True for faces that are bold by their weight though their names do not say so
    /// to Office ("Black", "Heavy", "ExtraBold" faces): macOS does not make them bolder.
    private static func isBoldByWeight(_ name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        return CTFontGetSymbolicTraits(font).contains(.traitBold)
    }

    /// The installed font with exactly this PostScript name, or nil if there is none.
    public static func face(postScriptName name: String) -> FontFace? {
        lock.lock()
        if let found = known[name] { lock.unlock(); return found }
        lock.unlock()

        let font = CTFontCreateWithName(name as CFString, 12, nil)
        let actual = CTFontCopyPostScriptName(font) as String
        var face: FontFace?
        if actual == name {
            let family = CTFontCopyFamilyName(font) as String
            let full = CTFontCopyFullName(font) as String
            let names = legacyNames(font)
            face = FontFace(
                postScriptName: name, family: family, fullName: full,
                legacyFamily: names?.family ?? family, legacySubfamily: names?.subfamily ?? styleGuess(font)
            )
        }
        lock.lock()
        known[name] = face
        lock.unlock()
        return face
    }

    private static func styleGuess(_ font: CTFont) -> String {
        let traits = CTFontGetSymbolicTraits(font)
        switch (traits.contains(.traitBold), traits.contains(.traitItalic)) {
        case (true, true): return "Bold Italic"
        case (true, false): return "Bold"
        case (false, true): return "Italic"
        default: return "Regular"
        }
    }

    /// Name IDs 1 and 2 of the font's name table: Windows' English names if it has them,
    /// else the Mac's.
    private static func legacyNames(_ font: CTFont) -> (family: String, subfamily: String)? {
        guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableName), []) as Data? else { return nil }
        let bytes = [UInt8](table)
        func u16(_ i: Int) -> Int { i + 1 < bytes.count ? Int(bytes[i]) << 8 | Int(bytes[i + 1]) : 0 }
        guard bytes.count >= 6 else { return nil }
        let count = u16(2), storage = u16(4)
        var best: [Int: (rank: Int, value: String)] = [:]
        for k in 0..<count {
            let r = 6 + k * 12
            guard r + 12 <= bytes.count else { break }
            let platform = u16(r), encoding = u16(r + 2), language = u16(r + 4), id = u16(r + 6)
            let length = u16(r + 8), offset = u16(r + 10)
            guard id == 1 || id == 2 else { continue }
            let start = storage + offset
            guard start + length <= bytes.count else { continue }
            let slice = Array(bytes[start..<(start + length)])
            var rank = 0
            var value: String?
            if platform == 3, encoding == 1 || encoding == 0 {
                rank = language == 0x409 ? 3 : 2
                var units: [UInt16] = []
                var j = 0
                while j + 1 < slice.count { units.append(UInt16(slice[j]) << 8 | UInt16(slice[j + 1])); j += 2 }
                value = String(decoding: units, as: UTF16.self)
            } else if platform == 1, encoding == 0 {
                rank = language == 0 ? 1 : 0
                value = String(bytes: slice, encoding: .macOSRoman)
            }
            if let value, !value.isEmpty, rank > (best[id]?.rank ?? -1) { best[id] = (rank, value) }
        }
        guard let family = best[1]?.value else { return nil }
        return (family, best[2]?.value ?? "Regular")
    }
}
