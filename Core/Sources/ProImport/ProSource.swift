// ProSource: a presentation opened from a .pro file or a .probundle, and the means of
// finding the media its slides and cues name.
//
// A .pro names media by the whole path it had on the Mac that made it
// ("file:///Users/media/Library/…/Media/Assets/Background.png"), and also by a root
// and a path under it (ROOT_SHOW and "Media/Assets/Background.png"). Neither need be
// true on this Mac. So each is looked for in turn:
//
// From a .probundle (KNOWN, from the maintainer's bundles): the bundle's entries are
// named by that whole path (ZipReader says more), so an entry is found by the URL's
// path. Failing that, by its file name alone, as long as only one entry has it.
//
// From a .pro on its own: the path as given, if it is there; then a file of the same
// name beside the .pro, or in a folder beside it (where someone who copied a
// presentation and its pictures together would have put them); then under the places
// ProPresenter keeps media on this Mac (A GUESS at where ROOT_SHOW points:
// ~/Documents/ProPresenter, and each folder workspace under ~/Library/Application
// Support/RenewedVision/ProPresenter/UserWorkspaces). What is found nowhere is
// reported as missing; the rest of the slide is converted all the same.

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
    let url: URL
    let presentation: RVData_Presentation
    private let bundle: ZipReader?
    private let bundleEntriesByName: [String: [ZipEntry]]

    init(url: URL) throws {
        self.url = url
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
        let given = media.url
        let fileURL = URL(string: given.absoluteString).flatMap { $0.isFileURL ? $0 : nil }
        let path = fileURL?.path ?? given.local.path
        let name = (path as NSString).lastPathComponent

        if let bundle {
            if let entry = bundle.entry(path) ?? bundle.entry(String(path.drop(while: { $0 == "/" }))) {
                return .zipEntry(archive: url, path: entry.path)
            }
            if let entries = bundleEntriesByName[name.lowercased()], entries.count == 1 {
                return .zipEntry(archive: url, path: entries[0].path)
            }
        }

        let fm = FileManager.default
        if fileURL != nil, fm.isReadableFile(atPath: path) { return .file(URL(fileURLWithPath: path)) }

        if !name.isEmpty {
            let folder = url.deletingLastPathComponent()
            if let found = Self.find(name, in: folder, depth: 2) { return .file(found) }
            if !given.local.path.isEmpty {
                for root in Self.proPresenterRoots() {
                    let candidate = root.appendingPathComponent(given.local.path)
                    if fm.isReadableFile(atPath: candidate.path) { return .file(candidate) }
                }
            }
        }
        return .missing(path.isEmpty ? name : path)
    }

    /// The file name a media item goes by.
    static func fileName(of media: RVData_Media) -> String {
        let absolute = media.url.absoluteString
        if let u = URL(string: absolute), !u.lastPathComponent.isEmpty { return u.lastPathComponent }
        return (media.url.local.path as NSString).lastPathComponent
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

    /// The folders ProPresenter may have meant by ROOT_SHOW on this Mac.
    private static func proPresenterRoots() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots = [home.appendingPathComponent("Documents/ProPresenter")]
        let workspaces = home.appendingPathComponent("Library/Application Support/RenewedVision/ProPresenter/UserWorkspaces")
        if let items = try? fm.contentsOfDirectory(at: workspaces, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            roots.append(contentsOf: items)
        }
        return roots
    }
}
