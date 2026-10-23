// Workspace: a place where ProPresenter keeps a library of presentations and its
// playlists, and what is in one.
//
// There are two kinds (docs/WORKSPACES.md has what was found of each):
//
//   - A FOLDER: `Libraries/<library>/<name>.pro`, and the playlists in one file,
//     `Playlists/Library`. Every ProPresenter 7 up to 21 keeps its workspaces so, and
//     the versions after can still open one.
//   - A DATABASE: one SQLite file, `DocumentStore/workspace-v1.sqlite3`, with every
//     document (each presentation, the playlists, the list of libraries) a Loro
//     document in it. The versions after 21 keep their workspaces so, and copy a
//     folder workspace into one when they first open it. One kept in step with
//     ProPresenter's cloud is one of these.
//
// Both are read, never written (AGENTS.md). Each is listed as libraries, each with its
// presentations, and as playlists, in folders, each with its items; a presentation in
// either is a PresentationRef, which the conversion reads the same way whichever kind
// it is in.

import Foundation

public struct Workspace: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case folder
        case database
    }

    public var kind: Kind
    public var name: String
    /// The workspace's own folder. Media named by a path "in the workspace" is under it.
    public var folder: URL
    /// Whether it is kept in step with ProPresenter's cloud.
    public var isCloud: Bool
    /// Whether ProPresenter's own records say it is the one in use. (Two versions
    /// installed side by side can each be using a different one.)
    public var isInUse: Bool

    public var id: String { folder.standardizedFileURL.resolvingSymlinksInPath().path }

    public init(kind: Kind, name: String, folder: URL, isCloud: Bool = false, isInUse: Bool = false) {
        self.kind = kind
        self.name = name
        self.folder = folder
        self.isCloud = isCloud
        self.isInUse = isInUse
    }

    /// The database a database workspace keeps its documents in.
    var store: URL { folder.appendingPathComponent("DocumentStore/workspace-v1.sqlite3") }
}

/// What a workspace has: its libraries, and its playlists.
public struct WorkspaceContents: Sendable {
    public var libraries: [Library]
    /// The playlists and folders of playlists at the top (ProPresenter's own root, which
    /// it does not show, left out).
    public var playlists: [PlaylistNode]

    public init(libraries: [Library], playlists: [PlaylistNode]) {
        self.libraries = libraries
        self.playlists = playlists
    }
}

public struct Library: Identifiable, Hashable, Sendable {
    public var name: String
    public var presentations: [PresentationRef]
    public var id: String { name }

    public init(name: String, presentations: [PresentationRef]) {
        self.name = name
        self.presentations = presentations
    }
}

/// A presentation in a workspace, or a file of one anywhere.
public struct PresentationRef: Identifiable, Hashable, Sendable {
    public enum Location: Hashable, Sendable {
        /// A .pro or .probundle file.
        case file(URL)
        /// A document in a database workspace's store, by its id (hexadecimal).
        case document(store: URL, id: String)
    }

    public var name: String
    public var location: Location
    /// The workspace it is in, whose folder media named "in the workspace" is under.
    public var workspaceFolder: URL?
    /// False for a document a cloud workspace knows of but has not yet brought to this
    /// Mac.
    public var isAvailable: Bool

    public var id: String {
        switch location {
        case .file(let url): return url.standardizedFileURL.path
        case .document(let store, let id): return store.standardizedFileURL.path + "#" + id
        }
    }

    public init(name: String, location: Location, workspaceFolder: URL? = nil, isAvailable: Bool = true) {
        self.name = name
        self.location = location
        self.workspaceFolder = workspaceFolder
        self.isAvailable = isAvailable
    }

    /// A presentation file on its own.
    public static func file(_ url: URL) -> PresentationRef {
        PresentationRef(name: url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespaces), location: .file(url))
    }

    /// The file, if it is one.
    public var fileURL: URL? {
        if case .file(let url) = location { return url }
        return nil
    }
}

/// A folder of playlists, or a playlist.
public struct PlaylistNode: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// A folder's playlists and folders; nil for a playlist. (Nil, not empty, so that a
    /// list of them can be shown as an outline that knows a playlist has none.)
    public var children: [PlaylistNode]?
    /// A playlist's items, in order; empty for a folder.
    public var entries: [PlaylistEntry]

    public var isFolder: Bool { children != nil }

    public init(id: String, name: String, children: [PlaylistNode]? = nil, entries: [PlaylistEntry] = []) {
        self.id = id
        self.name = name
        self.children = children
        self.entries = entries
    }

    /// Every playlist in it, folders opened, in order.
    public var allPlaylists: [PlaylistNode] {
        guard let children else { return [self] }
        return children.flatMap(\.allPlaylists)
    }
}

/// One item of a playlist.
public struct PlaylistEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A heading between items.
        case header
        /// A presentation (nil if it could not be found), and the arrangement the item
        /// chose for it, by id, if it chose one.
        case presentation(PresentationRef?, arrangement: String?)
        /// Media, a cue, a placeholder: nothing to convert.
        case other
    }

    public var id: String
    public var name: String
    public var kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var presentation: PresentationRef? {
        if case .presentation(let ref, _) = kind { return ref }
        return nil
    }

    public var arrangement: String? {
        if case .presentation(_, let arrangement) = kind { return arrangement }
        return nil
    }
}

public enum WorkspaceError: Error, CustomStringConvertible {
    case notFound(String)
    case notAvailable(String)
    case unreadable(String, String)

    public var description: String {
        switch self {
        case .notFound(let what): return "\(what) is not there any more."
        case .notAvailable(let name): return "\(name) is in the cloud workspace but not yet on this Mac. Open the workspace in ProPresenter to bring it down."
        case .unreadable(let what, let why): return "\(what) could not be read: \(why)"
        }
    }
}
