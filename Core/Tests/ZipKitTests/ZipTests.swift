// ZipKit: what is written can be read back, and what ProPresenter writes can be read.

import Foundation
import Testing
import TestSupport
@testable import ZipKit

@Suite struct ZipTests {
    @Test func writtenArchivesReadBack() throws {
        let folder = try TestFiles.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("a.zip")
        let text = Data(String(repeating: "Amazing grace, how sweet the sound. ", count: 200).utf8)
        let bytes = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7919) })
        let zip = try ZipWriter(url: url)
        try zip.add(path: "words.xml", data: text, packing: .deflate)
        try zip.add(path: "media/bytes.bin", data: bytes, packing: .store)
        try zip.add(path: "empty.txt", data: Data(), packing: .deflate)
        try zip.finish()

        let reader = try ZipReader(url: url)
        #expect(reader.entries.map(\.path) == ["words.xml", "media/bytes.bin", "empty.txt"])
        #expect(reader.entry("words.xml")!.method == 8)
        #expect(reader.entry("media/bytes.bin")!.method == 0)
        #expect(try reader.contents(of: reader.entry("words.xml")!) == text)
        #expect(try reader.contents(of: reader.entry("media/bytes.bin")!) == bytes)
        #expect(try reader.contents(of: reader.entry("empty.txt")!) == Data())
    }

    @Test func crcMatchesTheKnownValue() {
        // The check value of CRC-32 for "123456789".
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    /// ProPresenter's bundles end with a ZIP64 end record that it also counts in the size
    /// of the central directory, and name entries by whole paths. Made here the same way.
    @Test func readsBundlesShapedAsProPresenterWritesThem() throws {
        let name = Data("/Users/someone/Media/Assets/Background.png".utf8)
        let body = Data("picture".utf8)
        let crc = CRC32.checksum(body)
        var d = Data()
        d.le32(0x0403_4b50); d.le16(20); d.le16(0); d.le16(0); d.le16(0); d.le16(0)
        d.le32(crc); d.le32(UInt32(body.count)); d.le32(UInt32(body.count))
        d.le16(UInt16(name.count)); d.le16(0); d.append(name); d.append(body)
        let directoryStart = d.count
        d.le32(0x0201_4b50); d.le16(20); d.le16(20); d.le16(0); d.le16(0); d.le16(0); d.le16(0)
        d.le32(crc); d.le32(UInt32(body.count)); d.le32(UInt32(body.count))
        d.le16(UInt16(name.count)); d.le16(0); d.le16(0); d.le16(0); d.le16(0); d.le32(0); d.le32(0)
        d.append(name)
        let directorySize = d.count - directoryStart
        let zip64Start = d.count
        d.le32(0x0606_4b50); d.le32(44); d.le32(0); d.le32(0); d.le16(45); d.le16(45); d.le32(0); d.le32(0)
        d.le32(1); d.le32(0); d.le32(1); d.le32(0)
        d.le32(UInt32(directorySize)); d.le32(0); d.le32(UInt32(directoryStart)); d.le32(0)
        d.le32(0x0706_4b50); d.le32(0); d.le32(UInt32(zip64Start)); d.le32(0); d.le32(1)
        d.le32(0x0605_4b50); d.le16(0); d.le16(0); d.le16(1); d.le16(1)
        d.le32(UInt32(directorySize + 98)) // what ProPresenter writes: 98 too many
        d.le32(UInt32(directoryStart)); d.le16(0)

        let reader = try ZipReader(data: d)
        #expect(reader.entries.count == 1)
        #expect(reader.entries[0].fileName == "Background.png")
        #expect(try reader.contents(of: reader.entries[0]) == body)
    }

    @Test func refusesWhatIsNotAZip() {
        #expect(throws: ZipError.notAZip) { try ZipReader(data: Data("not a zip at all, not even close".utf8)) }
    }
}
