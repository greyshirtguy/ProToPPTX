// The maintainer's own ProPresenter workspaces, read as the window reads them, when asked
// for (PROTOPPTX_REAL_WORKSPACES=1). They are real church services: what is printed is
// numbers, never their words or names (AGENTS.md, "The person's files").
//
// The check that matters: a version of ProPresenter after 21 copies a folder workspace
// into a database the first time it opens it, so the same presentation is on this Mac
// twice, once in each kind. Each presentation of each database workspace is converted,
// and so is the one with its id in a folder workspace, and the two decks must be the
// same, but for where their media files are (each workspace has its own copy) and the
// presentation's own name (which that version sets to the file's name).

import Conversion
import DeckModel
import Foundation
import ProFormat
import Testing
import TestSupport
import Workspaces
import ZipKit

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PROTOPPTX_REAL_WORKSPACES"] != nil))
struct RealWorkspacesTests {
    @Test func everyWorkspaceIsListedAndRead() throws {
        let workspaces = WorkspaceFinder.onThisMac().workspaces()
        #expect(!workspaces.isEmpty)
        for (k, workspace) in workspaces.enumerated() {
            let contents = try WorkspaceReader.contents(of: workspace)
            let presentations = contents.libraries.reduce(0) { $0 + $1.presentations.count }
            let playlists = contents.playlists.flatMap(\.allPlaylists)
            let entries = playlists.flatMap(\.entries)
            let named = entries.filter { if case .presentation = $0.kind { return true } else { return false } }
            let found = named.filter { $0.presentation != nil }
            print("workspace \(k + 1): \(workspace.kind.rawValue)\(workspace.isCloud ? ", cloud" : "")\(workspace.isInUse ? ", in use" : ""): \(contents.libraries.count) libraries, \(presentations) presentations, \(playlists.count) playlists, \(found.count) of \(named.count) presentation items found")
        }
    }

    @Test func databaseDecksMatchTheirFolderTwins() throws {
        let workspaces = WorkspaceFinder.onThisMac().workspaces()
        // Every presentation of every folder workspace, by its id.
        var twins: [String: PresentationRef] = [:]
        for workspace in workspaces where workspace.kind == .folder {
            guard let contents = try? WorkspaceReader.contents(of: workspace) else { continue }
            for ref in contents.libraries.flatMap(\.presentations) {
                guard let url = ref.fileURL, let data = try? Data(contentsOf: url),
                      let p = try? RVData_Presentation(serializedBytes: data) else { continue }
                twins[p.uuid.string.uppercased()] = twins[p.uuid.string.uppercased()] ?? ref
            }
        }
        let options = ConversionOptions()
        for workspace in workspaces where workspace.kind == .database {
            let contents = try WorkspaceReader.contents(of: workspace)
            var same = 0, differ = 0, noTwin = 0, slides = 0, mediaFound = 0, mediaMissing = 0, twinMissing = 0
            var missingNames = Set<String>()
            for ref in contents.libraries.flatMap(\.presentations) where ref.isAvailable {
                let loaded = try Converter.load(ref, options: options)
                slides += loaded.deck.slides.count
                for media in allMedia(loaded.deck) {
                    if case .missing(let path) = media.source { mediaMissing += 1; missingNames.insert(path) } else { mediaFound += 1 }
                }
                guard case .document(let store, let id) = ref.location else { continue }
                let message = try WorkspaceReader.presentation(store: store, id: id)
                guard let twin = twins[message.uuid.string.uppercased()] else {
                    noTwin += 1
                    continue
                }
                let theirs = try Converter.load(twin, options: options)
                for media in allMedia(theirs.deck) {
                    if case .missing = media.source { twinMissing += 1 }
                }
                if normalized(loaded.deck) == normalized(theirs.deck) {
                    same += 1
                } else {
                    differ += 1
                    let a = normalized(loaded.deck), b = normalized(theirs.deck)
                    let firstDifferent = Array(zip(a.slides, b.slides)).firstIndex { $0.0 != $0.1 }
                    print("differs: \(a.slides.count) and \(b.slides.count) slides, first different \(firstDifferent.map { "\($0 + 1)" } ?? "none")")
                    if let k = firstDifferent {
                        let x = a.slides[k], y = b.slides[k]
                        print("  background same: \(x.background == y.background), colour same: \(x.backgroundColor == y.backgroundColor), items \(x.items.count) / \(y.items.count), notes same: \(x.notes == y.notes), caption same: \(x.caption == y.caption)")
                        if let bx = x.background, let by = y.background {
                            print("  background: kind \(bx.media.kind)/\(by.media.kind), name same \(bx.media.fileName == by.media.fileName), names \(bx.media.fileName.count)/\(by.media.fileName.count) letters, scale \(bx.scale)/\(by.scale), carried \(bx.isCarriedOver)/\(by.isCarriedOver), size \(String(describing: bx.media.naturalSize))/\(String(describing: by.media.naturalSize)), duration \(String(describing: bx.media.duration))/\(String(describing: by.media.duration))")
                            print("  sources: \(bx.media.source)".replacingOccurrences(of: NSHomeDirectory(), with: "~").count, "letters")
                        } else {
                            print("  background present: \(x.background != nil)/\(y.background != nil)")
                        }
                        for (i, (p, q)) in zip(x.items, y.items).enumerated() where p != q {
                            if case .shape(let s1) = p, case .shape(let s2) = q {
                                print("  item \(i): shape; frame \(s1.frame == s2.frame), fill \(s1.fill == s2.fill), line \(s1.line == s2.line), text \(s1.text == s2.text), text paragraphs \(s1.text?.paragraphs.count ?? -1)/\(s2.text?.paragraphs.count ?? -1), autofit same \(s1.text?.autofit == s2.text?.autofit), insets same \(s1.text?.insets == s2.text?.insets)")
                            } else {
                                print("  item \(i): \(p) differs")
                            }
                        }
                    }
                }
            }
            print("database workspace: \(same) decks the same as their folder twins, \(differ) not, \(noTwin) with no twin; \(slides) slides; media \(mediaFound) found, \(mediaMissing) missing (\(twinMissing) missing from the folder twins)")
            if let out = ProcessInfo.processInfo.environment["PROTOPPTX_MISSING_OUT"] {
                try missingNames.sorted().joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
            print("\(missingNames.count) different files missing")
            #expect(differ == 0)
        }
    }

    /// Every playlist of every workspace, written out as the window's Export All writes
    /// it (each item with the arrangement it chose), and every part of every deck valid.
    @Test func everyPlaylistIsWrittenValidly() throws {
        let out = try TestFiles.scratchFolder()
        defer { try? FileManager.default.removeItem(at: out) }
        let options = ConversionOptions()
        for (w, workspace) in WorkspaceFinder.onThisMac().workspaces().enumerated() {
            let contents = try WorkspaceReader.contents(of: workspace)
            var decks = 0, slides = 0, arranged = 0
            for playlist in contents.playlists.flatMap(\.allPlaylists) {
                for entry in playlist.entries {
                    guard let ref = entry.presentation, ref.isAvailable else { continue }
                    let loaded = try Converter.load(ref, arrangement: entry.arrangement, options: options)
                    if entry.arrangement != nil, loaded.arrangement != nil { arranged += 1 }
                    let file = out.appendingPathComponent("\(w)-\(decks).pptx")
                    _ = try Converter.write(loaded, to: file, options: options)
                    let zip = try ZipReader(url: file)
                    for part in zip.entries where part.path.hasSuffix(".xml") {
                        let problems = OOXMLLint.problems(in: String(decoding: try zip.contents(of: part), as: UTF8.self))
                        #expect(problems.isEmpty, "workspace \(w + 1), deck \(decks + 1), \(part.path): \(problems.prefix(3))")
                    }
                    decks += 1
                    slides += loaded.deck.slides.count
                }
            }
            print("workspace \(w + 1): \(decks) playlist items written, \(slides) slides, \(arranged) in the arrangement their item chose")
        }
    }

    private func allMedia(_ deck: Deck) -> [Media] {
        var result: [Media] = []
        for slide in deck.slides {
            if let b = slide.background { result.append(b.media) }
            for item in slide.items {
                switch item {
                case .picture(let p): result.append(p.media)
                case .video(let v): result.append(v.media)
                case .shape(let s): if case .picture(let m, _)? = s.fill { result.append(m) }
                }
            }
        }
        return result
    }

    /// The deck with each media file known by its name alone, and no title.
    private func normalized(_ deck: Deck) -> Deck {
        func n(_ media: Media) -> Media {
            var m = media
            m.source = .missing(m.fileName)
            m.still = nil
            return m
        }
        var d = deck
        d.title = ""
        for k in d.slides.indices {
            if d.slides[k].background != nil { d.slides[k].background!.media = n(d.slides[k].background!.media) }
            d.slides[k].items = d.slides[k].items.map { item in
                switch item {
                case .picture(var p): p.media = n(p.media); return .picture(p)
                case .video(var v): v.media = n(v.media); return .video(v)
                case .shape(var s):
                    if case .picture(let m, let scale)? = s.fill { s.fill = .picture(n(m), scale) }
                    return .shape(s)
                }
            }
        }
        return d
    }
}
