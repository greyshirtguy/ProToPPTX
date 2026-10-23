// ProSource: a presentation opened from a .pro file or a .probundle, or handed over
// from a workspace kept in a database, and the means of finding the media its slides
// and cues name.
//
// A .pro names media by the whole path it had on the Mac that made it
// ("file:///Users/media/Library/…/Media/Assets/Background.png"), and also by a root
// and a path under it (ROOT_SHOW and "Media/Assets/Background.png"). Neither need be
// true on this Mac. KNOWN (2026-10): a presentation from a database workspace has no
// URL on the media itself, only on the media's file (its image's or video's
// `file.local_url`), and that names the media in the workspace (ROOT_SHOW,
// "Media/Assets/…"), which is the workspace's folder. So each is looked for in turn:
//
// In the workspace the presentation is in, if it is in one: the path "in the
// workspace", under the workspace's folder; or, for media named only by its whole path
// on another Mac (KNOWN: 4 files in the maintainer's workspaces, 2026-10), what follows
// "Media/" in that path, under the workspace's folder; or a file of its name in the
// workspace's Media folder.
//
// From a .probundle (KNOWN, from the maintainer's bundles): the bundle's entries are
// named by that whole path (ZipReader says more), so an entry is found by the URL's
// path. Failing that, by its file name alone, as long as only one entry has it.
//
// From a .pro on its own: the path as given, if it is there; then a file of the same
// name beside the .pro, or in a folder beside it (where someone who copied a
// presentation and its pictures together would have put them); then under the places
// ProPresenter keeps media on this Mac (A GUESS at where ROOT_SHOW points:
// ~/Documents/ProPresenter, and each workspace under ~/Library/Application
// Support/RenewedVision/ProPresenter, in UserWorkspaces and in Workspaces), by the path
// "in the workspace", then by what follows "Media/" in the whole path. What is found
// nowhere is reported as missing; the rest of the slide is converted all the same.

import DeckModel
import Foundation
import ProFormat
import SwiftProtobuf
import ZipKit

public enum ProSourceError: Error, CustomStringConvertible {
    case unreadable(URL, String)
    case noPresentationInBundle(URL)
    case notAPresentation(URL)

    public var description: String {
        switch self {
        case .unreadable(let url, let why): return "\(url.lastPathComponent) could not be read: \(why)"
        case .noPresentationInBundle(let url): return "\(url.lastPathComponent) has no .pro presentation in it."
        case .notAPresentation(let url): return "\(url.lastPathComponent) is not a ProPresenter presentation this app can read."
        }
    }
}

struct ProSource {
    /// The file it was read from, if it was read from one.
    let url: URL?
    /// What to call it, if the presentation has no name of its own.
    let name: String
    let presentation: RVData_Presentation
    /// The folder of the workspace it is in, if it is in one.
    let workspaceFolder: URL?
    private let bundle: ZipReader?
    private let bundleEntriesByName: [String: [ZipEntry]]

    /// A presentation ProPresenter keeps other than as a file (a database workspace's).
    init(presentation: RVData_Presentation, name: String, workspaceFolder: URL?) {
        self.url = nil
        self.name = name
        self.presentation = presentation
        self.workspaceFolder = workspaceFolder
        bundle = nil
        bundleEntriesByName = [:]
    }

    init(url: URL, workspaceFolder: URL? = nil) throws {
        self.url = url
        self.name = url.deletingPathExtension().lastPathComponent
        self.workspaceFolder = workspaceFolder
        let data: Data
        if url.pathExtension.lowercased() == "probundle" {
            let zip: ZipReader
            do { zip = try ZipReader(url: url) } catch { throw ProSourceError.unreadable(url, "\(error)") }
            // The presentation is the .pro entry; ProPresenter names it without a folder.
            let pros = zip.entries.filter { $0.path.lowercased().hasSuffix(".pro") && !$0.isDirectory }
            guard let pro = pros.first(where: { !$0.path.contains("/") }) ?? pros.first else {
                throw ProSourceError.noPresentationInBundle(url)
            }
            do { data = try zip.contents(of: pro) } catch { throw ProSourceError.unreadable(url, "\(error)") }
            bundle = zip
            bundleEntriesByName = Dictionary(grouping: zip.entries.filter { !$0.isDirectory }, by: { $0.fileName.lowercased() })
        } else {
            do { data = try Data(contentsOf: url) } catch { throw ProSourceError.unreadable(url, error.localizedDescription) }
            bundle = nil
            bundleEntriesByName = [:]
        }
        do {
            presentation = try RVData_Presentation(serializedBytes: data)
        } catch {
            throw ProSourceError.notAPresentation(url)
        }
    }

    /// Where the media a presentation names is to be had on this Mac.
    func locate(_ media: RVData_Media) -> MediaSource {
        let given = Self.url(of: media)
        let fileURL = URL(string: given.absoluteString).flatMap { $0.isFileURL ? $0 : nil }
        let path = fileURL?.path ?? given.local.path
        let name = (path as NSString).lastPathComponent
        let fm = FileManager.default

        if let workspaceFolder {
            if given.local.root == .show, !given.local.path.isEmpty {
                let candidate = workspaceFolder.appendingPathComponent(given.local.path)
                if fm.isReadableFile(atPath: candidate.path) { return .file(candidate) }
            }
            // Named only by the whole path it had on another Mac: what follows its
            // workspace's "Media/" there, under this one's; then by its name, anywhere
            // in this one's Media.
            if let tail = Self.mediaTail(path) {
                let candidate = workspaceFolder.appendingPathComponent(tail)
                if fm.isReadableFile(atPath: candidate.path) { return .file(candidate) }
            }
            if !name.isEmpty, let found = Self.find(name, in: workspaceFolder.appendingPathComponent("Media"), depth: 2) {
                return .file(found)
            }
        }

        if let bundle, let url {
            if let entry = bundle.entry(path) ?? bundle.entry(String(path.drop(while: { $0 == "/" }))) {
                return .zipEntry(archive: url, path: entry.path)
            }
            if let entries = bundleEntriesByName[name.lowercased()], entries.count == 1 {
                return .zipEntry(archive: url, path: entries[0].path)
            }
        }

        if fileURL != nil, fm.isReadableFile(atPath: path) { return .file(URL(fileURLWithPath: path)) }

        if !name.isEmpty {
            if let folder = url?.deletingLastPathComponent(), let found = Self.find(name, in: folder, depth: 2) { return .file(found) }
            for relative in [given.local.path, Self.mediaTail(path) ?? ""] where !relative.isEmpty {
                for root in Self.proPresenterRoots() {
                    let candidate = root.appendingPathComponent(relative)
                    if fm.isReadableFile(atPath: candidate.path) { return .file(candidate) }
                }
            }
        }
        return .missing(path.isEmpty ? name : path)
    }

    /// The file name a media item goes by.
    static func fileName(of media: RVData_Media) -> String {
        let given = url(of: media)
        if let u = URL(string: given.absoluteString), !u.lastPathComponent.isEmpty { return u.lastPathComponent }
        return (given.local.path as NSString).lastPathComponent
    }

    /// What kind of media an item is: what it says, or, if it says nothing, what its
    /// file's ending says. Nil for what is not a file to show (live video, a web page),
    /// or a file whose ending says nothing known.
    ///
    /// KNOWN (2026-10): a media action in one of the maintainer's presentations has a
    /// video with no type properties at all; ProPresenter 22, copying it into a
    /// database workspace, made it a video. That ProPresenter plays such a file as its
    /// ending says is A GUESS from that.
    static func kind(of media: RVData_Media) -> Media.Kind? {
        switch media.typeProperties {
        case .image?: return .image
        case .video?: return .video
        case .audio?: return .audio
        case nil: break
        default: return nil
        }
        let ending = (fileName(of: media) as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "heic", "heif", "webp", "psd", "pdf"].contains(ending) { return .image }
        if ["mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "mts", "m2ts", "wmv", "flv", "3gp", "mxf"].contains(ending) { return .video }
        if ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "ogg", "wma"].contains(ending) { return .audio }
        return nil
    }

    /// Where a media item says its file is: its own URL, or else its file's.
    static func url(of media: RVData_Media) -> RVData_URL {
        if media.hasURL, !media.url.absoluteString.isEmpty || !media.url.local.path.isEmpty { return media.url }
        switch media.typeProperties {
        case .image(let p)?: return p.file.localURL
        case .video(let p)?: return p.file.localURL
        case .audio(let p)?: return p.file.localURL
        default: return media.url
        }
    }

    /// A file of this name in the folder, or in a folder inside it, to the given depth.
    private static func find(_ name: String, in folder: URL, depth: Int) -> URL? {
        let fm = FileManager.default
        let direct = folder.appendingPathComponent(name)
        if fm.isReadableFile(atPath: direct.path) { return direct }
        guard depth > 0, let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if item.pathExtension.lowercased() == "app" { continue }
            if let found = find(name, in: item, depth: depth - 1) { return found }
        }
        return nil
    }

    /// "Media/…" and what follows, of a whole path that goes through a ProPresenter
    /// folder's Media ("/Users/someone/…/ProPresenter/Media/Assets/Background.png").
    static func mediaTail(_ path: String) -> String? {
        guard let range = path.range(of: "/Media/", options: .backwards) else { return nil }
        let tail = String(path[path.index(after: range.lowerBound)...])
        return tail.count > "Media/".count ? tail : nil
    }

    /// The folders ProPresenter may have meant by ROOT_SHOW on this Mac.
    private static func proPresenterRoots() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots = [home.appendingPathComponent("Documents/ProPresenter")]
        let support = home.appendingPathComponent("Library/Application Support/RenewedVision/ProPresenter")
        for kind in ["UserWorkspaces", "Workspaces"] {
            if let items = try? fm.contentsOfDirectory(at: support.appendingPathComponent(kind), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                roots.append(contentsOf: items)
            }
        }
        return roots
    }
}
