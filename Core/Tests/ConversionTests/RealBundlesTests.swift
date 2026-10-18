// The maintainer's own presentations, converted: run only on the maintainer's Mac, when
// "Pro Bundles (Some with exported slides)" is beside the repository and asked for:
//
//     PROTOPPTX_REAL_BUNDLES=1 swift test --filter RealBundles
//
// They are real services, so nothing from them is printed but counts and numbers
// (AGENTS.md, "The person's files"). PROTOPPTX_DEBUG_SLIDE="<bundle file name>:<slide>"
// prints how one slide's text boxes are laid out, as numbers.

import AppKit
import Conversion
import DeckModel
import DeckPreview
import Foundation
import Testing
import TestSupport
import ZipKit

@Suite struct RealBundlesTests {
    static func bundles() -> [URL] {
        guard let folder = TestFiles.realBundles,
              let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "probundle" }.sorted { $0.path < $1.path }
    }

    @Test func everyBundleConverts() throws {
        let all = Self.bundles()
        guard !all.isEmpty else { return }
        let out = try TestFiles.scratchFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        for (k, bundle) in all.enumerated() {
            let loaded = try Converter.load(bundle, options: ConversionOptions())
            let notes = try Converter.write(loaded, to: out.appendingPathComponent("\(k).pptx"), options: ConversionOptions())
            // Every part valid as PowerPoint reads it, not only well-formed.
            let zip = try ZipReader(url: out.appendingPathComponent("\(k).pptx"))
            for entry in zip.entries where entry.path.hasSuffix(".xml") {
                let problems = OOXMLLint.problems(in: String(decoding: try zip.contents(of: entry), as: UTF8.self))
                #expect(problems.isEmpty, "bundle \(k) \(entry.path): \(problems.prefix(5))")
            }
            let carried = loaded.deck.slides.filter { $0.background?.isCarriedOver == true }.count
            print("NUMBERS bundle \(k): \(loaded.deck.slides.count) slides, \(carried) with carried backgrounds, \(notes.count) notes")
            #expect(!loaded.deck.slides.isEmpty)
        }
    }

    @Test func debugSlide() throws {
        guard let spec = ProcessInfo.processInfo.environment["PROTOPPTX_DEBUG_SLIDE"],
              let colon = spec.lastIndex(of: ":"), let number = Int(spec[spec.index(after: colon)...]),
              let bundle = Self.bundles().first(where: { $0.lastPathComponent.contains(spec[..<colon]) }) else { return }
        let deck = try Converter.load(bundle, options: ConversionOptions()).deck
        let slide = deck.slides[number - 1]
        for case .shape(let shape) in slide.items {
            guard let body = shape.text else { continue }
            var scale = 1.0
            if case .shrink(let s) = body.autofit { scale = s }
            let width = shape.frame.width - body.insets.left - body.insets.right
            let laid = TextLayout.lines(of: body, width: width, fontScale: scale)
            print("BOX frame \(shape.frame) insets \(body.insets) align \(body.verticalAlignment) autofit \(body.autofit) height \(laid.height)")
            for (k, p) in body.paragraphs.enumerated() {
                let sizes = p.runs.map(\.style.size)
                print("  PARAGRAPH \(k): \(p.runs.count) runs, chars \(p.runs.reduce(0) { $0 + $1.text.count }), sizes \(sizes), spacing \(String(describing: p.lineSpacing)) before \(p.spaceBefore) after \(p.spaceAfter) end size \(p.endStyle.size)")
            }
            for line in laid.lines { print("  LINE paragraph \(line.paragraph) size \(line.largestSize) baseline \(line.baseline)") }
        }
    }
}

/// How AppKit's own RTF reader lays a slide's text boxes out (what ProPresenter, a Mac
/// app, presumably does), next to how TextLayout does: numbers only.
@Suite struct AppKitOracle {
    @Test func compareSlide() throws {
        guard let spec = ProcessInfo.processInfo.environment["PROTOPPTX_ORACLE_SLIDE"],
              let colon = spec.lastIndex(of: ":"), let number = Int(spec[spec.index(after: colon)...]),
              let bundle = RealBundlesTests.bundles().first(where: { $0.lastPathComponent.contains(spec[..<colon]) }) else { return }
        let rtfs = try OracleSupport.rtfs(bundle: bundle, slide: number)
        for (k, rtf) in rtfs.enumerated() {
            guard let s = NSAttributedString(rtf: rtf.data, documentAttributes: nil) else { continue }
            let width = rtf.width
            let bounding = s.boundingRect(with: NSSize(width: width, height: 1e6), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            let storage = NSTextStorage(attributedString: s)
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: width, height: 1e6))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container).height
            var lines: [String] = []
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, usedRect, _, glyphs, _ in
                let base = rect.minY + manager.location(forGlyphAt: glyphs.location).y
                lines.append("[\(rect.minY), h \(rect.height), used \(usedRect.height), base \(base)]")
            }
            let extra = manager.extraLineFragmentRect
            let ct = CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(s), CFRange(location: 0, length: 0), nil, CGSize(width: width, height: 1e6), nil).height
            print("ORACLE box \(k): length \(s.length) endsWithNewline \(s.string.hasSuffix("\n")) bounding \(bounding) used \(used) coretext \(ct) extra \(extra.height) lines \(lines.joined(separator: " "))")
        }
    }
}

/// Lists, as numbers, the centred text boxes whose words end with a paragraph break.
@Suite struct TrailingBreakScan {
    @Test func scan() throws {
        guard ProcessInfo.processInfo.environment["PROTOPPTX_SCAN"] != nil else { return }
        for (b, bundle) in RealBundlesTests.bundles().enumerated() {
            let deck = try Converter.load(bundle, options: ConversionOptions()).deck
            for (s, slide) in deck.slides.enumerated() {
                for case .shape(let shape) in slide.items {
                    guard let body = shape.text, body.verticalAlignment != .top, body.paragraphs.count > 1,
                          let last = body.paragraphs.last, last.runs.isEmpty else { continue }
                    let before = body.paragraphs[body.paragraphs.count - 2]
                    print("SCAN bundle \(b) \(bundle.deletingPathExtension().lastPathComponent.count) slide \(s + 1) align \(body.verticalAlignment) paragraphs \(body.paragraphs.count) lastSize \(before.runs.last?.style.size ?? 0) font \(before.runs.last?.style.fontName.count ?? 0) sb \(before.spaceBefore) sa \(before.spaceAfter) spacing \(String(describing: before.lineSpacing)) frameY \(shape.frame.y) h \(shape.frame.height)")
                }
            }
        }
    }
}

/// Lists, as numbers, text boxes with a line multiple other than 1, by alignment.
@Suite struct MultipleScan {
    @Test func scan() throws {
        guard ProcessInfo.processInfo.environment["PROTOPPTX_SCAN_MULTIPLES"] != nil else { return }
        for (b, bundle) in RealBundlesTests.bundles().enumerated() {
            let deck = try Converter.load(bundle, options: ConversionOptions()).deck
            for (s, slide) in deck.slides.enumerated() {
                for case .shape(let shape) in slide.items {
                    guard let body = shape.text else { continue }
                    let ms = Set(body.paragraphs.compactMap { p -> Double? in if case .multiple(let m)? = p.lineSpacing { return m } else { return nil } })
                    guard !ms.isEmpty else { continue }
                    let sizes = body.paragraphs.compactMap { $0.runs.map(\.style.size).max() }
                    print("MULT bundle \(b) slide \(s + 1) align \(body.verticalAlignment) m \(ms.sorted()) sizes \(sizes) y \(Int(shape.frame.y)) h \(Int(shape.frame.height)) x \(Int(shape.frame.x)) w \(Int(shape.frame.width))")
                }
            }
        }
    }
}
