// DatabaseWorkspace: a workspace kept in a database (the versions of ProPresenter after
// 21), read.
//
// KNOWN (the maintainer's workspace, ProPresenter 22.7 beta, 2026-10, compared with the
// folder workspace it was copied from, docs/WORKSPACES.md): its folder has
// `DocumentStore/workspace-v1.sqlite3`, whose table `workspace_streams` has a row for
// each document: its id (16 bytes), `scope` (0 for what is shared, 1 for this Mac's
// own), `kind` ("Presentation", "PlaylistLibrary", "LibraryData", …), for a
// presentation `core_path` ("<library>/<name>", no ending), `availability` (1 for a
// document known of but not yet on this Mac, with no snapshot), and `snapshot`, the
// document as a Loro snapshot (LoroKit).
//
//   - A presentation's root is the presentation (LoroMessage, PresentationTree).
//   - "LibraryData" lists the libraries: root.rootLibrary, its libraries each with a
//     URL whose path is "Libraries/<library>". A library with no presentation in it is
//     known only from there.
//   - "PlaylistLibrary" (shared scope) keeps the playlists in a tree,
//     root.playlists: the top node is ProPresenter's root (the same id as the folder
//     workspace's root playlist), and under it folders (Kind "group"), playlists (Kind
//     "playlist") and, under a playlist, its items (Kind "item", with the item's
//     ItemType as in PlaylistItem). A presentation item names its presentation by the
//     URL it had in the folder workspace ("Libraries/<library>/<name>.pro"), which is
//     found by its core_path, as ProPresenter matches it, without regard to case
//     (`core_path_key` is the core path in small letters).
//
// The database is read from a copy (SQLiteReader says why), made once and made again
// whenever the database or its "-wal" has changed since.

import Foundation
import LoroKit
import ProFormat

enum DatabaseWorkspace {
    static func contents(of workspace: Workspace) throws -> WorkspaceContents {
        try DatabaseStores.shared.read(workspace.store) { db in
            guard try db.hasTable("workspace_streams") else {
                throw WorkspaceError.unreadable(workspace.name, "it is kept in a way this app does not know")
            }
            // The presentations, by library.
            let rows = try db.rows("SELECT hex(document_id) AS id, core_path, availability FROM workspace_streams WHERE kind = 'Presentation' AND scope = 0 AND core_path IS NOT NULL")
            var byLibrary: [String: [PresentationRef]] = [:]
            var byKey: [String: PresentationRef] = [:]
            for row in rows {
                guard let id = row["id"]?.text, let path = row["core_path"]?.text else { continue }
                let (library, name) = split(path)
                let ref = PresentationRef(
                    name: name, location: .document(store: workspace.store, id: id),
                    workspaceFolder: workspace.folder, isAvailable: row["availability"]?.integer != 1
                )
                byLibrary[library, default: []].append(ref)
                byKey[path.lowercased()] = ref
            }

            // The libraries, in the order ProPresenter lists them, then any others.
            var names: [String] = []
            if let tree = try document(db, kind: "LibraryData") {
                for library in tree["rootLibrary"]?["ChildType"]?["libraryChildren"]?["libraries"]?.list ?? [] {
                    if let path = library["url"]?["RelativeFilePath"]?["local"]?["path"]?.string {
                        let name = path.hasPrefix("Libraries/") ? String(path.dropFirst("Libraries/".count)) : (path as NSString).lastPathComponent
                        if !name.isEmpty, !names.contains(name) { names.append(name) }
                    }
                }
            }
            for name in byLibrary.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where !names.contains(name) {
                names.append(name)
            }
            let libraries = names.map { name in
                Library(name: name, presentations: (byLibrary[name] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }

            // The playlists.
            var playlists: [PlaylistNode] = []
            if let tree = try document(db, kind: "PlaylistLibrary") {
                for top in tree["playlists"]?.list ?? [] {
                    // The top is ProPresenter's root, not shown: its children are.
                    playlists.append(contentsOf: (top["children"]?.list ?? []).compactMap { node($0, byKey: byKey) })
                }
            }
            return WorkspaceContents(libraries: libraries, playlists: playlists)
        }
    }

    static func presentation(store: URL, id: String) throws -> RVData_Presentation {
        try DatabaseStores.shared.read(store) { db in
            guard id.count == 32, id.allSatisfy(\.isHexDigit) else { throw WorkspaceError.notFound("The presentation") }
            let rows = try db.rows("SELECT snapshot, core_path FROM workspace_streams WHERE document_id = X'\(id)' AND scope = 0")
            guard let row = rows.first else { throw WorkspaceError.notFound("The presentation") }
            let name = row["core_path"]?.text.map { split($0).name } ?? "The presentation"
            guard let snapshot = row["snapshot"]?.blob else { throw WorkspaceError.notAvailable(name) }
            do {
                let doc = try LoroDocument(snapshot: snapshot)
                var builder = LoroMessage()
                return try builder.message(RVData_Presentation.self, from: PresentationTree.asMessageTree(try doc.value(of: "root")))
            } catch {
                throw WorkspaceError.unreadable(name, "\(error)")
            }
        }
    }

    // MARK: -

    /// The root of a document there is one of, if it is there.
    private static func document(_ db: SQLiteReader, kind: String) throws -> LoroValue? {
        let rows = try db.rows("SELECT snapshot FROM workspace_streams WHERE kind = ? AND scope = 0 AND snapshot IS NOT NULL", [kind])
        guard let snapshot = rows.first?["snapshot"]?.blob else { return nil }
        return try LoroDocument(snapshot: snapshot).value(of: "root")
    }

    /// "<library>/<name>" into its two parts.
    private static func split(_ corePath: String) -> (library: String, name: String) {
        guard let slash = corePath.lastIndex(of: "/") else { return ("", corePath) }
        return (String(corePath[..<slash]), String(corePath[corePath.index(after: slash)...]))
    }

    /// A node of the playlists' tree: a folder or a playlist (nil for anything else).
    private static func node(_ node: LoroValue, byKey: [String: PresentationRef]) -> PlaylistNode? {
        let meta = node["meta"]
        let id = meta?["uuid"]?.string ?? node["id"]?.string ?? UUID().uuidString
        let name = meta?["name"]?.string ?? ""
        let children = node["children"]?.list ?? []
        switch meta?["Kind"]?["__tag"]?.string {
        case "group":
            return PlaylistNode(id: id, name: name, children: children.compactMap { self.node($0, byKey: byKey) })
        case "playlist":
            return PlaylistNode(id: id, name: name, entries: children.compactMap { entry($0, byKey: byKey) })
        default:
            return nil
        }
    }

    private static func entry(_ node: LoroValue, byKey: [String: PresentationRef]) -> PlaylistEntry? {
        guard let meta = node["meta"], meta["Kind"]?["__tag"]?.string == "item" else { return nil }
        let id = meta["uuid"]?.string ?? node["id"]?.string ?? UUID().uuidString
        let name = meta["name"]?.string ?? ""
        let type = meta["Kind"]?["item"]?["ItemType"]
        switch type?["__tag"]?.string {
        case "header":
            return PlaylistEntry(id: id, name: name, kind: .header)
        case "presentation":
            let p = type?["presentation"]
            let path = p?["document_path"]?["RelativeFilePath"]?["local"]?["path"]?.string
                ?? (p?["document_path"]?["Storage"]?["absolute_string"]?.string).flatMap { URL(string: $0)?.path }
                ?? ""
            var key = path
            if let range = key.range(of: "Libraries/") { key = String(key[range.upperBound...]) }
            if key.lowercased().hasSuffix(".pro") { key = String(key.dropLast(4)) }
            var ref = byKey[key.lowercased()]
            if ref == nil {
                // By name alone, as a folder workspace's items are (FolderWorkspace).
                let name = (key as NSString).lastPathComponent.lowercased()
                ref = byKey.first { ($0.key as NSString).lastPathComponent == name }?.value
            }
            let arrangement = p?["arrangement"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return PlaylistEntry(id: id, name: name, kind: .presentation(ref, arrangement: arrangement))
        default:
            return PlaylistEntry(id: id, name: name, kind: .other)
        }
    }
}

/// The copies of database workspaces' stores read so far, kept while they are current.
final class DatabaseStores: @unchecked Sendable {
    static let shared = DatabaseStores()

    private let lock = NSLock()
    private var open: [String: (reader: SQLiteReader, stamp: [String])] = [:]

    /// Runs `body` with a reader of a current copy of the store. One at a time.
    func read<T>(_ store: URL, _ body: (SQLiteReader) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: store.path) else { throw WorkspaceError.notFound("The workspace's database") }
        let key = store.standardizedFileURL.path
        let now = Self.stamp(store)
        if let kept = open[key], kept.stamp == now { return try body(kept.reader) }
        let reader = try SQLiteReader(copying: store)
        open[key] = (reader, now)
        return try body(reader)
    }

    private static func stamp(_ store: URL) -> [String] {
        [store, URL(fileURLWithPath: store.path + "-wal")].map { url in
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            return "\(a?[.size] ?? "-") \((a?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)"
        }
    }
}
