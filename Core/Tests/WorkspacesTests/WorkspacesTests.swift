// Finding ProPresenter's workspaces and reading them, on a made-up Mac (MadeUpMac.swift):
// both kinds, each kind of place they are found, their libraries and playlists, a
// presentation kept in a database made into ProPresenter's message, and the deck it
// becomes. The same against the maintainer's own workspaces, which cannot be in the
// repository, is ConversionTests/RealWorkspacesTests.swift.

import Conversion
import DeckModel
import Foundation
import LoroKit
import ProFormat
import SQLite3
import Testing
import TestSupport
@testable import Workspaces

@Suite(.serialized) struct WorkspacesTests {
    let mac: MadeUpMac
    init() throws { mac = try MadeUpMac() }

    static func id(_ n: Int) -> String { MadeUpMac.id(n) }

    @Test func findsEveryWorkspaceOnce() {
        let found = mac.finder.workspaces()
        #expect(found.map(\.name) == ["Made-Up Cloud", "Folder One", "ProPresenter (Documents)"])
        #expect(found.map(\.kind) == [.database, .folder, .folder])
        #expect(found.map(\.isCloud) == [true, false, false])
        // In use: the cloud one by the registry, Folder One by the settings.
        #expect(found.map(\.isInUse) == [true, true, false])
    }

    @Test func theRegistryIsReadFromItsWAL() throws {
        // All of the registry's rows are in its "-wal" (as on the maintainer's Mac), so
        // the database alone has not even its tables.
        let registry = mac.support.appendingPathComponent("Workspaces/registry-v1.sqlite3")
        var db: OpaquePointer?
        sqlite3_open_v2("file:" + registry.path + "?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &statement, nil)
        sqlite3_step(statement)
        #expect(sqlite3_column_int(statement, 0) == 0)
        sqlite3_finalize(statement)
        sqlite3_close(db)
        // Read through a copy, they are there; and nothing is added beside the original.
        let before = try FileManager.default.contentsOfDirectory(atPath: registry.deletingLastPathComponent().path).sorted()
        let reader = try SQLiteReader(copying: registry)
        #expect(try reader.rows("SELECT display_name FROM workspaces ORDER BY display_name").compactMap { $0["display_name"]?.text } == ["Folder One", "Made-Up Cloud"])
        let after = try FileManager.default.contentsOfDirectory(atPath: registry.deletingLastPathComponent().path).sorted()
        #expect(before == after)
    }

    @Test func aDatabaseWorkspacesLibrariesAndPlaylists() throws {
        let workspace = try #require(mac.finder.workspaces().first { $0.kind == .database })
        let contents = try WorkspaceReader.contents(of: workspace)
        // The libraries in the order the library list has them, the empty one too.
        #expect(contents.libraries.map(\.name) == ["Made Up", "Empty Library"])
        let madeUp = contents.libraries[0].presentations
        #expect(madeUp.map(\.name) == ["Made-Up Song", "Not Yet Here"])
        #expect(madeUp.map(\.isAvailable) == [true, false])

        // ProPresenter's own root left out: its folder, and its empty playlist.
        #expect(contents.playlists.map(\.name) == ["Made-Up Folder", "An Empty Playlist"])
        #expect(contents.playlists[0].isFolder && !contents.playlists[1].isFolder)
        let sunday = try #require(contents.playlists[0].children?.first)
        #expect(sunday.name == "Made-Up Sunday")
        #expect(sunday.entries.map(\.name) == ["Before", "Made-Up Song", "A made-up video", "Not there"])
        #expect(sunday.entries[0].kind == .header)
        #expect(sunday.entries[1].presentation == madeUp[0])
        #expect(sunday.entries[1].arrangement == Self.id(9100))
        #expect(sunday.entries[2].kind == .other)
        #expect(sunday.entries[3].kind == .presentation(nil, arrangement: nil))
    }

    @Test func aDatabasePresentationIsProPresentersMessage() throws {
        let workspace = try #require(mac.finder.workspaces().first { $0.kind == .database })
        let ref = try #require(try WorkspaceReader.contents(of: workspace).libraries.first?.presentations.first)
        guard case .document(let store, let id) = ref.location else { Issue.record("not a document"); return }
        let p = try WorkspaceReader.presentation(store: store, id: id)
        #expect(p.name == "Made-Up Song")
        #expect(p.uuid.string == Self.id(9000))
        // The groups, from the tree: in order, with their slides, colours and the rest.
        #expect(p.cueGroups.map(\.group.name) == ["Verse 1", "Chorus"])
        #expect(p.cueGroups.map { $0.cueIdentifiers.map(\.string) } == [[Self.id(1), Self.id(2)], [Self.id(3)]])
        #expect(p.cueGroups[0].group.uuid.string == Self.id(8001))
        #expect(p.cueGroups[1].group.color.red == 1)
        #expect(p.cueGroups[0].group.hasHotKey) // kept as "hot_key"
        // The slides, from the map of them: in the groups' order, then the one in none.
        #expect(p.cues.map(\.uuid.string) == [1, 2, 3, 4].map(Self.id))
        #expect(p.cues.map(\.name) == ["Verse one, first", "Verse one, second", "Chorus", "In no group"])
        // An arrangement's groups, kept in "group_identifiers_v2".
        #expect(p.arrangements.map(\.name) == ["Chorus first"])
        #expect(p.arrangements[0].groupIdentifiers.map(\.string) == [8002, 8001, 8002].map(Self.id))
        // A slide's words, and its media, whose file is named only on the file.
        let slide = try #require(p.cues[0].actions.first { $0.type == .presentationSlide })
        guard case .presentation(let ps)? = slide.slide.slide else { Issue.record("no slide"); return }
        #expect(String(decoding: ps.baseSlide.elements[0].element.text.rtfData, as: UTF8.self).contains("Made-up words, verse one"))
        #expect(ps.baseSlide.elements[0].element.bounds.size.width == 1600)
        let media = try #require(p.cues[0].actions.first { $0.type == .media })
        #expect(!media.media.element.hasURL)
        guard case .image(let image)? = media.media.element.typeProperties else { Issue.record("not a picture"); return }
        #expect(image.file.localURL.local.root == .show)
        #expect(image.file.localURL.local.path == "Media/Assets/Made Up Background.png")
    }

    @Test func aDatabasePresentationBecomesADeck() throws {
        let workspace = try #require(mac.finder.workspaces().first { $0.kind == .database })
        let refs = try #require(try WorkspaceReader.contents(of: workspace).libraries.first?.presentations)
        let options = ConversionOptions()
        // Its own order: each group once.
        let own = try Converter.load(refs[0], options: options)
        #expect(own.deck.slides.map(\.caption) == ["Verse 1 · Made-up words, verse one", "Verse 1 · More made-up words", "Chorus · A made-up chorus"])
        // Its picture, found in the workspace's own Media, and kept on the next slides.
        let background = try #require(own.deck.slides[0].background)
        #expect(background.media.source == .file(workspace.folder.appendingPathComponent("Media/Assets/Made Up Background.png")))
        #expect(own.deck.slides[2].background?.isCarriedOver == true)
        #expect(own.notes.filter { $0.kind == .missingMedia }.isEmpty)
        // The arrangement the playlist chose for it.
        let arranged = try Converter.load(refs[0], arrangement: Self.id(9100), options: options)
        #expect(arranged.arrangement == "Chorus first")
        #expect(arranged.deck.slides.map(\.caption).map { $0.components(separatedBy: " · ")[0] } == ["Chorus", "Verse 1", "Verse 1", "Chorus"])
        // Not yet on this Mac: said so.
        #expect(throws: WorkspaceError.self) { try Converter.load(refs[1], options: options) }
    }

    @Test func aFolderWorkspacesLibrariesAndPlaylists() throws {
        let workspace = try #require(mac.finder.workspaces().first { $0.name == "Folder One" })
        let contents = try WorkspaceReader.contents(of: workspace)
        #expect(contents.libraries.map(\.name) == ["Made Up"])
        #expect(contents.libraries[0].presentations.map(\.name) == ["Another Song", "Made-Up Song"])
        #expect(contents.playlists.map(\.name) == ["A Folder"])
        let sunday = try #require(contents.playlists.first?.children?.first)
        #expect(sunday.entries.map(\.name) == ["Before", "Another Song", "Made-Up Song", "Gone Altogether"])
        #expect(sunday.entries[1].presentation?.name == "Another Song")
        #expect(sunday.entries[2].presentation?.name == "Made-Up Song") // by the item's name
        #expect(sunday.entries[3].kind == .presentation(nil, arrangement: nil))
        let deck = try Converter.load(try #require(sunday.entries[1].presentation), options: ConversionOptions()).deck
        #expect(deck.slides.map(\.caption) == ["Chorus · Other made-up words"])
    }

    @Test func aStoreChangedIsReadAgain() throws {
        let workspace = try #require(mac.finder.workspaces().first { $0.kind == .database })
        #expect(try WorkspaceReader.contents(of: workspace).libraries[0].presentations.count == 2)
        var db: OpaquePointer?
        sqlite3_open(workspace.store.path, &db)
        sqlite3_exec(db, "UPDATE workspace_streams SET core_path = 'Elsewhere/Made-Up Song' WHERE kind = 'Presentation' AND availability = 0", nil, nil, nil)
        sqlite3_close(db)
        // (A store's copy is kept while the store's size and date are as they were.)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: workspace.store.path)
        let names = try WorkspaceReader.contents(of: workspace).libraries.map(\.name)
        #expect(names.contains("Elsewhere"))
    }
}

/// The rules by which a Loro tree is made into a message (LoroMessage.swift).
struct LoroMessageTests {
    @Test func idsChoicesNamesAndLists() throws {
        let tree: LoroValue = .map([
            "uuid": .string("ID-ONE"),
            "name": .string("A made-up name"),
            "made_up_field_of_a_later_version": .bool(true),
            "SlideShow": .map(["__tag": .string("slide_show_duration"), "slide_show_duration": .double(20)]),
            "background": .map(["is_enabled": .bool(true), "Fill": .map(["__tag": .null])]),
            "selected_arrangement": .null,
            "arrangements": .list([
                .map(["uuid": .string("A1"), "name": .string("one"), "group_identifiers": .list([]), "group_identifiers_v2": .list([.string("G1"), .string("G2")])]),
            ]),
            "cue_groups": .list([.map(["group": .map(["name": .string("G"), "hot_key": .map(["code": .int(3)])]), "cue_identifiers": .list([.string("C2")])])]),
            "cues": .map([
                "C2": .map(["uuid": .string("C2"), "isEnabled": .bool(true)]),
                "C1": .map(["uuid": .string("C1"), "isEnabled": .bool(false)]),
            ]),
        ])
        var builder = LoroMessage()
        let p = try builder.message(RVData_Presentation.self, from: tree)
        #expect(p.uuid.string == "ID-ONE")
        #expect(p.name == "A made-up name")
        #expect(p.slideShowDuration == 20)
        #expect(p.background.isEnabled && p.background.fill == nil)
        #expect(!p.hasSelectedArrangement)
        #expect(p.arrangements[0].groupIdentifiers.map(\.string) == ["G1", "G2"])
        #expect(p.cueGroups[0].group.hotKey.code.rawValue == 3)
        // A list kept by id, its items in the order of their ids.
        #expect(p.cues.map(\.uuid.string) == ["C1", "C2"])
        #expect(builder.unknownFields == ["rv.data.Presentation.made_up_field_of_a_later_version": 1])
    }

    @Test func aChoiceWithoutItsTag() throws {
        // (Seen once in a library list: the one field there is, with no "__tag".)
        let tree: LoroValue = .map([
            "name": .string("Made-Up Playlist"),
            "smart_directory_path": .map(["RelativeFilePath": .map(["__tag": .string("local"), "local": .map(["root": .int(10), "path": .string("Media")])])]),
            "ChildrenType": .map(["items": .map(["items": .list([.map(["name": .string("An item"), "uuid": .string("I1")])])])]),
        ])
        var builder = LoroMessage()
        let playlist = try builder.message(RVData_Playlist.self, from: tree)
        #expect(playlist.smartDirectoryPath.local.root == .show)
        guard case .items(let items)? = playlist.childrenType else { Issue.record("no items"); return }
        #expect(items.items.map(\.name) == ["An item"])
        #expect(items.items.first?.uuid.string == "I1")
    }
}

extension LoroMessageTests {
    @Test func aPartOfAnotherShapeIsPassedOver() throws {
        let tree: LoroValue = .map([
            "name": .string("Kept"),
            "content_destination": .string("not a number"),
            "background": .list([.int(1)]),
        ])
        var builder = LoroMessage()
        let p = try builder.message(RVData_Presentation.self, from: tree)
        #expect(p.name == "Kept")
        #expect(!p.hasBackground)
        #expect(builder.unknownFields.keys.sorted() == ["rv.data.Presentation.background (not as expected)", "rv.data.Presentation.content_destination (not as expected)"])
    }
}
