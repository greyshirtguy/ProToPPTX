// A made-up Mac for the workspace tests: ProPresenter's folder in a temporary folder,
// with every kind of place a workspace is found, all made up.
//
//   Workspaces/registry-v1.sqlite3   the registry of the versions after 21, with its rows
//                                    left in its "-wal", as the maintainer's was found
//   Workspaces/<id>/                 a cloud workspace kept in a database: its store made
//                                    of testdata/loro's made-up documents, and a picture
//                                    in its Media/Assets
//   UserWorkspaces/Folder One/       a folder workspace, listed in the made-up settings
//                                    (userWorkspaces) as in use, and named again by
//                                    applicationShowDirectory
//   Documents/ProPresenter/          the folder from before workspaces
//
// The made-up settings are handed to the finder; nothing of the real Mac's is read.

import AppKit
import Foundation
import ProFormat
import SQLite3
import TestSupport
@testable import Workspaces

final class MadeUpMac {
    let top: URL
    let support: URL
    let documents: URL
    let database: URL
    let folderOne: URL
    /// The registry's connection, kept open so that its rows stay in the "-wal".
    private var registry: OpaquePointer?

    static let databaseID = "4D41-4445-5550-0001"
    static let fixtures = TestFiles.testdata.appendingPathComponent("loro")

    /// A made-up id: the fixtures' ids are 00000000-0000-4000-8000-<n, 12 digits>.
    static func id(_ n: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", n) }

    init() throws {
        top = try TestFiles.scratchFolder()
        support = top.appendingPathComponent("Application Support/RenewedVision/ProPresenter")
        documents = top.appendingPathComponent("Documents")
        database = support.appendingPathComponent("Workspaces/\(Self.databaseID)")
        folderOne = support.appendingPathComponent("UserWorkspaces/Folder One")
        let fm = FileManager.default
        for folder in [database.appendingPathComponent("DocumentStore"), database.appendingPathComponent("Media/Assets"),
                       folderOne.appendingPathComponent("Libraries/Made Up"), folderOne.appendingPathComponent("Playlists"),
                       documents.appendingPathComponent("ProPresenter/Libraries/Old Library")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try makeRegistry()
        try makeStore()
        try Self.picture().write(to: database.appendingPathComponent("Media/Assets/Made Up Background.png"))
        try makeFolderOne()
        try Self.presentation(name: "Old Song", words: "Old made-up words", group: "Verse")
            .serializedData().write(to: documents.appendingPathComponent("ProPresenter/Libraries/Old Library/Old Song.pro"))
    }

    deinit {
        sqlite3_close(registry)
        try? FileManager.default.removeItem(at: top)
    }

    /// ProPresenter's made-up settings.
    var settings: [String: Any] {
        let list: [[String: Any]] = [
            ["name": "Folder One", "url": folderOne.absoluteString, "isActive": true],
            ["name": "Not There", "url": support.appendingPathComponent("UserWorkspaces/Not There").absoluteString, "isActive": false],
        ]
        return [
            "userWorkspaces": try! JSONSerialization.data(withJSONObject: list),
            "applicationShowDirectory": folderOne.path,
        ]
    }

    var finder: WorkspaceFinder {
        let settings = self.settings
        return WorkspaceFinder(proPresentersSetting: { settings[$0] }, supportFolder: support, documents: documents)
    }

    // MARK: - Making it

    private func makeRegistry() throws {
        let file = support.appendingPathComponent("Workspaces/registry-v1.sqlite3")
        guard sqlite3_open(file.path, &registry) == SQLITE_OK else { throw Failure("the registry could not be made") }
        try exec(registry, """
            PRAGMA journal_mode = WAL;
            PRAGMA wal_autocheckpoint = 0;
            CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
            CREATE TABLE workspaces (local_uuid TEXT PRIMARY KEY NOT NULL, root_path TEXT NOT NULL UNIQUE,
                display_name TEXT NOT NULL, cloud_uuid TEXT UNIQUE, schema_version TEXT NOT NULL, availability TEXT NOT NULL);
            INSERT INTO meta VALUES ('active_local_uuid', '\(Self.databaseID)');
            INSERT INTO workspaces VALUES ('\(Self.databaseID)', '\(database.path)', 'Made-Up Cloud', 'C10D', '22.7.0', 'local');
            INSERT INTO workspaces VALUES ('4D41-4445-5550-0002', '\(folderOne.path)', 'Folder One', NULL, '22.0.0', 'local');
            """)
    }

    private func makeStore() throws {
        var db: OpaquePointer?
        guard sqlite3_open(database.appendingPathComponent("DocumentStore/workspace-v1.sqlite3").path, &db) == SQLITE_OK else { throw Failure("the store could not be made") }
        defer { sqlite3_close(db) }
        try exec(db, """
            CREATE TABLE workspace_streams (document_id BLOB NOT NULL, scope INTEGER NOT NULL, location_type INTEGER NOT NULL,
                kind TEXT NOT NULL, core_path TEXT, availability INTEGER NOT NULL, snapshot BLOB, version_vector BLOB,
                sha256 BLOB, byte_count INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, core_path_key TEXT,
                PRIMARY KEY(document_id, scope));
            """)
        func add(_ id: String, _ kind: String, _ corePath: String?, _ fixture: String?, scope: Int = 0) throws {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO workspace_streams VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, 0, ?)", -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let idBytes = Data(hex: id)
            _ = idBytes.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
            sqlite3_bind_int(statement, 2, Int32(scope))
            sqlite3_bind_int(statement, 3, corePath == nil ? 0 : 1)
            sqlite3_bind_text(statement, 4, kind, -1, transient)
            if let corePath { sqlite3_bind_text(statement, 5, corePath, -1, transient) } else { sqlite3_bind_null(statement, 5) }
            sqlite3_bind_int(statement, 6, fixture == nil ? 1 : 0)
            var count = 0
            if let fixture {
                let bytes = try Data(contentsOf: Self.fixtures.appendingPathComponent(fixture + ".loro"))
                count = bytes.count
                _ = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, 7, $0.baseAddress, Int32($0.count), transient) }
            } else {
                sqlite3_bind_null(statement, 7)
            }
            sqlite3_bind_int(statement, 8, Int32(count))
            if let corePath { sqlite3_bind_text(statement, 9, corePath.lowercased(), -1, transient) } else { sqlite3_bind_null(statement, 9) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure(String(cString: sqlite3_errmsg(db))) }
        }
        try add("00000000000040008000000000009000", "Presentation", "Made Up/Made-Up Song", "presentation")
        try add("00000000000040008000000000009001", "Presentation", "Made Up/Not Yet Here", nil)
        try add("0000000000004000800000000000A001", "LibraryData", nil, "libraries")
        try add("0000000000004000800000000000A002", "PlaylistLibrary", nil, "playlists")
        try add("0000000000004000800000000000A002", "PlaylistLibrary", nil, "libraries", scope: 1) // not the playlists
    }

    private func makeFolderOne() throws {
        let libraries = folderOne.appendingPathComponent("Libraries/Made Up")
        try Self.presentation(name: "Made-Up Song", words: "Made-up words in a folder", group: "Verse 1")
            .serializedData().write(to: libraries.appendingPathComponent("Made-Up Song.pro"))
        try Self.presentation(name: "Another Song", words: "Other made-up words", group: "Chorus")
            .serializedData().write(to: libraries.appendingPathComponent("Another Song.pro"))

        func item(_ name: String, path: String) -> RVData_PlaylistItem {
            var item = RVData_PlaylistItem()
            item.uuid.string = UUID().uuidString
            item.name = name
            var p = RVData_PlaylistItem.Presentation()
            p.documentPath.local.root = .show
            p.documentPath.local.path = path
            p.documentPath.absoluteString = "file:///Users/someone/elsewhere/" + path.replacingOccurrences(of: " ", with: "%20")
            item.itemType = .presentation(p)
            return item
        }
        var header = RVData_PlaylistItem()
        header.uuid.string = UUID().uuidString
        header.name = "Before"
        header.itemType = .header(RVData_PlaylistItem.Header())

        var sunday = RVData_Playlist()
        sunday.uuid.string = "PLAYLIST-SUNDAY"
        sunday.name = "Folder Sunday"
        sunday.type = .playlist
        var items = RVData_Playlist.PlaylistItems()
        items.items = [
            header,
            item("Another Song", path: "Libraries/Made Up/Another Song.pro"),
            // Its file renamed since: found by the item's name.
            item("Made-Up Song", path: "Libraries/Made Up/An Old Name.pro"),
            item("Gone Altogether", path: "Libraries/Made Up/Gone Altogether.pro"),
        ]
        sunday.childrenType = .items(items)

        var folder = RVData_Playlist()
        folder.uuid.string = "PLAYLIST-FOLDER"
        folder.name = "A Folder"
        folder.type = .group
        var inFolder = RVData_Playlist.PlaylistArray()
        inFolder.playlists = [sunday]
        folder.childrenType = .playlists(inFolder)

        var root = RVData_Playlist()
        root.uuid.string = "PLAYLIST-ROOT"
        root.name = "PLAYLIST"
        root.type = .root
        var top = RVData_Playlist.PlaylistArray()
        top.playlists = [folder]
        root.childrenType = .playlists(top)

        var document = RVData_PlaylistDocument()
        document.type = .presentation
        document.rootNode = root
        try document.serializedData().write(to: folderOne.appendingPathComponent("Playlists/Library"))
    }

    /// A made-up presentation of one group and one slide of words.
    static func presentation(name: String, words: String, group: String) -> RVData_Presentation {
        var p = RVData_Presentation()
        p.name = name
        p.uuid.string = UUID().uuidString
        var cue = RVData_Cue()
        cue.uuid.string = UUID().uuidString
        cue.isEnabled = true
        var action = RVData_Action()
        action.type = .presentationSlide
        action.isEnabled = true
        var slide = RVData_PresentationSlide()
        slide.baseSlide.size.width = 1920
        slide.baseSlide.size.height = 1080
        var element = RVData_Slide.Element()
        element.element.bounds.origin.x = 160
        element.element.bounds.origin.y = 140
        element.element.bounds.size.width = 1600
        element.element.bounds.size.height = 800
        element.element.opacity = 1
        element.element.text.rtfData = Data(("{\\rtf1\\ansi{\\fonttbl\\f0\\fswiss Helvetica;}\\f0\\fs160 " + words + "}").utf8)
        slide.baseSlide.elements = [element]
        action.slide.slide = .presentation(slide)
        cue.actions = [action]
        p.cues = [cue]
        var g = RVData_Presentation.CueGroup()
        g.group.uuid.string = UUID().uuidString
        g.group.name = group
        g.cueIdentifiers = [cue.uuid]
        p.cueGroups = [g]
        return p
    }

    /// A small picture, drawn here.
    static func picture() -> Data {
        let image = NSImage(size: NSSize(width: 64, height: 36), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw Failure(error.map { String(cString: $0) } ?? "unknown")
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}

extension Data {
    /// Bytes from hexadecimal digits.
    init(hex: String) {
        var bytes: [UInt8] = []
        var chars = Array(hex)
        if chars.count % 2 == 1 { chars.insert("0", at: 0) }
        for k in stride(from: 0, to: chars.count, by: 2) {
            bytes.append(UInt8(String(chars[k ... k + 1]), radix: 16) ?? 0)
        }
        self.init(bytes)
    }
}
