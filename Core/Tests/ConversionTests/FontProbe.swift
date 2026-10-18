// Prints what FontCatalog makes of a few fonts' names, for checking by eye.
//     PROTOPPTX_FONT_PROBE="HelveticaNeue-CondensedBlack,CMGSans-Light" swift test --filter FontProbe

import DeckPreview
import Foundation
import Testing

@Suite struct FontProbe {
    @Test func probe() {
        guard let names = ProcessInfo.processInfo.environment["PROTOPPTX_FONT_PROBE"] else { return }
        for name in names.split(separator: ",").map(String.init) {
            if let f = FontCatalog.face(postScriptName: name) {
                print("FONT \(name): family \(f.family) | full \(f.fullName) | legacy \(f.legacyFamily) / \(f.legacySubfamily)")
            } else {
                print("FONT \(name): not installed")
            }
        }
    }
}
