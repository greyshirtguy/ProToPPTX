// RTFReader: the words of a ProPresenter text box, with their fonts, sizes, colours and
// paragraph settings, out of the RTF ProPresenter keeps them in.
//
// Why by hand and not with AppKit's NSAttributedString(rtf:): AppKit puts another font
// in place of one that is not installed on this Mac, and forgets the name it was asked
// for. The name is what PowerPoint needs, so that the deck looks right on the Mac it is
// shown on, which may have fonts this one has not. Reading it ourselves keeps every name
// as written, works the same with or without the fonts, and can be tested anywhere.
//
// KNOWN: what ProPresenter writes is the RTF of macOS's own text system ("Cocoa RTF":
// \cocoartf, \expandedcolortbl). What this reads was settled by counting the control
// words in the maintainer's presentations (2026, ProPresenter 21.4), and it reads all
// of them: fonts and sizes (\f, \fs, \fsmilli), bold and italic, colours with alpha
// (\cf with \cssrgb, \csgray, \csgenericrgb), underline and strike, character spacing
// (\expnd, \expndtw), superscript and baseline (\super, \up), alignment, indents, line
// and paragraph spacing (\sl, \slmult, \slleading, \sa, \sb), tab stops, and lists
// (\ls, and the marker in {\listtext}). Anything else is passed over without harm: an
// unknown control word is ignored, and an unknown group marked \* is skipped whole.
//
// Units: RTF's twips are 1/20 of a point, and font sizes are half points. A point here
// is a unit of the ProPresenter slide (a pixel of a 1080p slide), because that is what
// ProPresenter's font sizes are; so twips / 20 is slide units, as Deck counts them.
//
// The text is counted as ProPresenter counts it (in UTF-16 units, a paragraph break
// being one, a list's marker being part of the text) so that the ranges
// ProPresenter keeps beside the RTF (capitalization, gradient fills) can be laid on it
// afterwards: `RTFDocument.paragraphs` keeps each run's start for that.
//
// Never write a backslash, a "u" and four digits into this file or its tests through a
// tool: it arrives as one character (see the maintainer's notes in other projects).
// Build such text from pieces: "\\" + "u" + "8232".

import CoreGraphics
import DeckModel
import Foundation

/// What the RTF of one text box says.
struct RTFDocument: Equatable {
    var paragraphs: [Paragraph]
    /// For each paragraph, how many UTF-16 units of list marker came before its runs:
    /// counted in ProPresenter's ranges, but not part of the words (Deck draws the marker
    /// itself, as a bullet).
    var markerLengths: [Int]
    /// The fonts the RTF names, in the order of its font table (PostScript names).
    var fontNames: [String]

    /// Where each paragraph's runs start, in ProPresenter's count of the whole text.
    var paragraphStarts: [Int] {
        var starts: [Int] = []
        var at = 0
        for (k, p) in paragraphs.enumerated() {
            starts.append(at + markerLengths[k])
            at += markerLengths[k] + p.runs.reduce(0) { $0 + $1.text.utf16.count } + 1
        }
        return starts
    }
}

struct RTFReader {
    /// Reads RTF. Never fails: what cannot be read is left out, and text that is not RTF
    /// at all comes back as one paragraph of plain words.
    static func read(_ data: Data) -> RTFDocument {
        var reader = RTFReader(bytes: [UInt8](data))
        return reader.parse()
    }

    static func read(_ string: String) -> RTFDocument { read(Data(string.utf8)) }

    // MARK: - State

    private enum Destination {
        case text
        case fontTable
        case colorTable
        case expandedColorTable
        case listText
        case skip
    }

    private struct CharacterState: Equatable {
        var font = 0
        var halfPoints = 24
        var milliPoints: Int?
        var bold = false
        var italic = false
        var underline = false
        var underlineColor = 0
        var strike = false
        var color = 0
        var background = 0
        var spacingTwips = 0
        var baselineHalfPoints = 0
        var superscript = 0
        var caps = RunStyle.Capitalization.none
    }

    private struct ParagraphState {
        var alignment = Paragraph.Alignment.left
        var leftTwips = 0
        var firstTwips = 0
        var rightTwips = 0
        var spaceBeforeTwips = 0
        var spaceAfterTwips = 0
        var lineTwips = 0
        var lineMultiple = false
        var leadingTwips = 0
        var tabStops: [Int] = []
        var defaultTabTwips = 0
        var isListItem = false
    }

    private struct GroupState {
        var destination = Destination.text
        var character = CharacterState()
        var paragraph = ParagraphState()
        var unicodeSkip = 1
    }

    private let bytes: [UInt8]
    private var i = 0
    private var state = GroupState()
    private var stack: [GroupState] = []

    // Tables
    private var fonts: [Int: String] = [:]
    private var fontOrder: [String] = []
    private var currentFont = 0
    private var fontNameBuffer = ""
    private var colors: [Color?] = []
    private var colorBuffer: (r: Int, g: Int, b: Int, set: Bool) = (0, 0, 0, false)
    private var expanded: [Color?] = []
    private var expandedSpace = ""
    private var expandedValues: [Int] = []

    // Output
    private var paragraphs: [Paragraph] = []
    private var markerLengths: [Int] = []
    private var runs: [Run] = []
    private var pendingText: [UInt16] = []
    private var pendingStyle: CharacterState?
    private var listMarker = ""
    private var paragraphOpenState = ParagraphState()
    private var sawText = false
    private var documentDefaultTab = 0
    private var documentEnd: GroupState?

    private init(bytes: [UInt8]) { self.bytes = bytes }

    // MARK: - Parsing

    private mutating func parse() -> RTFDocument {
        guard bytes.starts(with: Array("{\\rtf".utf8)) else {
            let words = String(decoding: bytes, as: UTF8.self)
            let style = RunStyle()
            let paragraphs = words.components(separatedBy: "\n").map {
                Paragraph(runs: $0.isEmpty ? [] : [Run(text: $0, style: style)], endStyle: style)
            }
            return RTFDocument(paragraphs: paragraphs, markerLengths: paragraphs.map { _ in 0 }, fontNames: [])
        }
        while i < bytes.count {
            let c = bytes[i]
            switch c {
            case UInt8(ascii: "{"):
                flushText()
                stack.append(state)
                i += 1
            case UInt8(ascii: "}"):
                flushText()
                endGroup()
                i += 1
            case UInt8(ascii: "\\"):
                controlWord()
            case 0x0A, 0x0D:
                i += 1
            default:
                plainCharacter(c)
                i += 1
            }
        }
        flushText()
        endParagraph(final: true)
        var order = fontOrder
        if order.isEmpty { order = fonts.keys.sorted().compactMap { fonts[$0] } }
        return RTFDocument(paragraphs: paragraphs, markerLengths: markerLengths, fontNames: order)
    }

    private mutating func endGroup() {
        if state.destination == .fontTable { finishFontName() }
        // The document's own group closing: what was in force at its end is what the last
        // paragraph has, not the state from before the document began.
        if stack.count == 1 { documentEnd = state }
        if let previous = stack.popLast() { state = previous }
    }

    private mutating func controlWord() {
        i += 1 // the backslash
        guard i < bytes.count else { return }
        let c = bytes[i]

        // Control symbols: a backslash and one character that is not a letter.
        if !isLetter(c) {
            i += 1
            switch c {
            case UInt8(ascii: "\\"), UInt8(ascii: "{"), UInt8(ascii: "}"):
                plainCharacter(c)
            case 0x0A, 0x0D:
                // Cocoa writes a paragraph's end as a backslash before the line break.
                paragraphBreak()
            case UInt8(ascii: "~"):
                appendUnit(0x00A0)
            case UInt8(ascii: "_"):
                appendUnit(0x2011)
            case UInt8(ascii: "-"):
                break // an optional hyphen: not shown unless the word breaks there
            case UInt8(ascii: "'"):
                if let byte = hexByte() { appendUnit(Self.windows1252(byte)) }
            case UInt8(ascii: "*"):
                // "What follows is a destination that may be ignored": skipped, unless it
                // is one of the few this reader knows (looked at by the word after it).
                if !nextWordIsKnownDestination() { state.destination = .skip }
            case 0x09:
                appendUnit(0x09)
            default:
                break
            }
            return
        }

        // A control word: letters, then perhaps a signed number, then perhaps one space.
        let start = i
        while i < bytes.count, isLetter(bytes[i]) { i += 1 }
        let word = String(decoding: bytes[start..<i], as: UTF8.self)
        var number: Int?
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") || isDigit(bytes[i]) {
            let numberStart = i
            i += 1
            while i < bytes.count, isDigit(bytes[i]) { i += 1 }
            number = Int(String(decoding: bytes[numberStart..<i], as: UTF8.self))
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: " ") { i += 1 }
        apply(word, number)
    }

    private mutating func apply(_ word: String, _ n: Int?) {
        // Destinations first: these change where the words of the group go.
        switch word {
        case "fonttbl": state.destination = .fontTable; return
        case "colortbl": state.destination = .colorTable; colors = []; return
        case "expandedcolortbl": state.destination = .expandedColorTable; expanded = []; return
        case "listtext": state.destination = .listText; return
        case "info", "stylesheet", "pict", "NeXTGraphic", "header", "footer", "footnote", "fldinst",
             "listtable", "listoverridetable", "themedata", "colorschememapping", "latentstyles", "generator":
            state.destination = .skip
            return
        default:
            break
        }
        if state.destination == .skip { return }

        if state.destination == .fontTable {
            if word == "f" {
                finishFontName()
                currentFont = n ?? 0
            }
            return
        }
        if state.destination == .colorTable {
            switch word {
            case "red": colorBuffer.r = n ?? 0; colorBuffer.set = true
            case "green": colorBuffer.g = n ?? 0; colorBuffer.set = true
            case "blue": colorBuffer.b = n ?? 0; colorBuffer.set = true
            default: break
            }
            return
        }
        if state.destination == .expandedColorTable {
            switch word {
            case "cssrgb", "csgray", "csgenericrgb", "csgenericgray", "csdisplayp3", "csdevicergb":
                expandedSpace = word
                expandedValues = []
            case "c":
                expandedValues.append(n ?? 0)
            default:
                break
            }
            return
        }

        var ch = state.character
        var pa = state.paragraph
        switch word {
        // Paragraphs
        case "par": paragraphBreak(); return
        case "line": appendUnit(0x2028)
        case "tab": appendUnit(0x09)
        case "pard": pa = ParagraphState(defaultTabTwips: documentDefaultTab)
        case "deftab": documentDefaultTab = n ?? 0; pa.defaultTabTwips = documentDefaultTab
        case "pardeftab": pa.defaultTabTwips = n ?? 0
        case "ql", "qn": pa.alignment = .left
        case "qc": pa.alignment = .center
        case "qr": pa.alignment = .right
        case "qj": pa.alignment = .justified
        case "li": pa.leftTwips = n ?? 0
        case "fi": pa.firstTwips = n ?? 0
        case "ri": pa.rightTwips = n ?? 0
        case "sb": pa.spaceBeforeTwips = n ?? 0
        case "sa": pa.spaceAfterTwips = n ?? 0
        case "sl": pa.lineTwips = n ?? 0
        case "slmult": pa.lineMultiple = (n ?? 0) != 0
        case "slleading": pa.leadingTwips = n ?? 0
        case "tx": pa.tabStops.append(n ?? 0)
        case "ls": pa.isListItem = true
        // Characters
        case "plain": ch = CharacterState()
        case "f": ch.font = n ?? 0
        case "fs": ch.halfPoints = n ?? 24; ch.milliPoints = nil
        case "fsmilli": ch.milliPoints = n
        case "b": ch.bold = (n ?? 1) != 0
        case "i": ch.italic = (n ?? 1) != 0
        case "ul", "uld", "uldb", "ulth", "ulw", "uldash", "uldashd", "uldashdd", "ulwave", "ulhwave", "ululdbwave":
            ch.underline = (n ?? 1) != 0
        case "ulnone": ch.underline = false
        case "ulc": ch.underlineColor = n ?? 0
        case "strike", "striked": ch.strike = (n ?? 1) != 0
        case "cf": ch.color = n ?? 0
        case "cb", "highlight": ch.background = n ?? 0
        // Cocoa writes both, \expnd (quarter points) and then \expndtw (twips, finer),
        // so the second has the last word.
        case "expnd": ch.spacingTwips = (n ?? 0) * 5
        case "expndtw": ch.spacingTwips = n ?? 0
        case "up": ch.baselineHalfPoints = n ?? 6
        case "dn": ch.baselineHalfPoints = -(n ?? 6)
        case "super": ch.superscript = 1
        case "sub": ch.superscript = -1
        case "nosupersub": ch.superscript = 0
        case "caps": ch.caps = (n ?? 1) != 0 ? .allCaps : .none
        case "scaps": ch.caps = (n ?? 1) != 0 ? .smallCaps : .none
        // Unicode
        case "uc": state.unicodeSkip = max(0, n ?? 1)
        case "u":
            if var v = n {
                if v < 0 { v += 65_536 }
                appendUnit(UInt16(truncatingIfNeeded: v))
                skipFallback(state.unicodeSkip)
            }
        default:
            break
        }
        state.character = ch
        state.paragraph = pa
    }

    // MARK: - Words

    private mutating func plainCharacter(_ c: UInt8) {
        switch state.destination {
        case .fontTable:
            if c == UInt8(ascii: ";") { finishFontName() } else { fontNameBuffer.append(Character(Unicode.Scalar(c))) }
        case .colorTable:
            if c == UInt8(ascii: ";") {
                colors.append(colorBuffer.set
                    ? Color(red: Double(colorBuffer.r) / 255, green: Double(colorBuffer.g) / 255, blue: Double(colorBuffer.b) / 255)
                    : nil)
                colorBuffer = (0, 0, 0, false)
            }
        case .expandedColorTable:
            if c == UInt8(ascii: ";") {
                expanded.append(Self.expandedColor(expandedSpace, expandedValues))
                expandedSpace = ""
                expandedValues = []
            }
        case .skip:
            break
        case .text, .listText:
            appendUnit(Self.windows1252(c))
        }
    }

    private mutating func appendUnit(_ unit: UInt16) {
        switch state.destination {
        case .listText:
            listMarker.append(String(decoding: [unit], as: UTF16.self))
            // The marker is part of the text as ProPresenter counts it.
            return appendToRun(unit, marker: true)
        case .text:
            appendToRun(unit, marker: false)
        default:
            break
        }
    }

    private mutating func appendToRun(_ unit: UInt16, marker: Bool) {
        if marker {
            // Counted, but kept apart from the words: see `markerUnits`.
            markerUnits += 1
            return
        }
        if pendingStyle != state.character, !pendingText.isEmpty { flushText() }
        if pendingText.isEmpty {
            pendingStyle = state.character
            if !sawText { paragraphOpenState = state.paragraph }
        }
        sawText = true
        pendingText.append(unit)
    }

    /// How many UTF-16 units of list marker the current paragraph has had.
    private var markerUnits = 0

    private mutating func flushText() {
        guard !pendingText.isEmpty, let style = pendingStyle else { return }
        let text = String(decoding: pendingText, as: UTF16.self)
        if let last = runs.last, last.style == runStyle(style) {
            runs[runs.count - 1].text += text
        } else {
            runs.append(Run(text: text, style: runStyle(style)))
        }
        pendingText = []
    }

    private mutating func paragraphBreak() {
        flushText()
        endParagraph(final: false)
    }

    private mutating func endParagraph(final: Bool) {
        // The paragraph's settings are those in force where its text began, or at its
        // end if it has none (an empty line).
        let closing = final ? (documentEnd ?? state) : state
        let pa = sawText ? paragraphOpenState : closing.paragraph
        var paragraph = Paragraph(
            alignment: pa.alignment,
            lineSpacing: Self.lineSpacing(pa),
            extraLeading: Double(pa.leadingTwips) / 20,
            spaceBefore: Double(pa.spaceBeforeTwips) / 20,
            spaceAfter: Double(pa.spaceAfterTwips) / 20,
            leftIndent: Double(pa.leftTwips) / 20,
            firstLineIndent: Double(pa.firstTwips) / 20,
            rightIndent: Double(pa.rightTwips) / 20,
            bullet: nil,
            // (Cocoa writes stops left of the margin, \tx-100, that macOS ignores.)
            tabStops: pa.tabStops.filter { $0 > 0 }.map { Double($0) / 20 },
            defaultTabInterval: Double(pa.defaultTabTwips) / 20,
            runs: runs,
            endStyle: runStyle(closing.character)
        )
        if pa.isListItem || markerUnits > 0 {
            paragraph.bullet = Self.bullet(fromMarker: listMarker)
        }
        // Cocoa ends the last paragraph without a \par, so what follows the last break is
        // always a paragraph, if an empty one: "A", a break and nothing is two lines, the
        // second empty, as macOS lays it out. (`final` is kept for saying so here.)
        _ = final
        paragraphs.append(paragraph)
        markerLengths.append(markerUnits)
        resetParagraph()
    }

    private mutating func resetParagraph() {
        runs = []
        listMarker = ""
        markerUnits = 0
        sawText = false
    }

    private mutating func finishFontName() {
        let name = fontNameBuffer.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            fonts[currentFont] = name
            if !fontOrder.contains(name) { fontOrder.append(name) }
        }
        fontNameBuffer = ""
    }

    private mutating func skipFallback(_ count: Int) {
        // After \uN come N characters for readers that do not know Unicode: a character,
        // or a \'hh, each counting one.
        var left = count
        while left > 0, i < bytes.count {
            if bytes[i] == UInt8(ascii: "\\"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "'") {
                i += 4
            } else if bytes[i] == UInt8(ascii: "{") || bytes[i] == UInt8(ascii: "}") || bytes[i] == UInt8(ascii: "\\") {
                return
            } else {
                i += 1
            }
            left -= 1
        }
    }

    private mutating func hexByte() -> UInt8? {
        guard i + 2 <= bytes.count, let v = UInt8(String(decoding: bytes[i..<(i + 2)], as: UTF8.self), radix: 16) else { return nil }
        i += 2
        return v
    }

    private func nextWordIsKnownDestination() -> Bool {
        var j = i
        guard j < bytes.count, bytes[j] == UInt8(ascii: "\\") else { return false }
        j += 1
        let start = j
        while j < bytes.count, isLetter(bytes[j]) { j += 1 }
        let word = String(decoding: bytes[start..<j], as: UTF8.self)
        return word == "expandedcolortbl"
    }

    // MARK: - Turning state into Deck's values

    private func color(_ index: Int) -> Color? {
        if index < expanded.count, let c = expanded[index] { return c }
        if index < colors.count { return colors[index] }
        return nil
    }

    private func runStyle(_ ch: CharacterState) -> RunStyle {
        let size = ch.milliPoints.map { Double($0) / 1000 } ?? Double(ch.halfPoints) / 2
        let name = fonts[ch.font] ?? fontOrder.first ?? "Helvetica"
        return RunStyle(
            fontName: name,
            fontFamily: "",
            size: size,
            bold: ch.bold,
            italic: ch.italic,
            underline: ch.underline,
            underlineColor: ch.underlineColor == 0 ? nil : color(ch.underlineColor),
            strikethrough: ch.strike,
            // Colour 0 is "automatic": macOS draws it black.
            fill: .solid(color(ch.color) ?? .black),
            characterSpacing: Double(ch.spacingTwips) / 20,
            baselineOffset: Double(ch.baselineHalfPoints) / 2,
            superscript: ch.superscript,
            capitalization: ch.caps,
            highlight: ch.background == 0 ? nil : color(ch.background)
        )
    }

    private static func lineSpacing(_ pa: ParagraphState) -> Paragraph.LineSpacing? {
        if pa.lineTwips == 0 { return nil }
        if pa.lineMultiple { return .multiple(Double(pa.lineTwips) / 240) }
        return pa.lineTwips > 0 ? .atLeast(Double(pa.lineTwips) / 20) : .exactly(Double(-pa.lineTwips) / 20)
    }

    /// The marker macOS wrote for a list item ("\t1.\t", "\t•\t") as a bullet
    /// PowerPoint can draw itself.
    static func bullet(fromMarker marker: String) -> Paragraph.Bullet? {
        let m = marker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return nil }
        let schemes: [(String, String)] = [
            (#"^(\d+)\.$"#, "arabicPeriod"), (#"^(\d+)\)$"#, "arabicParenR"), (#"^\((\d+)\)$"#, "arabicParenBoth"),
            (#"^(\d+)$"#, "arabicPlain"),
        ]
        for (pattern, scheme) in schemes {
            if let r = m.range(of: pattern, options: .regularExpression) {
                let digits = m[r].filter(\.isNumber)
                return .number(scheme: scheme, startAt: Int(digits) ?? 1)
            }
        }
        if m.count == 2, let first = m.first, first.isLetter, m.last == "." {
            let start = Int(first.lowercased().unicodeScalars.first!.value) - 96
            return .number(scheme: first.isUppercase ? "alphaUcPeriod" : "alphaLcPeriod", startAt: max(1, start))
        }
        return .character(String(m.prefix(1)))
    }

    /// A colour of the expanded table: values in 1/100000, alpha last if given.
    static func expandedColor(_ space: String, _ v: [Int]) -> Color? {
        func f(_ k: Int) -> Double { Double(v[k]) / 100_000 }
        switch space {
        case "cssrgb", "csdevicergb":
            guard v.count >= 3 else { return nil }
            return Color(red: f(0), green: f(1), blue: f(2), alpha: v.count >= 4 ? f(3) : 1)
        case "csgenericrgb", "csdisplayp3":
            guard v.count >= 3 else { return nil }
            let alpha = v.count >= 4 ? f(3) : 1
            // Generic RGB and Display P3 are near sRGB but not the same: converted properly.
            let fromName = space == "csgenericrgb" ? ("kCGColorSpaceGenericRGB" as CFString) : CGColorSpace.displayP3
            if let from = CGColorSpace(name: fromName), let srgb = CGColorSpace(name: CGColorSpace.sRGB),
               let cg = CGColor(colorSpace: from, components: [f(0), f(1), f(2), alpha]),
               let converted = cg.converted(to: srgb, intent: .defaultIntent, options: nil),
               let c = converted.components, c.count >= 3 {
                return Color(red: c[0], green: c[1], blue: c[2], alpha: alpha)
            }
            return Color(red: f(0), green: f(1), blue: f(2), alpha: alpha)
        case "csgray", "csgenericgray":
            guard v.count >= 1 else { return nil }
            return Color(red: f(0), green: f(0), blue: f(0), alpha: v.count >= 2 ? f(1) : 1)
        default:
            return nil
        }
    }

    private func isLetter(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
    private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    /// \ansicpg1252, which is all ProPresenter writes: the bytes 0x80–0x9F differ from
    /// Latin-1; the rest are the same.
    static func windows1252(_ b: UInt8) -> UInt16 {
        let high: [UInt16] = [
            0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
            0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
        ]
        if b >= 0x80, b <= 0x9F { return high[Int(b - 0x80)] }
        return UInt16(b)
    }
}
