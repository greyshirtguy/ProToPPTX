// The small codecs a Loro snapshot is built of: a cursor over bytes that reads the
// several kinds of integer the format mixes, xxHash32 (its checksums) and LZ4 frames
// (its compressed blocks).
//
// Written from Loro's own description of its format (docs/encoding.md and
// docs/encoding-lz4.md in github.com/loro-dev/loro, verified there against loro
// 1.17, 2026-07), not from its code. The format mixes integer encodings field by
// field; each reader here is named for the one it reads, and the callers say which
// field uses which.

import Foundation

/// What is wrong with bytes that were to be a Loro snapshot.
public enum LoroError: Error, CustomStringConvertible, Equatable {
    case notLoro
    case unsupportedMode(UInt16)
    case checksumMismatch
    case truncated(String)
    case malformed(String)
    /// The snapshot keeps no state, only history, which this reader does not replay.
    case historyOnly

    public var description: String {
        switch self {
        case .notLoro: return "The data is not a Loro document."
        case .unsupportedMode(let m): return "The Loro document is in a form this app cannot read (mode \(m))."
        case .checksumMismatch: return "The Loro document is damaged (its checksum does not match)."
        case .truncated(let what): return "The Loro document ends too soon (in \(what))."
        case .malformed(let what): return "The Loro document is malformed (\(what))."
        case .historyOnly: return "The Loro document keeps only its history, which this app cannot read."
        }
    }
}

/// A cursor over bytes. Each read moves it on, or throws if the bytes run out.
struct ByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int
    let end: Int
    let context: String

    init(_ bytes: [UInt8], from start: Int = 0, to end: Int? = nil, context: String) {
        self.bytes = bytes
        self.offset = start
        self.end = end ?? bytes.count
        self.context = context
    }

    var isAtEnd: Bool { offset >= end }
    var remaining: Int { end - offset }

    mutating func u8() throws -> UInt8 {
        guard offset < end else { throw LoroError.truncated(context) }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else { throw LoroError.truncated(context) }
        defer { offset += count }
        return bytes[offset ..< offset + count]
    }

    mutating func skip(_ count: Int) throws { _ = try take(count) }

    mutating func u16le() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }

    mutating func u32le() throws -> UInt32 {
        let b = try take(4)
        var v: UInt32 = 0
        for (k, byte) in b.enumerated() { v |= UInt32(byte) << (8 * k) }
        return v
    }

    mutating func u64le() throws -> UInt64 {
        let b = try take(8)
        var v: UInt64 = 0
        for (k, byte) in b.enumerated() { v |= UInt64(byte) << (8 * k) }
        return v
    }

    mutating func f64le() throws -> Double { Double(bitPattern: try u64le()) }

    /// Unsigned LEB128, which is also postcard's unsigned integer. Up to 128 bits are
    /// read (serde_columnar's deltas are i128); what does not fit 64 is an error.
    mutating func uleb() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try u8()
            let part = UInt64(byte & 0x7f)
            if shift < 64 {
                if shift > 57, part >> (64 - shift) != 0 { throw LoroError.malformed("a number too large, in \(context)") }
                result |= part << shift
            } else if part != 0 {
                throw LoroError.malformed("a number too large, in \(context)")
            }
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 133 { throw LoroError.malformed("an endless number, in \(context)") }
        }
    }

    /// Postcard's signed integer: zigzag, then unsigned LEB128.
    mutating func zigzag() throws -> Int64 {
        let u = try uleb()
        return Int64(bitPattern: (u >> 1) ^ (0 &- (u & 1)))
    }

    /// A count or an index: an unsigned LEB128 that must be a reasonable Int.
    mutating func count(limit: Int = 1 << 28) throws -> Int {
        let v = try uleb()
        guard v <= UInt64(limit) else { throw LoroError.malformed("a count of \(v), in \(context)") }
        return Int(v)
    }

    /// Bytes preceded by their length.
    mutating func lengthPrefixed() throws -> ArraySlice<UInt8> {
        try take(count(limit: remaining))
    }

    mutating func utf8() throws -> String {
        let b = try lengthPrefixed()
        guard let s = String(validating: b, as: UTF8.self) else { throw LoroError.malformed("text that is not UTF-8, in \(context)") }
        return s
    }
}

// MARK: - xxHash32

/// xxHash32, as Loro uses it for its checksums (with its own seed, "LORO" read as a
/// little-endian number) and as LZ4 uses it for a frame's header (with nought).
enum XXHash32 {
    static let loroSeed: UInt32 = 0x4f52_4f4c

    private static let p1: UInt32 = 2_654_435_761
    private static let p2: UInt32 = 2_246_822_519
    private static let p3: UInt32 = 3_266_489_917
    private static let p4: UInt32 = 668_265_263
    private static let p5: UInt32 = 374_761_393

    static func hash<C: RandomAccessCollection>(_ input: C, seed: UInt32) -> UInt32 where C.Element == UInt8, C.Index == Int {
        func word(_ i: Int) -> UInt32 {
            UInt32(input[i]) | UInt32(input[i + 1]) << 8 | UInt32(input[i + 2]) << 16 | UInt32(input[i + 3]) << 24
        }
        func round(_ acc: UInt32, _ lane: UInt32) -> UInt32 {
            var a = acc &+ lane &* p2
            a = (a << 13) | (a >> 19)
            return a &* p1
        }
        var i = input.startIndex
        let end = input.endIndex
        let length = UInt32(truncatingIfNeeded: input.count)
        var h: UInt32
        if input.count >= 16 {
            var v1 = seed &+ p1 &+ p2, v2 = seed &+ p2, v3 = seed, v4 = seed &- p1
            while i + 16 <= end {
                v1 = round(v1, word(i)); v2 = round(v2, word(i + 4))
                v3 = round(v3, word(i + 8)); v4 = round(v4, word(i + 12))
                i += 16
            }
            h = ((v1 << 1) | (v1 >> 31)) &+ ((v2 << 7) | (v2 >> 25))
            h = h &+ ((v3 << 12) | (v3 >> 20)) &+ ((v4 << 18) | (v4 >> 14))
        } else {
            h = seed &+ p5
        }
        h = h &+ length
        while i + 4 <= end {
            h = h &+ word(i) &* p3
            h = ((h << 17) | (h >> 15)) &* p4
            i += 4
        }
        while i < end {
            h = h &+ UInt32(input[i]) &* p5
            h = ((h << 11) | (h >> 21)) &* p1
            i += 1
        }
        h ^= h >> 15
        h = h &* p2
        h ^= h >> 13
        h = h &* p3
        h ^= h >> 16
        return h
    }
}

// MARK: - LZ4

/// LZ4's frame format, as far as reading goes. Loro writes one frame for each
/// compressed block, with none of the frame's options set (docs/encoding-lz4.md); the
/// options a standard frame may have are read all the same, and skipped.
enum LZ4Frame {
    static func decode(_ input: ArraySlice<UInt8>) throws -> [UInt8] {
        var r = ByteReader(Array(input), context: "an LZ4 frame")
        guard try r.u32le() == 0x184D_2204 else { throw LoroError.malformed("an LZ4 frame without its magic number") }
        let flg = try r.u8()
        let bd = try r.u8()
        guard flg >> 6 == 1 else { throw LoroError.malformed("an LZ4 frame of an unknown version") }
        let blockChecksums = flg & 0x10 != 0
        let contentSize = flg & 0x08 != 0
        let contentChecksum = flg & 0x04 != 0
        let dictionary = flg & 0x01 != 0
        let maxBlock: Int
        switch (bd >> 4) & 0x7 {
        case 4: maxBlock = 64 << 10
        case 5: maxBlock = 256 << 10
        case 6: maxBlock = 1 << 20
        case 7: maxBlock = 4 << 20
        default: throw LoroError.malformed("an LZ4 frame with an unknown block size")
        }
        if contentSize { try r.skip(8) }
        if dictionary { throw LoroError.malformed("an LZ4 frame that needs a dictionary") }
        try r.skip(1) // the header's checksum
        var output: [UInt8] = []
        while true {
            let info = try r.u32le()
            if info == 0 { break }
            let length = Int(info & 0x7fff_ffff)
            guard length <= maxBlock else { throw LoroError.malformed("an LZ4 block larger than its frame allows") }
            let data = try r.take(length)
            if info & 0x8000_0000 != 0 {
                output.append(contentsOf: data)
            } else {
                try decodeBlock(data, into: &output, limit: output.count + maxBlock)
            }
            if blockChecksums { try r.skip(4) }
        }
        if contentChecksum { try r.skip(4) }
        return output
    }

    /// One LZ4 block, appended to `output`. A match may reach back into what earlier
    /// blocks of the frame wrote, which is what a frame of linked blocks needs.
    static func decodeBlock(_ input: ArraySlice<UInt8>, into output: inout [UInt8], limit: Int) throws {
        var i = input.startIndex
        let end = input.endIndex
        func byte() throws -> UInt8 {
            guard i < end else { throw LoroError.truncated("an LZ4 block") }
            defer { i += 1 }
            return input[i]
        }
        func length(_ start: Int) throws -> Int {
            var n = start
            if start == 15 {
                while true {
                    let more = try byte()
                    n += Int(more)
                    if more != 255 { break }
                }
            }
            return n
        }
        while i < end {
            let token = try byte()
            let literals = try length(Int(token >> 4))
            guard literals <= end - i, output.count + literals <= limit else { throw LoroError.truncated("an LZ4 block's literals") }
            output.append(contentsOf: input[i ..< i + literals])
            i += literals
            if i == end { break }
            let offset = Int(try byte()) | Int(try byte()) << 8
            let count = try length(Int(token & 0x0f)) + 4
            guard offset > 0, offset <= output.count else { throw LoroError.malformed("an LZ4 match that reaches before the start") }
            guard output.count + count <= limit else { throw LoroError.malformed("an LZ4 block larger than its frame allows") }
            let from = output.count - offset
            output.reserveCapacity(output.count + count)
            for k in 0 ..< count { output.append(output[from + k]) }
        }
    }
}
