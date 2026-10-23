// FolderWorkspace: a workspace kept as a folder of files (ProPresenter 7 up to 21).
//
// KNOWN (Pro7ChordEditor's spec/06, and the maintainer's workspaces, 2026-10): each
// folder in `Libraries` is a library, by its name, and each `.pro` file directly in
// one is a presentation, which ProPresenter shows by its file name. The playlists are
// one PlaylistDocument, `Playlists/Library`: a root that is not shown, holding folders
// (which hold playlists and folders) and playlists (which hold items). A presentation
// item names its file by a URL, a path "in the workspace" (ROOT_SHOW) and the whole
// path it had on the Mac that saved it.
//
// An item whose file is not where its URL says is looked for in the libraries by its
// file name, then by the item's own name. (A GUESS at what ProPresenter does. Seen once
// on the maintainer's Mac: an item naming a file whose name starts with a dot, where the
// library had the presentation under another name, which the item's name did not match
// either; it is shown as not found.)

import Foundation
import ProFormat
import SwiftProtobuf

enum FolderWorkspace {
    static func contents(of workspace: Workspace) throws -> WorkspaceContents {
        let fm = FileManager.default
        let librariesFolder = workspace.folder.appendingPathComponent("Libraries", isDirectory: true)
        var libraries: [Library] = []
        let folders = (try? fm.contentsOfDirectory(at: librariesFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let presentations = files
                .filter { $0.pathExtension.lowercased() == "pro" }
                .map { url -> PresentationRef in
                    var ref = PresentationRef.file(url)
                    ref.workspaceFolder = workspace.folder
                    return ref
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            libraries.append(Library(name: folder.lastPathComponent, presentations: presentations))
        }
        libraries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var playlists: [PlaylistNode] = []
        let playlistFile = workspace.folder.appendingPathComponent("Playlists/Library")
        if fm.fileExists(atPath: playlistFile.path) {
            do {
                let document = try RVData_PlaylistDocument(serializedBytes: Data(contentsOf: playlistFile))
                let finder = Finder(workspace: workspace, libraries: libraries)
                playlists = document.rootNode.childNodes.map { finder.node($0) }
            } catch {
                throw WorkspaceError.unreadable("The playlists of \(workspace.name)", "\(error)")
            }
        }
        return WorkspaceContents(libraries: libraries, playlists: playlists)
    }

    /// Finds the presentations playlist items name.
    private struct Finder {
        let workspace: Workspace
        let byPath: [String: PresentationRef]
        let byName: [String: PresentationRef]

        init(workspace: Workspace, libraries: [Library]) {
            self.workspace = workspace
            var byPath: [String: PresentationRef] = [:], byName: [String: PresentationRef] = [:]
            for library in libraries {
                for ref in library.presentations {
                    if let url = ref.fileURL { byPath[url.standardizedFileURL.path.lowercased()] = ref }
                    byName[ref.name.lowercased()] = byName[ref.name.lowercased()] ?? ref
                }
            }
            self.byPath = byPath
            self.byName = byName
        }

        func node(_ playlist: RVData_Playlist) -> PlaylistNode {
            let id = playlist.uuid.string
            if case .items(let items)? = playlist.childrenType {
                return PlaylistNode(id: id, name: playlist.name, entries: items.items.map(entry))
            }
            if playlist.type == .playlist {
                return PlaylistNode(id: id, name: playlist.name, entries: [])
            }
            return PlaylistNode(id: id, name: playlist.name, children: playlist.childNodes.map(node))
        }

        func entry(_ item: RVData_PlaylistItem) -> PlaylistEntry {
            let id = item.uuid.string
            switch item.itemType {
            case .header?:
                return PlaylistEntry(id: id, name: item.name, kind: .header)
            case .presentation(let p)?:
                let arrangement = p.hasArrangement && !p.arrangement.string.isEmpty ? p.arrangement.string : nil
                return PlaylistEntry(id: id, name: item.name, kind: .presentation(find(p.documentPath, itemName: item.name), arrangement: arrangement))
            default:
                return PlaylistEntry(id: id, name: item.name, kind: .other)
            }
        }

        func find(_ url: RVData_URL, itemName: String) -> PresentationRef? {
            var candidates: [URL] = []
            if url.local.root == .show, !url.local.path.isEmpty {
                candidates.append(workspace.folder.appendingPathComponent(url.local.path))
            }
            if let absolute = URL(string: url.absoluteString), absolute.isFileURL {
                candidates.append(absolute)
            }
            for candidate in candidates {
                if let ref = byPath[candidate.standardizedFileURL.path.lowercased()] { return ref }
            }
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                var ref = PresentationRef.file(candidate)
                ref.workspaceFolder = workspace.folder
                return ref
            }
            let fileName = (url.local.path.isEmpty ? (URL(string: url.absoluteString)?.lastPathComponent ?? "") : (url.local.path as NSString).lastPathComponent)
            let stem = (fileName as NSString).deletingPathExtension.lowercased()
            return byName[stem] ?? byName[itemName.lowercased()]
        }
    }
}

extension RVData_Playlist {
    /// A folder's playlists and folders.
    var childNodes: [RVData_Playlist] {
        if case .playlists(let array)? = childrenType { return array.playlists }
        return children
    }
}
