// ZipReader: the entries of a zip archive, and the bytes of each.
//
// What it is for: a .probundle is a zip of one .pro and the media it plays, and this is
// how its pieces are got at. It reads what ProPresenter writes and what PowerPoint
// writes, and is not meant to be a reader of every zip there is: no encryption, no
// archives in several parts, and only the two ways of packing anything here uses
// (stored, and deflated).
//
// KNOWN, from the maintainer's bundles (ProPresenter 21.4, 2026): ProPresenter writes
// every entry stored (not compressed), with no permissions (unzip makes them files that
// nobody can read), names them by the whole path the file had on the Mac that made the
// bundle ("/Users/…/Media/Assets/Background.png"; only the .pro itself has a bare
// name), and ends the archive with a ZIP64 end record and its locator, 98 bytes it then
// counts in the size of the central directory as well. So the size the end record
// gives for the central directory is not to be trusted, and `unzip` complains of
// "98 bytes missing". The entries are therefore read by their count, one header after
// another from where the central directory starts, never by its size.
//
// The archive is read from memory: `Data(contentsOf:options: .alwaysMapped)` keeps a
// large bundle out of memory until its bytes are asked for.

import Compression
import Foundation

/// One file in a zip archive, as its central directory describes it.
public struct ZipEntry: Sendable, Hashable {
    /// The name as stored: a path with "/" between its parts, perhaps starting with "/".
    public let path: String
    /// 0 for stored, 8 for deflated.
    public let method: UInt16
    public let crc32: UInt32
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    /// Where the entry's local header starts.
    let localHeaderOffset: UInt64

    /// A name ending in "/" is a folder, not a file.
    public var isDirectory: Bool { path.hasSuffix("/") }
    /// The last part of the path.
    public var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }
}

public enum ZipError: Error, CustomStringConvertible, Equatable {
    case notAZip
    case damaged(String)
    case unsupportedMethod(UInt16, path: String)
    case checksumMismatch(path: String)
    case tooLarge(path: String)

    public var description: String {
        switch self {
        case .notAZip: return "The file is not a zip archive."
        case .damaged(let why): return "The zip archive is damaged: \(why)."
        case .unsupportedMethod(let m, let path): return "\(path) is packed in a way this app cannot read (method \(m))."
        case .checksumMismatch(let path): return "\(path) is damaged inside the archive (its checksum does not match)."
        case .tooLarge(let path): return "\(path) is too large to be written into a zip archive by this app."
        }
    }
}

public struct ZipReader: Sendable {
    public let entries: [ZipEntry]
    private let data: Data

    /// Opens an archive on disk; its bytes are mapped, not read, until they are needed.
    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        self.data = data
        self.entries = try Self.readCentralDirectory(data)
    }

    /// The entry with exactly this path, if there is one.
    public func entry(_ path: String) -> ZipEntry? { entries.first { $0.path == path } }

    /// The bytes of an entry, unpacked and checked against its checksum.
    public func contents(of entry: ZipEntry) throws -> Data {
        let base = Int(entry.localHeaderOffset)
        guard base + 30 <= data.count, data.u32(at: base) == 0x0403_4b50 else {
            throw ZipError.damaged("no local header for \(entry.path)")
        }
        let nameLength = Int(data.u16(at: base + 26))
        let extraLength = Int(data.u16(at: base + 28))
        let start = base + 30 + nameLength + extraLength
        let end = start + Int(entry.compressedSize)
        guard end <= data.count else { throw ZipError.damaged("\(entry.path) runs past the end of the archive") }
        let packed = data.subdata(in: start..<end)
        let unpacked: Data
        switch entry.method {
        case 0:
            unpacked = packed
        case 8:
            unpacked = try Inflate.raw(packed, expectedSize: Int(entry.uncompressedSize), path: entry.path)
        default:
            throw ZipError.unsupportedMethod(entry.method, path: entry.path)
        }
        guard CRC32.checksum(unpacked) == entry.crc32 else { throw ZipError.checksumMismatch(path: entry.path) }
        return unpacked
    }

    // MARK: - The central directory

    private static func readCentralDirectory(_ data: Data) throws -> [ZipEntry] {
        // The end record is the last thing in the file, followed by a comment of up to
        // 65535 bytes: look for its signature from the end back.
        guard data.count >= 22 else { throw ZipError.notAZip }
        var eocd = -1
        var i = data.count - 22
        let lowest = max(0, data.count - 22 - 65_535)
        while i >= lowest {
            if data.u32(at: i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        var count = UInt64(data.u16(at: eocd + 10))
        var directoryOffset = UInt64(data.u32(at: eocd + 16))

        // A ZIP64 locator sits just before the end record when there is one; its record
        // has the true count and offset if the plain ones are full (0xFFFF, 0xFFFFFFFF).
        if eocd >= 20, data.u32(at: eocd - 20) == 0x0706_4b50 {
            let z64 = Int(data.u64(at: eocd - 20 + 8))
            if z64 >= 0, z64 + 56 <= data.count, data.u32(at: z64) == 0x0606_4b50 {
                if count == 0xFFFF { count = data.u64(at: z64 + 32) }
                if directoryOffset == 0xFFFF_FFFF { directoryOffset = data.u64(at: z64 + 48) }
            }
        }

        var entries: [ZipEntry] = []
        var p = Int(directoryOffset)
        for _ in 0..<count {
            guard p + 46 <= data.count, data.u32(at: p) == 0x0201_4b50 else {
                throw ZipError.damaged("the list of files is cut short")
            }
            let method = data.u16(at: p + 10)
            let crc = data.u32(at: p + 16)
            var compressed = UInt64(data.u32(at: p + 20))
            var uncompressed = UInt64(data.u32(at: p + 24))
            let nameLength = Int(data.u16(at: p + 28))
            let extraLength = Int(data.u16(at: p + 30))
            let commentLength = Int(data.u16(at: p + 32))
            var localOffset = UInt64(data.u32(at: p + 42))
            guard p + 46 + nameLength + extraLength <= data.count else { throw ZipError.damaged("a file name runs past the end") }
            let nameBytes = data.subdata(in: (p + 46)..<(p + 46 + nameLength))
            // Bit 11 of the flags says the name is UTF-8. Without it the name is meant to
            // be in the old DOS code page, but everything that writes the archives this
            // app opens writes UTF-8 regardless, so it is read as UTF-8 either way.
            let name = String(decoding: nameBytes, as: UTF8.self)

            // ZIP64 extra field: the values that did not fit, in this order, for those
            // that are full.
            var e = p + 46 + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let tag = data.u16(at: e), size = Int(data.u16(at: e + 2))
                if tag == 0x0001 {
                    var q = e + 4
                    if uncompressed == 0xFFFF_FFFF, q + 8 <= e + 4 + size { uncompressed = data.u64(at: q); q += 8 }
                    if compressed == 0xFFFF_FFFF, q + 8 <= e + 4 + size { compressed = data.u64(at: q); q += 8 }
                    if localOffset == 0xFFFF_FFFF, q + 8 <= e + 4 + size { localOffset = data.u64(at: q); q += 8 }
                }
                e += 4 + size
            }

            entries.append(ZipEntry(
                path: name, method: method, crc32: crc,
                compressedSize: compressed, uncompressedSize: uncompressed,
                localHeaderOffset: localOffset
            ))
            p += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }
}

// MARK: - Reading little-endian numbers out of Data, wherever its indices start

extension Data {
    func u16(at i: Int) -> UInt16 {
        let s = startIndex + i
        return UInt16(self[s]) | UInt16(self[s + 1]) << 8
    }

    func u32(at i: Int) -> UInt32 {
        let s = startIndex + i
        return UInt32(self[s]) | UInt32(self[s + 1]) << 8 | UInt32(self[s + 2]) << 16 | UInt32(self[s + 3]) << 24
    }

    func u64(at i: Int) -> UInt64 {
        UInt64(u32(at: i)) | UInt64(u32(at: i + 4)) << 32
    }
}

/// Raw DEFLATE (RFC 1951) unpacked with Apple's Compression, whose ZLIB is exactly that:
/// no zlib header, no checksum after.
enum Inflate {
    static func raw(_ packed: Data, expectedSize: Int, path: String) throws -> Data {
        if expectedSize == 0 { return Data() }
        var out = Data(count: expectedSize)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            packed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, packed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw ZipError.damaged("\(path) does not unpack to its stated size") }
        return out
    }
}
