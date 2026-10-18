// Reaches into a presentation for the RTF of one slide's text boxes, for AppKitOracle.

import Foundation
@testable import ProImport
import ProFormat

enum OracleSupport {
    struct BoxRTF { let data: Data; let width: Double }

    static func rtfs(bundle: URL, slide: Int) throws -> [BoxRTF] {
        let source = try ProSource(url: bundle)
        let played = PlayOrder.cues(of: source.presentation, followArrangement: true).cues.filter(\.cue.isEnabled)
        guard let base = ProImporter.presentationSlide(of: played[slide - 1].cue) else { return [] }
        return base.baseSlide.elements.reversed().compactMap { e in
            let g = e.element
            guard g.hasText, !g.text.rtfData.isEmpty else { return nil }
            return BoxRTF(data: g.text.rtfData, width: g.bounds.size.width - g.text.margins.left - g.text.margins.right - 10)
        }
    }
}
