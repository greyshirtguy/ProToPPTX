// LoroKit against Loro itself: made-up documents (testdata/loro, made by
// make-fixtures.mjs there with Loro's own JavaScript package), each with the JSON Loro
// reads out of it, which this reader must read out of it too.
//
// And, when asked for, any folder of snapshots against JSON Loro wrote for them
// (PROTOPPTX_LORO_ORACLE=<folder>: each <name>.loro beside its <name>.oracle.json). That
// is how this reader was checked against every document of the maintainer's own
// database workspace (106 of them, 2026-10-23, all the same), which cannot be in the
// repository.

import Foundation
import Testing
import TestSupport
@testable import LoroKit

struct LoroDocumentTests {
    static let fixtures = TestFiles.testdata.appendingPathComponent("loro")

    @Test(arguments: ["containers", "presentation", "playlists", "libraries"])
    func readsAsLoroDoes(_ name: String) throws {
        let doc = try LoroDocument(snapshot: Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".loro")))
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".json")))
        let mine = LoroValue.map(try doc.value()).jsonObject
        #expect(Self.alike(mine, expected), "\(name) is not read as Loro reads it")
    }

    @Test func everyKindOfContainer() throws {
        let doc = try LoroDocument(snapshot: Data(contentsOf: Self.fixtures.appendingPathComponent("containers.loro")))
        #expect(doc.rootNames == ["root"]) // and not the mergeable children's made-up roots
        let root = try doc.value(of: "root")
        #expect(root["text"] == .string("Made up, by the second"))
        #expect(root["gone"] == nil)
        #expect(root["counter"] == .double(3.5))
        #expect(root["text container"] == .string("Hello world"))
        #expect(root["list"]?.list?.count == 5)
        #expect(root["mergeable map"]?["kept"] == .string("in a mergeable map"))
        #expect(root["mergeable tree"]?.list?.first?["meta"]?["name"] == .string("in a mergeable tree"))
        #expect(root["large"]?.string?.count == 12000)
        #expect(root["many"]?.map?.count == 300)
        // The tree: the deleted child gone, the moved one first, one moved to another top.
        let tops = try #require(root["tree"]?.list)
        let names = tops.map { $0["meta"]?["name"]?.string ?? "-" }
        #expect(names.contains("top") && names.contains("second top"))
        let top = try #require(tops.first { $0["meta"]?["name"] == .string("top") })
        #expect(top["children"]?.list?.map { $0["meta"]?["name"]?.string ?? "" } == ["child 3", "child 0"])
    }

    @Test func checksumIsHeldTo() throws {
        var bytes = [UInt8](try Data(contentsOf: Self.fixtures.appendingPathComponent("libraries.loro")))
        bytes[bytes.count / 2] ^= 0x40
        #expect(throws: LoroError.checksumMismatch) { try LoroDocument(snapshot: Data(bytes)) }
        #expect(throws: LoroError.notLoro) { try LoroDocument(snapshot: Data("not a Loro document at all".utf8)) }
    }

    @Test func xxHash32() {
        // The algorithm's own published values.
        #expect(XXHash32.hash([UInt8](), seed: 0) == 0x02CC_5D05)
        #expect(XXHash32.hash(Array("a".utf8), seed: 0) == 0x550D_7456)
        #expect(XXHash32.hash(Array("abc".utf8), seed: 0) == 0x32D1_53FF)
        #expect(XXHash32.hash(Array("Nobody inspects the spammish repetition".utf8), seed: 0) == 0xE229_3B2F)
    }

    @Test func lz4Block() throws {
        // "abcabcabcabc" as LZ4, written by hand: a token of three literals and a
        // match of 5 + 4, the literals "abc", then the match's offset, three back. And
        // a match reaching back before the start, which must be refused.
        var out: [UInt8] = []
        try LZ4Frame.decodeBlock([0x35, 0x61, 0x62, 0x63, 0x03, 0x00][...], into: &out, limit: 100)
        #expect(String(decoding: out, as: UTF8.self) == "abcabcabcabc")
        var bad: [UInt8] = []
        #expect(throws: LoroError.self) { try LZ4Frame.decodeBlock([0x15, 0x61, 0x09, 0x00][...], into: &bad, limit: 100) }
    }

    @Test func againstLoroItself() throws {
        guard let folder = ProcessInfo.processInfo.environment["PROTOPPTX_LORO_ORACLE"] else { return }
        var same = 0, differ: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder).sorted() where name.hasSuffix(".loro") {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            let doc = try LoroDocument(snapshot: Data(contentsOf: url))
            let theirs = try JSONSerialization.jsonObject(with: Data(contentsOf: url.deletingPathExtension().appendingPathExtension("oracle.json")))
            if Self.alike(LoroValue.map(try doc.value()).jsonObject, theirs) { same += 1 } else { differ.append(name) }
        }
        print("\(same) the same as Loro reads them, \(differ.count) not")
        #expect(differ.isEmpty)
    }

    /// The same value, as JSON: numbers alike to a part in 10^12 (Foundation reads a
    /// long decimal as NSDecimalNumber, which is not exactly the Double written).
    static func alike(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (is NSNull, is NSNull): return true
        case (let x as String, let y as String): return x == y
        case (let x as [Any], let y as [Any]): return x.count == y.count && zip(x, y).allSatisfy { alike($0, $1) }
        case (let x as [String: Any], let y as [String: Any]):
            return Set(x.keys) == Set(y.keys) && x.allSatisfy { alike($0.value, y[$0.key]!) }
        case (let x as Bool, let y as NSNumber): return CFGetTypeID(y) == CFBooleanGetTypeID() && x == y.boolValue
        case (let x as Int64, let y as NSNumber): return CFGetTypeID(y) != CFBooleanGetTypeID() && close(Double(x), y.doubleValue)
        case (let x as Double, let y as NSNumber): return CFGetTypeID(y) != CFBooleanGetTypeID() && close(x, y.doubleValue)
        default: return false
        }
    }

    static func close(_ x: Double, _ y: Double) -> Bool {
        x == y || abs(x - y) <= 1e-12 * max(abs(x), abs(y))
    }
}
