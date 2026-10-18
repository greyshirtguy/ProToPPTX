// Units: Deck's slide units turned into PowerPoint's.
//
// PowerPoint measures in EMUs (914400 to the inch, 12700 to the point) and font sizes in
// hundredths of a point. The PowerPoint slide is made 7.5 inches tall, the height of
// PowerPoint's own standard slides, and as wide as the presentation's shape asks: a
// 1920 × 1080 presentation becomes PowerPoint's standard widescreen slide, 13.333 ×
// 7.5 inches, and a 4:3 one its standard 10 × 7.5. Everything is scaled by the same
// factor, so a ProPresenter font size of 72 on a 1080p slide becomes 36 points, which
// is the same size on the slide.

import DeckModel
import Foundation

struct Units {
    /// EMUs per slide unit.
    let emuPerUnit: Double

    static let slideHeightEMU = 6_858_000.0

    init(deckSize: Size) {
        emuPerUnit = Self.slideHeightEMU / max(deckSize.height, 1)
    }

    func emu(_ units: Double) -> Int { Int((units * emuPerUnit).rounded()) }

    /// Points, for a length in slide units.
    func points(_ units: Double) -> Double { units * emuPerUnit / 12_700 }

    /// Hundredths of a point (font sizes, character spacing, spacing in points).
    func centipoints(_ units: Double) -> Int { Int((points(units) * 100).rounded()) }

    /// A font size as PowerPoint takes it: hundredths of a point, 1 to 4000 points.
    func fontSize(_ units: Double) -> Int { min(max(centipoints(units), 100), 400_000) }

    /// Degrees in PowerPoint's 60000ths.
    static func angle(_ degrees: Double) -> Int {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return Int((d * 60_000).rounded())
    }

    /// A fraction as PowerPoint's thousandths of a percent (1 is 100000).
    static func percent(_ fraction: Double) -> Int { Int((fraction * 100_000).rounded()) }
}
