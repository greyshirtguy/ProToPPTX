// Mergeable containers: a container in a map whose id is made from the map and the key
// it is under, not from who made it, so that two people who each make "the playlists"
// at once make the one container, and their changes merge.
//
// From Loro's source (crates/loro-common/src/lib.rs and
// crates/loro-internal/docs/mergeable-container-id.md, loro 1.17, 2026-10): the map
// keeps, under the key, an eight-byte marker: 00 "L" "M" 01, the child's kind, and
// three bytes of a CRC-32 of where it is (so that a marker copied elsewhere activates
// nothing). The child itself is kept as a root whose name is "🤝:", then where its
// parent is ("$" and a root's name, "@" and a made container's peer and counter in base
// 36, or a mergeable parent's own path), then ">" and the key. KNOWN: ProPresenter's
// PlaylistLibrary document keeps its playlists so (root "🤝:$root>playlists", a tree).

import Foundation

enum Mergeable {
    static let prefix = "🤝:"
    private static let magic: [UInt8] = [0x00, 0x4c, 0x4d, 0x01]

    /// The container a map's entry is a marker for, if it is one.
    static func child(of parent: ContainerID, key: String, marker: [UInt8]) -> ContainerID? {
        guard marker.count == 8, marker.starts(with: magic) else { return nil }
        let kind = marker[4]
        guard ContainerID.Kind(rawValue: kind) != nil else { return nil }
        var input = Array("loro.mergeable.marker.v1".utf8)
        func segment(_ bytes: [UInt8]) {
            var n = UInt64(bytes.count)
            repeat {
                var b = UInt8(n & 0x7f)
                n >>= 7
                if n != 0 { b |= 0x80 }
                input.append(b)
            } while n != 0
            input.append(contentsOf: bytes)
        }
        segment(parent.key)
        segment(Array(key.utf8))
        input.append(kind)
        let crc = crc32(input) & 0x00ff_ffff
        guard marker[5] == UInt8(crc >> 16), marker[6] == UInt8((crc >> 8) & 0xff), marker[7] == UInt8(crc & 0xff) else { return nil }
        return ContainerID(rawKind: kind, rootName: prefix + path(of: parent) + ">" + escaped(key))
    }

    private static func path(of parent: ContainerID) -> String {
        if let name = parent.rootName {
            if name.hasPrefix(prefix) { return String(name.dropFirst(prefix.count)) }
            return "$" + escaped(name)
        }
        return "@" + base36(parent.peer) + ":" + (parent.counter < 0 ? "-" + base36(UInt64(-Int64(parent.counter))) : base36(UInt64(parent.counter)))
    }

    private static func escaped(_ segment: String) -> String {
        var out = ""
        for ch in segment {
            switch ch {
            case "\\": out += "\\\\"
            case ">": out += "\\>"
            case "/": out += "\\s"
            case "\0": out += "\\0"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func base36(_ value: UInt64) -> String { String(value, radix: 36) }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 { crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}
