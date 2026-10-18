// The window's own pieces drawn into pictures, to be looked at: the model that builds
// this app cannot see the screen, and macOS 26 will not draw the whole window into a
// picture from inside the app (its glass is drawn elsewhere). SwiftUI's ImageRenderer
// draws views made of SwiftUI's own parts, which these are.
//
//     PROTOPPTX_VIEW_PICTURES=<folder> PROTOPPTX_REAL_BUNDLES=1 swift test --filter ViewPictures
//
// With no folder named it draws them all the same and keeps nothing, which proves at
// least that they build and lay out.

import AppKit
import Conversion
import DeckModel
import Foundation
import SwiftUI
import Testing
import TestSupport
@testable import AppViews

@MainActor @Suite struct ViewPictures {
    func save<V: View>(_ view: V, _ name: String, width: CGFloat) {
        let renderer = ImageRenderer(content: view.frame(width: width).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.cgImage else { Issue.record("\(name) did not draw"); return }
        guard let folder = ProcessInfo.processInfo.environment["PROTOPPTX_VIEW_PICTURES"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    @Test func emptyState() {
        save(DropHint(add: {}).frame(height: 500), "drop-hint", width: 800)
    }

    @Test func notes() {
        let notes = [
            ConversionNote(kind: .missingMedia, message: "The media file Background.png could not be found", slides: [1, 2, 3]),
            ConversionNote(kind: .missingFont, message: "The font Montserrat-Bold is not installed on this Mac: PowerPoint will show another font until it is", slides: [4]),
            ConversionNote(kind: .macro, message: "The macro \"Clear All\" is not followed: if it changes the background, check these slides", slides: [5, 9]),
        ]
        save(VStack(alignment: .leading, spacing: 10) { ForEach(notes) { NoteRow(note: $0) } }.padding(), "notes", width: 320)
    }

    /// The slide grid's cells, for a real presentation when one is at hand.
    @Test func slideCells() async throws {
        guard let folder = TestFiles.realBundles,
              let bundle = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL }).filter({ $0.pathExtension == "probundle" }).sorted(by: { $0.path < $1.path }).last
        else { return }
        let model = AppModel()
        var options = ConversionOptions()
        options.carryBackgroundForward = true
        model.options = options
        model.add([bundle])
        let item = try #require(model.selected)
        for _ in 0..<200 where item.thumbnails.count < (item.deck?.slides.count ?? 1) || item.deck == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        let deck = try #require(item.deck)
        let cells = Grid(horizontalSpacing: 18, verticalSpacing: 22) {
            ForEach(0..<((min(deck.slides.count, 12) + 3) / 4), id: \.self) { row in
                GridRow {
                    ForEach(row * 4..<min(row * 4 + 4, min(deck.slides.count, 12)), id: \.self) { k in
                        SlideCell(number: k + 1, slide: deck.slides[k], image: item.thumbnails[k], aspect: deck.size.width / deck.size.height, isSelected: k == 1)
                            .frame(width: 250)
                    }
                }
            }
        }
        .padding(20)
        .background(Color(nsColor: .underPageBackgroundColor))
        save(cells, "slide-cells", width: 1140)
        save(PresentationRow(item: item).padding(8), "row", width: 260)
    }
}
