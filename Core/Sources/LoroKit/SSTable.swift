// The sorted key-value table a Loro snapshot keeps its state in ("SSTable", from
// Loro's kv-store crate), read whole into a dictionary.
//
// Layout (docs/encoding.md, section 4): "LORO", a schema byte, the blocks, then the
// blocks' metadata, then where that metadata starts. A block is either many small
// entries, each key told as what it shares with the block's first key and what it
// adds, or one large value alone. Each block may be one LZ4 frame, and ends with an
// xxHash32 of what is stored. Nothing is assumed of the order or the size of blocks
// beyond what the metadata says.

import Foundation

enum SSTable {
    /// Every entry of the table. Empty bytes are an empty table.
    static func read(_ bytes: [UInt8]) throws -> [[UInt8]: [UInt8]] {
        guard !bytes.isEmpty else { return [:] }
        var head = ByteReader(bytes, context: "the state table")
        guard try head.take(4).elementsEqual(Array("LORO".utf8)) else { throw LoroError.malformed("a state table without its magic word") }
        guard try head.u8() == 0 else { throw LoroError.malformed("a state table of an unknown schema") }
        guard bytes.count >= 9 else { throw LoroError.truncated("the state table") }

        var tail = ByteReader(bytes, from: bytes.count - 4, context: "the state table")
        let metaStart = Int(try tail.u32le())
        guard metaStart >= 5, metaStart <= bytes.count - 4 else { throw LoroError.malformed("a state table's metadata out of place") }

        struct BlockMeta {
            var offset: Int
            var firstKey: [UInt8]
            var isLarge: Bool
            var compression: UInt8
        }
        var meta = ByteReader(bytes, from: metaStart, to: bytes.count - 4, context: "the state table's metadata")
        let count = Int(try meta.u32le())
        guard count > 0, count <= 10_000_000 else { throw LoroError.malformed("a state table of \(count) blocks") }
        let entriesStart = meta.offset
        var blocks: [BlockMeta] = []
        blocks.reserveCapacity(count)
        for _ in 0 ..< count {
            let offset = Int(try meta.u32le())
            let firstKey = Array(try meta.take(Int(try meta.u16le())))
            let flags = try meta.u8()
            let isLarge = flags & 0x80 != 0
            if !isLarge { try meta.skip(Int(try meta.u16le())) } // the last key
            blocks.append(BlockMeta(offset: offset, firstKey: firstKey, isLarge: isLarge, compression: flags & 0x7f))
        }
        let checksumAt = meta.offset
        let checksum = try meta.u32le()
        guard XXHash32.hash(bytes[entriesStart ..< checksumAt], seed: XXHash32.loroSeed) == checksum else {
            throw LoroError.checksumMismatch
        }

        var table: [[UInt8]: [UInt8]] = [:]
        for (k, block) in blocks.enumerated() {
            let end = k + 1 < blocks.count ? blocks[k + 1].offset : metaStart
            guard block.offset >= 5, end - block.offset >= 4, end <= metaStart else {
                throw LoroError.malformed("a state table block out of place")
            }
            let stored = bytes[block.offset ..< end - 4]
            var sum = ByteReader(bytes, from: end - 4, to: end, context: "a block's checksum")
            guard XXHash32.hash(stored, seed: XXHash32.loroSeed) == (try sum.u32le()) else { throw LoroError.checksumMismatch }
            let body: [UInt8]
            switch block.compression {
            case 0: body = Array(stored)
            case 1: body = try LZ4Frame.decode(stored)
            default: throw LoroError.malformed("a block compressed in an unknown way")
            }
            if block.isLarge {
                table[block.firstKey] = body
            } else {
                try readNormalBlock(body, firstKey: block.firstKey, into: &table)
            }
        }
        return table
    }

    /// The entries of a block of small ones: their bytes, then where each starts (two
    /// bytes each), then how many there are (two bytes).
    private static func readNormalBlock(_ body: [UInt8], firstKey: [UInt8], into table: inout [[UInt8]: [UInt8]]) throws {
        guard body.count >= 2 else { throw LoroError.truncated("a state table block") }
        var r = ByteReader(body, from: body.count - 2, context: "a state table block")
        let count = Int(try r.u16le())
        let dataEnd = body.count - 2 - 2 * count
        guard count > 0, dataEnd >= 0 else { throw LoroError.malformed("a state table block's count") }
        var offsets = ByteReader(body, from: dataEnd, to: body.count - 2, context: "a state table block")
        var starts: [Int] = []
        for _ in 0 ..< count { starts.append(Int(try offsets.u16le())) }
        for k in 0 ..< count {
            let start = starts[k], end = k + 1 < count ? starts[k + 1] : dataEnd
            guard start <= end, end <= dataEnd else { throw LoroError.malformed("a state table entry out of place") }
            if k == 0 {
                table[firstKey] = Array(body[start ..< end])
                continue
            }
            var entry = ByteReader(body, from: start, to: end, context: "a state table entry")
            let shared = Int(try entry.u8())
            let suffix = try entry.take(Int(try entry.u16le()))
            guard shared <= firstKey.count else { throw LoroError.malformed("a state table key") }
            table[Array(firstKey[0 ..< shared]) + suffix] = Array(body[entry.offset ..< end])
        }
    }
}
