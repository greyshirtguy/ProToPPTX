// OOXMLLint: the values in a PowerPoint part that the standard bounds, checked.
//
// Why: a value out of its range (a left margin less than nought, say) makes a part that
// is well-formed XML but not valid PresentationML, and PowerPoint then offers to
// "repair" the whole deck. That happened once (2026-10-19: RTF's \li-100 written as a
// negative marL). The ranges are those of the ECMA-376 schema's types (ST_TextMargin,
// ST_TextIndent, ST_TextFontSize and so on); only the attributes this app writes are
// checked, by name, wherever they are.

import Foundation

public enum OOXMLLint {
    /// (attribute, element it must be on or nil for any, lowest, highest)
    static let rules: [(String, String?, Int, Int)] = [
        ("marL", "a:pPr", 0, 51_206_400),
        ("marR", "a:pPr", 0, 51_206_400),
        ("indent", "a:pPr", -51_206_400, 51_206_400),
        ("defTabSz", "a:pPr", 0, 51_206_400),
        ("startAt", "a:buAutoNum", 1, 32_767),
        ("sz", "a:rPr", 100, 400_000),
        ("sz", "a:endParaRPr", 100, 400_000),
        ("spc", "a:rPr", -400_000, 400_000),
        ("blurRad", "a:outerShdw", 0, Int.max),
        ("dist", "a:outerShdw", 0, Int.max),
        ("dir", "a:outerShdw", 0, 21_599_999),
        ("rad", "a:softEdge", 0, Int.max),
        ("w", "a:ln", 0, 20_116_800),
        ("val", "a:alpha", 0, 100_000),
        ("amt", "a:alphaModFix", 0, 100_000),
        ("val", "a:spcPct", 0, 13_200_000),
        ("val", "a:spcPts", 0, 158_400),
        ("pos", "a:gs", 0, 100_000),
        ("ang", "a:lin", 0, 21_599_999),
        ("fontScale", "a:normAutofit", 1_000, 100_000),
        ("cx", "a:ext", 0, 27_273_042_316_900),
        ("cy", "a:ext", 0, 27_273_042_316_900),
    ]

    /// What is out of range in one part, as "element attribute=value".
    public static func problems(in xml: String) -> [String] {
        var found: [String] = []
        let elementPattern = try! NSRegularExpression(pattern: #"<([a-z0-9]+:[A-Za-z0-9]+)((?:\s+[A-Za-z0-9:]+="[^"]*")*)\s*/?>"#)
        let attributePattern = try! NSRegularExpression(pattern: #"([A-Za-z0-9:]+)="([^"]*)""#)
        let ns = xml as NSString
        for element in elementPattern.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: element.range(at: 1))
            let attributes = ns.substring(with: element.range(at: 2)) as NSString
            for attribute in attributePattern.matches(in: attributes as String, range: NSRange(location: 0, length: attributes.length)) {
                let key = attributes.substring(with: attribute.range(at: 1))
                let value = attributes.substring(with: attribute.range(at: 2))
                for (ruleKey, ruleElement, low, high) in rules where ruleKey == key && (ruleElement == nil || ruleElement == name) {
                    guard let number = Int(value) else { found.append("\(name) \(key)=\(value) (not a whole number)"); continue }
                    if number < low || number > high { found.append("\(name) \(key)=\(value)") }
                }
            }
        }
        return found
    }
}
