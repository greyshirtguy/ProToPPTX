// LoroDocument: what a Loro document holds now, read from a snapshot of it, without
// its history and without Loro itself.
//
// Loro (loro.dev) keeps a document that several people can change at once as
// containers (maps, lists, trees, texts and counters) nested in one another under named
// roots. A snapshot of it (`doc.export({ mode: "snapshot" })`) carries both the history
// of changes and the state they come to. This reads only the state, which is all that
// is wanted to show what the document says: each container's value is stored whole,
// and a container in a container is stored as a reference to it.
//
// The format is Loro's own documented one (docs/encoding.md and
// docs/encoding-container-states.md in github.com/loro-dev/loro, verified there
// against loro 1.17, 2026-07): a 22-byte envelope ("loro", a checksum, the mode), then
// for a snapshot (mode 3) three sections: the history, the state, and the state of a
// "shallow" start, each a key-value table (SSTable.swift) or empty. The state table's
// keys are containers' ids, and its values the containers.
//
// What is read of each container is its visible value: a map's keys and values, a
// list's items, a text's text, a counter's number, and a tree's nodes (which need the
// tree's columns read, there being no value stored before them). What Loro keeps
// beside these to merge changes (who wrote each value, and when; what was deleted) is
// skipped. A snapshot whose state section is omitted (a shallow one that expects its
// history to be replayed) cannot be read this way, and says so.
//
// A map's entry can also be a "mergeable" container: one whose id is made from where
// it is (the map and the key), so that two people who make it at once make the same
// one. The map keeps a small marker for it, and the container is kept as a root with a
// made-up name (Mergeable.swift). ProPresenter's playlists are kept in such a tree.
//
// What `value()` gives is shaped as Loro's own `toJSON()` would give it, so that the
// two can be compared: a tree is a list of its root nodes, each a map with "id",
// "parent", "index", "fractional_index", "meta" and "children".

import Foundation

/// A value in a Loro document, with every container in it read.
public indirect enum LoroValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case double(Double)
    case int(Int64)
    case string(String)
    case binary([UInt8])
    case list([LoroValue])
    case map([String: LoroValue])

    public subscript(key: String) -> LoroValue? {
        if case .map(let m) = self { return m[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var map: [String: LoroValue]? { if case .map(let m) = self { return m } else { return nil } }
    public var list: [LoroValue]? { if case .list(let l) = self { return l } else { return nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var isNull: Bool { self == .null }
    /// A number, whether kept as an integer or not.
    public var number: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}

/// The id of a container: a root's name, or who made it and when.
struct ContainerID: Hashable {
    enum Kind: UInt8 {
        case map = 0, list = 1, text = 2, tree = 3, movableList = 4, counter = 5
    }

    var rawKind: UInt8
    var rootName: String?
    var peer: UInt64 = 0
    var counter: Int32 = 0

    /// The key it is stored under in the state table (`ContainerID::to_bytes`).
    var key: [UInt8] {
        if let rootName {
            let name = Array(rootName.utf8)
            var bytes: [UInt8] = [rawKind | 0x80]
            var n = UInt64(name.count)
            repeat {
                var b = UInt8(n & 0x7f)
                n >>= 7
                if n != 0 { b |= 0x80 }
                bytes.append(b)
            } while n != 0
            return bytes + name
        }
        var bytes: [UInt8] = [rawKind]
        for k in 0 ..< 8 { bytes.append(UInt8(truncatingIfNeeded: peer >> (8 * k))) }
        let c = UInt32(bitPattern: counter)
        for k in 0 ..< 4 { bytes.append(UInt8(truncatingIfNeeded: c >> (8 * k))) }
        return bytes
    }

    /// From a state table key.
    init?(key: [UInt8]) {
        guard let first = key.first else { return nil }
        if first & 0x80 != 0 {
            var r = ByteReader(key, from: 1, context: "a container's id")
            guard let name = try? r.utf8(), r.isAtEnd else { return nil }
            self.rawKind = first & 0x7f
            self.rootName = name
        } else {
            guard key.count == 13 else { return nil }
            var r = ByteReader(key, from: 1, context: "a container's id")
            guard let peer = try? r.u64le(), let counter = try? r.u32le() else { return nil }
            self.rawKind = first
            self.peer = peer
            self.counter = Int32(bitPattern: counter)
        }
    }

    init(rawKind: UInt8, rootName: String? = nil, peer: UInt64 = 0, counter: Int32 = 0) {
        self.rawKind = rawKind
        self.rootName = rootName
        self.peer = peer
        self.counter = counter
    }

    /// Postcard's form of an id, as a value or a parent names it. Postcard numbers the
    /// kinds otherwise than the table's keys do.
    static func postcard(_ r: inout ByteReader) throws -> ContainerID {
        let variant = try r.uleb()
        func kind() throws -> UInt8 {
            let historical = try r.u8()
            switch historical {
            case 0: return Kind.text.rawValue
            case 1: return Kind.map.rawValue
            case 2: return Kind.list.rawValue
            case 3: return Kind.movableList.rawValue
            case 4: return Kind.tree.rawValue
            default: return historical
            }
        }
        switch variant {
        case 0:
            let name = try r.utf8()
            return ContainerID(rawKind: try kind(), rootName: name)
        case 1:
            let peer = try r.uleb()
            let counter = try r.zigzag()
            guard let c = Int32(exactly: counter) else { throw LoroError.malformed("a container's counter") }
            return ContainerID(rawKind: try kind(), peer: peer, counter: c)
        default:
            throw LoroError.malformed("a container's id")
        }
    }
}

public struct LoroDocument: Sendable {
    /// The state table: each container's stored bytes, by its key.
    private let state: [[UInt8]: [UInt8]]
    /// The names of the document's roots, and the kind of each.
    public let rootNames: [String]
    private let rootKinds: [String: UInt8]

    /// Reads a snapshot. The bytes are checked against the checksum they carry.
    public init(snapshot: Data) throws {
        let bytes = [UInt8](snapshot)
        guard bytes.count >= 22, bytes[0 ..< 4].elementsEqual(Array("loro".utf8)) else { throw LoroError.notLoro }
        var header = ByteReader(bytes, from: 16, context: "the envelope")
        let checksum = try header.u32le()
        let mode = UInt16(bytes[20]) << 8 | UInt16(bytes[21])
        guard mode == 3 else { throw LoroError.unsupportedMode(mode) }
        guard XXHash32.hash(bytes[20...], seed: XXHash32.loroSeed) == checksum else { throw LoroError.checksumMismatch }

        var body = ByteReader(bytes, from: 22, context: "the snapshot's sections")
        _ = try body.take(Int(try body.u32le())) // the history
        let stateBytes = Array(try body.take(Int(try body.u32le())))
        let shallowRoot = Array(try body.take(Int(try body.u32le())))
        guard body.isAtEnd else { throw LoroError.malformed("bytes after the snapshot's sections") }

        var table: [[UInt8]: [UInt8]]
        if shallowRoot.isEmpty {
            guard stateBytes != [0x45] else { throw LoroError.historyOnly }
            table = try SSTable.read(stateBytes)
        } else {
            // A shallow snapshot: the state at its start, and what has changed since
            // laid over it ("E" for nothing laid over: the changes are only in the
            // history, which is not replayed here).
            guard stateBytes != [0x45] else { throw LoroError.historyOnly }
            table = try SSTable.read(shallowRoot)
            table[Array("fr".utf8)] = nil
            for (key, value) in try SSTable.read(stateBytes) { table[key] = value }
        }
        state = table

        var kinds: [String: UInt8] = [:]
        for key in table.keys {
            if let id = ContainerID(key: key), let name = id.rootName { kinds[name] = id.rawKind }
        }
        // (The roots made for mergeable containers are not the document's own roots:
        // each is shown where its marker is. Mergeable.swift says more.)
        kinds = kinds.filter { !$0.key.hasPrefix(Mergeable.prefix) }
        rootKinds = kinds
        rootNames = kinds.keys.sorted()
    }

    /// One root, with every container in it read.
    public func value(of root: String) throws -> LoroValue {
        guard let kind = rootKinds[root] else { return .null }
        return try value(of: ContainerID(rawKind: kind, rootName: root), depth: 0)
    }

    /// Every root, by name.
    public func value() throws -> [String: LoroValue] {
        var result: [String: LoroValue] = [:]
        for name in rootNames { result[name] = try value(of: name) }
        return result
    }

    // MARK: - Containers

    private func value(of id: ContainerID, depth: Int) throws -> LoroValue {
        guard depth < 256 else { throw LoroError.malformed("containers nested too deeply") }
        guard let stored = state[id.key] else {
            // A container never written to is not stored: it is empty.
            switch ContainerID.Kind(rawValue: id.rawKind) {
            case .map: return .map([:])
            case .list, .movableList, .tree: return .list([])
            case .text: return .string("")
            case .counter: return .double(0)
            case nil: return .null
            }
        }
        // The wrapper: the kind, how deep it is, and its parent; then its state.
        var r = ByteReader(stored, context: "a container")
        let kind = try r.u8()
        _ = try r.uleb() // depth
        if try r.u8() == 1 { _ = try ContainerID.postcard(&r) } // parent

        switch ContainerID.Kind(rawValue: kind) {
        case .map:
            // The visible entries come first; who set each, and when, follows.
            var result: [String: LoroValue] = [:]
            let count = try r.count()
            for _ in 0 ..< count {
                let key = try r.utf8()
                var stored = try Self.postcardValue(&r, depth: 0)
                if case .plain(.binary(let bytes)) = stored, let child = Mergeable.child(of: id, key: key, marker: bytes) {
                    stored = .container(child)
                }
                result[key] = try resolve(stored, depth: depth)
            }
            return .map(result)
        case .list, .movableList:
            // The visible items come first; their ids follow.
            let count = try r.count()
            var items: [LoroValue] = []
            items.reserveCapacity(count)
            for _ in 0 ..< count { items.append(try resolve(try Self.postcardValue(&r, depth: 0), depth: depth)) }
            return .list(items)
        case .text:
            return .string(try r.utf8())
        case .counter:
            return .double(r.remaining >= 8 ? try r.f64le() : 0)
        case .tree:
            return try tree(&r, depth: depth)
        case nil:
            return .null
        }
    }

    /// A value read from the state, with each container it names replaced by what that
    /// container holds.
    private func resolve(_ value: Stored, depth: Int) throws -> LoroValue {
        switch value {
        case .plain(let v): return v
        case .container(let id): return try self.value(of: id, depth: depth + 1)
        case .list(let items): return .list(try items.map { try resolve($0, depth: depth) })
        case .map(let entries): return .map(try entries.mapValues { try resolve($0, depth: depth) })
        }
    }

    /// A value as stored: like LoroValue, but a container is only named.
    private indirect enum Stored {
        case plain(LoroValue)
        case container(ContainerID)
        case list([Stored])
        case map([String: Stored])
    }

    /// Postcard's form of a value (docs/encoding-container-states.md, section 3).
    private static func postcardValue(_ r: inout ByteReader, depth: Int) throws -> Stored {
        guard depth < 256 else { throw LoroError.malformed("values nested too deeply") }
        switch try r.uleb() {
        case 0: return .plain(.null)
        case 1: return .plain(.bool(try r.u8() != 0))
        case 2: return .plain(.double(try r.f64le()))
        case 3: return .plain(.int(try r.zigzag()))
        case 4: return .plain(.string(try r.utf8()))
        case 5:
            let count = try r.count()
            var items: [Stored] = []
            for _ in 0 ..< count { items.append(try postcardValue(&r, depth: depth + 1)) }
            return .list(items)
        case 6:
            let count = try r.count()
            var entries: [String: Stored] = [:]
            for _ in 0 ..< count {
                let key = try r.utf8()
                entries[key] = try postcardValue(&r, depth: depth + 1)
            }
            return .map(entries)
        case 7: return .container(try ContainerID.postcard(&r))
        case 8: return .plain(.binary(Array(try r.lengthPrefixed())))
        case let other: throw LoroError.malformed("a value of an unknown kind (\(other))")
        }
    }

    // MARK: - Trees

    /// A tree's nodes (docs/encoding-container-states.md, section 7): its peers, then
    /// its columns: each node's id, then each node's parent, who last moved it and
    /// when, and its place among its siblings (a "fractional index", from a table of
    /// them that follows). Each node's own data is a map with the node's id.
    private func tree(_ r: inout ByteReader, depth: Int) throws -> LoroValue {
        let peers = try Self.peerTable(&r)
        guard try r.uleb() == 4 else { throw LoroError.malformed("a tree's fields") }

        guard try r.uleb() == 2 else { throw LoroError.malformed("a tree's node ids") }
        let nodePeers = try Columnar.deltaRle(try r.lengthPrefixed())
        let nodeCounters = try Columnar.deltaRle(try r.lengthPrefixed())

        guard try r.uleb() == 5 else { throw LoroError.malformed("a tree's nodes") }
        let parents = try Columnar.deltaRle(try r.lengthPrefixed())
        let setPeers = try Columnar.deltaRle(try r.lengthPrefixed())
        let setCounters = try Columnar.deltaRle(try r.lengthPrefixed())
        let setLamportSubs = try Columnar.deltaRle(try r.lengthPrefixed())
        let positionIndices = try Columnar.genericUnsigned(try r.lengthPrefixed())

        let positions = try Columnar.positionArena(try r.lengthPrefixed())
        _ = try r.lengthPrefixed() // reserved

        let n = nodePeers.count
        guard nodeCounters.count == n, parents.count == n, setPeers.count == n, setCounters.count == n,
              setLamportSubs.count == n, positionIndices.count == n else {
            throw LoroError.malformed("a tree's columns of different lengths")
        }

        struct Node {
            var peer: UInt64
            var counter: Int32
            var parent: Int? // a row; nil for the root
            var deleted: Bool
            var position: [UInt8]
            var lamport: Int64
            var setPeer: UInt64
        }
        func peer(_ index: Int64) throws -> UInt64 {
            guard index >= 0, index < Int64(peers.count) else { throw LoroError.malformed("a tree's peer") }
            return peers[Int(index)]
        }
        var nodes: [Node] = []
        nodes.reserveCapacity(n)
        for k in 0 ..< n {
            guard let counter = Int32(exactly: nodeCounters[k]), counter >= 0 else { throw LoroError.malformed("a tree node's counter") }
            let p = parents[k]
            guard p >= 0, p < Int64(n) + 2 else { throw LoroError.malformed("a tree node's parent") }
            let pi = Int(positionIndices[k])
            guard pi >= 0, pi < positions.count else { throw LoroError.malformed("a tree node's position") }
            nodes.append(Node(
                peer: try peer(nodePeers[k]), counter: counter,
                parent: p >= 2 ? Int(p - 2) : nil, deleted: p == 1,
                position: positions[pi], lamport: setCounters[k] + setLamportSubs[k], setPeer: try peer(setPeers[k])
            ))
        }

        // Siblings in Loro's order: by place, then by when and by whom they were placed.
        var children: [Int?: [Int]] = [:]
        for k in 0 ..< n where !nodes[k].deleted { children[nodes[k].parent, default: []].append(k) }
        for key in children.keys {
            children[key]!.sort { a, b in
                let x = nodes[a], y = nodes[b]
                if x.position != y.position { return x.position.lexicographicallyPrecedes(y.position) }
                if x.lamport != y.lamport { return x.lamport < y.lamport }
                return x.setPeer < y.setPeer
            }
        }
        func id(_ k: Int) -> String { "\(nodes[k].counter)@\(nodes[k].peer)" }
        func build(_ k: Int, index: Int, level: Int) throws -> LoroValue {
            guard level < 256 else { throw LoroError.malformed("a tree nested too deeply") }
            let node = nodes[k]
            let meta = try value(of: ContainerID(rawKind: ContainerID.Kind.map.rawValue, peer: node.peer, counter: node.counter), depth: depth + 1)
            let kids = try (children[k] ?? []).enumerated().map { try build($0.element, index: $0.offset, level: level + 1) }
            return .map([
                "id": .string(id(k)),
                "parent": node.parent.map { .string(id($0)) } ?? .null,
                "index": .int(Int64(index)),
                "fractional_index": .string(node.position.map { String(format: "%02X", $0) }.joined()),
                "meta": meta,
                "children": .list(kids),
            ])
        }
        // (A node whose parent is deleted is left out with it.)
        return .list(try (children[nil] ?? []).enumerated().map { try build($0.element, index: $0.offset, level: 0) })
    }

    /// The table of peers some states start with: a count, then each one's eight bytes.
    private static func peerTable(_ r: inout ByteReader) throws -> [UInt64] {
        let count = try r.count(limit: r.remaining / 8)
        var peers: [UInt64] = []
        for _ in 0 ..< count { peers.append(try r.u64le()) }
        return peers
    }
}

/// The column encodings of serde_columnar that a tree's state uses
/// (docs/encoding.md, section 8).
enum Columnar {
    /// A run-length column: runs of one value repeated (a positive count), or of values
    /// given one by one (a negative count), each value a postcard signed or unsigned
    /// number as `signed` says.
    static func anyRle(_ bytes: ArraySlice<UInt8>, signed: Bool) throws -> [Int64] {
        var r = ByteReader(Array(bytes), context: "a column")
        var values: [Int64] = []
        while !r.isAtEnd {
            let run = try r.zigzag()
            guard run != 0, abs(run) <= 1 << 28 else { throw LoroError.malformed("a column's run") }
            func one() throws -> Int64 {
                if signed { return try r.zigzag() }
                let u = try r.uleb()
                guard let v = Int64(exactly: u) else { throw LoroError.malformed("a column's value") }
                return v
            }
            if run > 0 {
                let v = try one()
                values.append(contentsOf: repeatElement(v, count: Int(run)))
            } else {
                for _ in 0 ..< Int(-run) { values.append(try one()) }
            }
        }
        return values
    }

    /// A column of differences from the value before, run-length coded.
    static func deltaRle(_ bytes: ArraySlice<UInt8>) throws -> [Int64] {
        var last: Int64 = 0
        return try anyRle(bytes, signed: true).map { delta in
            last = last &+ delta
            return last
        }
    }

    /// A plain postcard list of unsigned numbers.
    static func genericUnsigned(_ bytes: ArraySlice<UInt8>) throws -> [Int64] {
        var r = ByteReader(Array(bytes), context: "a column")
        let count = try r.count()
        var values: [Int64] = []
        for _ in 0 ..< count {
            guard let v = Int64(exactly: try r.uleb()) else { throw LoroError.malformed("a column's value") }
            values.append(v)
        }
        return values
    }

    /// A table of byte strings, each told as how much it shares with the one before it
    /// and what it adds.
    static func positionArena(_ bytes: ArraySlice<UInt8>) throws -> [[UInt8]] {
        var r = ByteReader(Array(bytes), context: "a tree's positions")
        guard !r.isAtEnd else { return [] }
        guard try r.uleb() == 1, try r.uleb() == 2 else { throw LoroError.malformed("a tree's positions") }
        let shared = try anyRle(try r.lengthPrefixed(), signed: false)
        var rest = ByteReader(Array(try r.lengthPrefixed()), context: "a tree's positions")
        let count = try rest.count()
        guard count == shared.count else { throw LoroError.malformed("a tree's positions") }
        var result: [[UInt8]] = []
        for k in 0 ..< count {
            let tail = Array(try rest.lengthPrefixed())
            let prefix = Int(shared[k])
            if k == 0 {
                guard prefix == 0 else { throw LoroError.malformed("a tree's first position") }
                result.append(tail)
            } else {
                guard prefix <= result[k - 1].count else { throw LoroError.malformed("a tree's position") }
                result.append(Array(result[k - 1][0 ..< prefix]) + tail)
            }
        }
        return result
    }
}

extension LoroValue {
    /// The value as JSONSerialization takes it, shaped as Loro's `toJSON()` gives it,
    /// but for binary data, which is written as text: "base64:" and its Base64. For
    /// comparing this reader with Loro's own.
    public var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .double(let d): return d
        case .int(let i): return i
        case .string(let s): return s
        case .binary(let b): return "base64:" + Data(b).base64EncodedString()
        case .list(let l): return l.map(\.jsonObject)
        case .map(let m): return m.mapValues(\.jsonObject)
        }
    }
}
