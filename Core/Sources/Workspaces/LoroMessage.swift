// LoroMessage: a ProPresenter message (a presentation, say) made out of the tree a
// workspace kept in a database holds it as.
//
// KNOWN (the maintainer's workspace, ProPresenter 22.7 beta, 2026-10, compared document
// for document with the folder workspace it was made from): each document is a Loro
// document whose root map "root" is the message, part for part, named as the message's
// fields are named in ProPresenter's descriptions (proto/autogen-proto). What differs
// from the message's own bytes, and is undone here:
//
//   - An id (rv.data.UUID, a message of one string) is its text.
//   - A choice between fields (a oneof) is a part named for the choice, holding
//     "__tag", the name of the field chosen (or nothing), and that field under its own
//     name. (One was seen without its "__tag": the one field it holds is taken.)
//   - A field at its default is there, with that default; one that is a message and is
//     not set is null.
//   - A few fields are named otherwise than 21.4's descriptions name them ("hot_key"
//     for "hotKey"), so a name is also matched without its underscores and case.
//   - Some lists are under a new name, the old one with "_v2" ("group_identifiers_v2"
//     in an arrangement, in place of "group_identifiers"). A part "x_v2" is taken as
//     the field "x" when the tree has no "x" of its own, or an empty one. KNOWN of
//     arrangements; A GUESS of the rest (a slide's "element_build_order_v2").
//   - A list ProPresenter keeps by id is a map of id to item; its items are taken in
//     the order of their ids, unless the caller has put them in order first
//     (PresentationTree.swift does, for a presentation's cues).
//
// It is done by going through the message's description field by field (Descriptions,
// generated beside ProFormat's code), writing protobuf's own bytes, which the generated
// code then reads. What the tree has that 21.4's descriptions do not (fields added
// since), or has in another shape than they say, is left out, and named in
// `unknownFields`, for the tests to look at.

import Foundation
import LoroKit
import ProFormat
import SwiftProtobuf

enum LoroMessageError: Error, CustomStringConvertible {
    case noSuchMessage(String)
    case wrongShape(String)

    var description: String {
        switch self {
        case .noSuchMessage(let name): return "ProPresenter's descriptions have no message \(name)."
        case .wrongShape(let what): return "The document is not shaped as expected (\(what))."
        }
    }
}

/// ProPresenter's messages, field by field, from the descriptions ProFormat keeps.
final class MessageSchema: Sendable {
    struct Field: Sendable {
        let name: String
        let number: Int
        let type: Google_Protobuf_FieldDescriptorProto.TypeEnum
        let isRepeated: Bool
        /// For a message or an enum: its full name, with the leading ".".
        let typeName: String
        /// The oneof it is one choice of, if any (not proto3's made-up ones for `optional`).
        let oneof: String?
    }

    struct Message: Sendable {
        let fields: [Field]
        let byName: [String: Int]
        let byLooseName: [String: Int]
        let oneofs: Set<String>
        let looseOneofs: [String: String]
        let isMapEntry: Bool

        /// A field by its name, or else by its name without underscores and case.
        func field(_ name: String) -> Field? {
            if let k = byName[name] { return fields[k] }
            if let k = byLooseName[MessageSchema.loose(name)] { return fields[k] }
            return nil
        }

        /// A oneof by its name, or else loosely.
        func oneof(_ name: String) -> String? {
            if oneofs.contains(name) { return name }
            return looseOneofs[MessageSchema.loose(name)]
        }
    }

    let messages: [String: Message]

    static let shared: MessageSchema = {
        // The descriptions are generated with the code; if they could not be read, the
        // code beside them could not have been built from them either.
        let data = Data(base64Encoded: Descriptions.fileDescriptorSet)!
        let set = try! Google_Protobuf_FileDescriptorSet(serializedBytes: data)
        return MessageSchema(set)
    }()

    init(_ set: Google_Protobuf_FileDescriptorSet) {
        var messages: [String: Message] = [:]
        func add(_ d: Google_Protobuf_DescriptorProto, in scope: String) {
            let fullName = scope + "." + d.name
            var fields: [Field] = []
            for f in d.field {
                let oneof: String?
                if f.hasOneofIndex, !f.proto3Optional, d.oneofDecl.indices.contains(Int(f.oneofIndex)) {
                    oneof = d.oneofDecl[Int(f.oneofIndex)].name
                } else {
                    oneof = nil
                }
                fields.append(Field(name: f.name, number: Int(f.number), type: f.type, isRepeated: f.label == .repeated, typeName: f.typeName, oneof: oneof))
            }
            var byName: [String: Int] = [:], byLoose: [String: Int] = [:]
            for (k, f) in fields.enumerated() {
                byName[f.name] = k
                byLoose[Self.loose(f.name)] = byLoose[Self.loose(f.name)] ?? k
            }
            let oneofs = Set(fields.compactMap(\.oneof))
            messages[fullName] = Message(
                fields: fields, byName: byName, byLooseName: byLoose, oneofs: oneofs,
                looseOneofs: Dictionary(oneofs.map { (Self.loose($0), $0) }, uniquingKeysWith: { a, _ in a }),
                isMapEntry: d.options.mapEntry
            )
            for nested in d.nestedType { add(nested, in: fullName) }
        }
        for file in set.file {
            let scope = file.package.isEmpty ? "" : "." + file.package
            for d in file.messageType { add(d, in: scope) }
        }
        self.messages = messages
    }

    static func loose(_ name: String) -> String { name.replacingOccurrences(of: "_", with: "").lowercased() }
}

struct LoroMessage {
    let schema: MessageSchema
    /// Each part of the tree that no field was found for, as "Message.part", with how
    /// often it came.
    private(set) var unknownFields: [String: Int] = [:]

    init(schema: MessageSchema = .shared) {
        self.schema = schema
    }

    /// The message of this type (its full name, "rv.data.Presentation") that the tree is.
    mutating func message<M: SwiftProtobuf.Message>(_ type: M.Type, from tree: LoroValue) throws -> M {
        let bytes = try encode(tree, as: "." + M.protoMessageName)
        return try M(serializedBytes: bytes)
    }

    mutating func encode(_ tree: LoroValue, as messageName: String) throws -> [UInt8] {
        var out: [UInt8] = []
        try writeMessage(tree, messageName, into: &out)
        return out
    }

    // MARK: -

    private mutating func writeMessage(_ value: LoroValue, _ name: String, into out: inout [UInt8]) throws {
        guard let message = schema.messages[name] else { throw LoroMessageError.noSuchMessage(name) }
        switch value {
        case .map(var parts):
            // A part "x_v2" stands for the field "x" when the tree has no "x" of its own.
            for key in parts.keys where key.hasSuffix("_v2") {
                let base = String(key.dropLast(3))
                guard message.byName[base] != nil else { continue }
                let own = parts[base]
                if own == nil || own == .null || own == .list([]) {
                    parts[base] = parts[key]
                    parts[key] = nil
                }
            }
            for key in parts.keys.sorted() {
                let part = parts[key]!
                if part.isNull { continue }
                // A name as it is first, a field's or a choice's; then loosely.
                if let k = message.byName[key] {
                    try writeField(message.fields[k], part, in: name, into: &out)
                } else if message.oneofs.contains(key), case .map(let choice) = part {
                    try writeChoice(choice, of: message, in: name, into: &out)
                } else if let field = message.field(key) {
                    try writeField(field, part, in: name, into: &out)
                } else if message.oneof(key) != nil, case .map(let choice) = part {
                    try writeChoice(choice, of: message, in: name, into: &out)
                } else {
                    unknownFields[String(name.dropFirst()) + "." + key, default: 0] += 1
                }
            }
        case .string(let text):
            // An id kept as its text: a message of one string field.
            guard let only = message.fields.first, message.fields.count == 1, only.type == .string else {
                throw LoroMessageError.wrongShape("text where \(name) was expected")
            }
            try writeField(only, .string(text), in: name, into: &out)
        default:
            throw LoroMessageError.wrongShape("a value where \(name) was expected")
        }
    }

    /// A oneof's part: "__tag" names the field chosen, which is under its own name.
    private mutating func writeChoice(_ choice: [String: LoroValue], of message: MessageSchema.Message, in name: String, into out: inout [UInt8]) throws {
        if let tag = choice["__tag"] {
            guard let chosen = tag.string else { return } // nothing chosen
            guard let field = message.field(chosen), let value = choice[chosen] ?? choice.first(where: { MessageSchema.loose($0.key) == MessageSchema.loose(chosen) })?.value else {
                unknownFields[String(name.dropFirst()) + "." + chosen, default: 0] += 1
                return
            }
            try writeField(field, value, in: name, into: &out)
        } else {
            // No "__tag": the one field there is.
            for (key, value) in choice where !value.isNull {
                if let field = message.field(key) {
                    try writeField(field, value, in: name, into: &out)
                    return
                }
            }
        }
    }

    private mutating func writeField(_ field: MessageSchema.Field, _ value: LoroValue, in name: String, into out: inout [UInt8]) throws {
        if value.isNull { return }
        if field.isRepeated {
            let items: [LoroValue]
            switch value {
            case .list(let list): items = list
            case .map(let byID) where !(schema.messages[field.typeName]?.isMapEntry ?? false):
                // A list kept by id.
                items = byID.keys.sorted().map { byID[$0]! }
            case .map(let entries):
                // A protobuf map: each entry a message of its key (1) and value (2).
                for key in entries.keys.sorted() {
                    var entry: [UInt8] = []
                    let types = schema.messages[field.typeName]!
                    let keyValue: LoroValue = types.fields[0].type == .string ? .string(key) : .int(Int64(key) ?? 0)
                    try writeField(types.fields[0], keyValue, in: field.typeName, into: &entry)
                    try writeField(types.fields[1], entries[key]!, in: field.typeName, into: &entry)
                    Wire.tag(field.number, 2, into: &out)
                    Wire.bytes(entry, into: &out)
                }
                return
            default:
                items = [value]
            }
            for item in items where !item.isNull { try writeLeniently(field, item, in: name, into: &out) }
        } else {
            try writeLeniently(field, value, in: name, into: &out)
        }
    }

    /// One value of a field; or, if it is not shaped as the field is, nothing, and the
    /// field named in `unknownFields`: one part not as 21.4 has it does not cost the
    /// rest of the presentation.
    private mutating func writeLeniently(_ field: MessageSchema.Field, _ value: LoroValue, in name: String, into out: inout [UInt8]) throws {
        var piece: [UInt8] = []
        do {
            try writeOne(field, value, in: name, into: &piece)
            out.append(contentsOf: piece)
        } catch LoroMessageError.wrongShape {
            unknownFields[String(name.dropFirst()) + "." + field.name + " (not as expected)", default: 0] += 1
        }
    }

    private mutating func writeOne(_ field: MessageSchema.Field, _ value: LoroValue, in name: String, into out: inout [UInt8]) throws {
        func number() throws -> Double {
            switch value {
            case .double(let d): return d
            case .int(let i): return Double(i)
            case .bool(let b): return b ? 1 : 0
            default: throw LoroMessageError.wrongShape("\(field.name) of \(name) is not a number")
            }
        }
        func integer() throws -> Int64 {
            if case .int(let i) = value { return i }
            let d = try number()
            guard d.isFinite, abs(d) < 9.2e18 else { throw LoroMessageError.wrongShape("\(field.name) of \(name) is out of range") }
            return Int64(d.rounded())
        }
        let n = field.number
        switch field.type {
        case .double:
            Wire.tag(n, 1, into: &out)
            Wire.fixed64(try number().bitPattern, into: &out)
        case .float:
            Wire.tag(n, 5, into: &out)
            Wire.fixed32(Float(try number()).bitPattern, into: &out)
        case .int64, .uint64, .int32, .uint32, .enum:
            Wire.tag(n, 0, into: &out)
            Wire.varint(UInt64(bitPattern: try integer()), into: &out)
        case .bool:
            Wire.tag(n, 0, into: &out)
            let b: Bool
            switch value {
            case .bool(let v): b = v
            default: b = try number() != 0
            }
            Wire.varint(b ? 1 : 0, into: &out)
        case .sint32, .sint64:
            let v = try integer()
            Wire.tag(n, 0, into: &out)
            Wire.varint(UInt64(bitPattern: (v << 1) ^ (v >> 63)), into: &out)
        case .fixed32, .sfixed32:
            Wire.tag(n, 5, into: &out)
            Wire.fixed32(UInt32(truncatingIfNeeded: try integer()), into: &out)
        case .fixed64, .sfixed64:
            Wire.tag(n, 1, into: &out)
            Wire.fixed64(UInt64(bitPattern: try integer()), into: &out)
        case .string:
            guard case .string(let s) = value else { throw LoroMessageError.wrongShape("\(field.name) of \(name) is not text") }
            Wire.tag(n, 2, into: &out)
            Wire.bytes(Array(s.utf8), into: &out)
        case .bytes:
            let bytes: [UInt8]
            switch value {
            case .binary(let b): bytes = b
            case .string(let s): bytes = Array(s.utf8)
            default: throw LoroMessageError.wrongShape("\(field.name) of \(name) is not bytes")
            }
            Wire.tag(n, 2, into: &out)
            Wire.bytes(bytes, into: &out)
        case .message:
            var inner: [UInt8] = []
            try writeMessage(value, field.typeName, into: &inner)
            Wire.tag(n, 2, into: &out)
            Wire.bytes(inner, into: &out)
        default:
            unknownFields[String(name.dropFirst()) + "." + field.name + " (a kind of field not read)", default: 0] += 1
        }
    }
}

/// Protobuf's wire format, as far as writing goes.
enum Wire {
    static func varint(_ value: UInt64, into out: inout [UInt8]) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    static func tag(_ number: Int, _ wireType: UInt64, into out: inout [UInt8]) {
        varint(UInt64(number) << 3 | wireType, into: &out)
    }

    static func fixed32(_ value: UInt32, into out: inout [UInt8]) {
        for k in 0 ..< 4 { out.append(UInt8(truncatingIfNeeded: value >> (8 * k))) }
    }

    static func fixed64(_ value: UInt64, into out: inout [UInt8]) {
        for k in 0 ..< 8 { out.append(UInt8(truncatingIfNeeded: value >> (8 * k))) }
    }

    static func bytes(_ bytes: [UInt8], into out: inout [UInt8]) {
        varint(UInt64(bytes.count), into: &out)
        out.append(contentsOf: bytes)
    }
}
