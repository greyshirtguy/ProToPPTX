// ZipWriter: a zip archive written one entry at a time, straight to a file.
//
// What it is for: a .pptx is a zip of XML parts and media. The XML is deflated; media
// that is already compressed (pictures, video, sound) is stored as it is, which is what
// PowerPoint itself does and saves time for nothing lost.
//
// Each entry is written whole, its sizes and checksum in its local header (no data
// descriptors after), then the central directory and the end record at `finish()`. No
// ZIP64: an entry or an archive of 4 GB or more is refused with a plain error rather
// than written wrong. A slide show that large is not something PowerPoint opens well
// either.
//
// Entries' dates are left at nought (1980-01-01): the same deck written twice is then
// the same bytes, which is worth more here than a date nobody reads.

import Compression
import Foundation

public final class ZipWriter {
    public enum Packing: Sendable {
        case store
        case deflate
    }

    private struct Written {
        let path: Data
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let offset: UInt32
    }

    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var written: [Written] = []
    private var finished = false

    /// Creates (or empties) the file at `url` and writes the archive into it.
    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
    }

    deinit { try? handle.close() }

    /// Adds one file. `path` uses "/" between its parts and does not start with one.
    public func add(path: String, data: Data, packing: Packing) throws {
        precondition(!finished, "an entry added after finish()")
        let crc = CRC32.checksum(data)
        var method: UInt16 = 0
        var body = data
        if packing == .deflate, !data.isEmpty, let packed = Deflate.raw(data), packed.count < data.count {
            method = 8
            body = packed
        }
        guard data.count < 0xFFFF_FFFF, body.count < 0xFFFF_FFFF, offset < 0xFFFF_FFFF else {
            throw ZipError.tooLarge(path: path)
        }
        let name = Data(path.utf8)
        var header = Data()
        header.le32(0x0403_4b50)
        header.le16(20)            // version needed: 2.0
        header.le16(0x0800)        // flags: the name is UTF-8
        header.le16(method)
        header.le16(0)             // time
        header.le16(0x0021)        // date: 1980-01-01
        header.le32(crc)
        header.le32(UInt32(body.count))
        header.le32(UInt32(data.count))
        header.le16(UInt16(name.count))
        header.le16(0)             // no extra field
        header.append(name)
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: body)
        written.append(Written(
            path: name, method: method, crc: crc,
            compressedSize: UInt32(body.count), uncompressedSize: UInt32(data.count),
            offset: UInt32(offset)
        ))
        offset += UInt64(header.count + body.count)
    }

    /// Writes the central directory and the end record, and closes the file.
    public func finish() throws {
        precondition(!finished, "finish() called twice")
        finished = true
        let directoryStart = offset
        var directory = Data()
        for entry in written {
            directory.le32(0x0201_4b50)
            directory.le16(0x0314)     // made by: Unix, 2.0 (so the permissions below count)
            directory.le16(20)
            directory.le16(0x0800)
            directory.le16(entry.method)
            directory.le16(0)
            directory.le16(0x0021)
            directory.le32(entry.crc)
            directory.le32(entry.compressedSize)
            directory.le32(entry.uncompressedSize)
            directory.le16(UInt16(entry.path.count))
            directory.le16(0)          // extra
            directory.le16(0)          // comment
            directory.le16(0)          // disk
            directory.le16(0)          // internal attributes
            directory.le32(0o100644 << 16) // a plain file, readable by all
            directory.le32(entry.offset)
            directory.append(entry.path)
        }
        guard written.count < 0xFFFF, directoryStart + UInt64(directory.count) < 0xFFFF_FFFF else {
            throw ZipError.tooLarge(path: "the archive")
        }
        var end = Data()
        end.le32(0x0605_4b50)
        end.le16(0)
        end.le16(0)
        end.le16(UInt16(written.count))
        end.le16(UInt16(written.count))
        end.le32(UInt32(directory.count))
        end.le32(UInt32(directoryStart))
        end.le16(0)
        try handle.write(contentsOf: directory)
        try handle.write(contentsOf: end)
        try handle.close()
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
}

/// Raw DEFLATE with Apple's Compression; nil if it could not be done (the caller then
/// stores the bytes instead).
enum Deflate {
    static func raw(_ data: Data) -> Data? {
        // Deflate can come out a little larger than what went in; anything larger than
        // this is stored instead, by the caller.
        let capacity = data.count + data.count / 100 + 1024
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard n > 0 else { return nil }
        return out.prefix(n)
    }
}

/// The CRC-32 zip uses (IEEE 802.3, reflected, 0xEDB88320), eight bytes at a time
/// ("slicing by eight": eight tables of 256, one after another in one array).
public enum CRC32 {
    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 8 * 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            t[i] = c
        }
        for k in 1..<8 {
            for i in 0..<256 {
                let previous = t[(k - 1) * 256 + i]
                t[k * 256 + i] = (previous >> 8) ^ t[Int(previous & 0xFF)]
            }
        }
        return t
    }()

    public static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { t in
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let b = raw.bindMemory(to: UInt8.self)
                let n = b.count
                var i = 0
                while i + 8 <= n {
                    var lo = UInt32(b[i])
                    lo |= UInt32(b[i + 1]) << 8
                    lo |= UInt32(b[i + 2]) << 16
                    lo |= UInt32(b[i + 3]) << 24
                    lo ^= c
                    var hi = UInt32(b[i + 4])
                    hi |= UInt32(b[i + 5]) << 8
                    hi |= UInt32(b[i + 6]) << 16
                    hi |= UInt32(b[i + 7]) << 24
                    var x = t[7 * 256 + Int(lo & 0xFF)]
                    x ^= t[6 * 256 + Int((lo >> 8) & 0xFF)]
                    x ^= t[5 * 256 + Int((lo >> 16) & 0xFF)]
                    x ^= t[4 * 256 + Int(lo >> 24)]
                    x ^= t[3 * 256 + Int(hi & 0xFF)]
                    x ^= t[2 * 256 + Int((hi >> 8) & 0xFF)]
                    x ^= t[1 * 256 + Int((hi >> 16) & 0xFF)]
                    x ^= t[Int(hi >> 24)]
                    c = x
                    i += 8
                }
                while i < n {
                    c = t[Int((c ^ UInt32(b[i])) & 0xFF)] ^ (c >> 8)
                    i += 1
                }
            }
        }
        return c ^ 0xFFFF_FFFF
    }
}
