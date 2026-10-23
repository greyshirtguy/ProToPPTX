// WorkspaceFinder: every ProPresenter workspace on this Mac, of either kind.
//
// ProPresenter keeps its own things in `~/Library/Application Support/RenewedVision/
// ProPresenter` and its settings under `com.renewedvision.propresenter`, which every
// version installed shares. What says where the workspaces are, by version (KNOWN of
// the maintainer's Mac, 2026-10, with 21.4 and the 22.7 beta installed side by side,
// unless it says otherwise):
//
//   - After 21: a registry, `Workspaces/registry-v1.sqlite3` in that folder. Its table
//     `workspaces` has a row for each workspace those versions know (`local_uuid`,
//     `root_path` its folder, `display_name`, `cloud_uuid` for one kept in step with
//     the cloud, `schema_version`, `availability`); its table `meta` has
//     `active_local_uuid`, the one in use. It lists the database workspaces (in
//     `Workspaces/<id>`), and also any folder workspace those versions have opened as
//     a folder. A database workspace's folder not in the registry is found too, by
//     looking in `Workspaces` for a `DocumentStore` (A GUESS that one can be there and
//     not listed).
//   - 21: the setting `userWorkspaces`, JSON kept as data, each entry a `name`, a `url`
//     (the folder) and `isActive`; the folders are in `UserWorkspaces`.
//     (Pro7ChordEditor's Places.swift found it so; the code here is taken from there.)
//   - Before workspaces: one folder, `ProPresenter` in Documents, unless the setting
//     `applicationShowDirectory` names another (A GUESS that this is what it means:
//     with 21 it names the workspace in use).
//
// A folder with neither `Libraries` nor a `DocumentStore` in it is left out, and one
// found twice is listed once. ProPresenter's settings and registry are only read; the
// registry is read from a copy (SQLiteReader).
//
// The finder is handed what it reads (a setting by its key, ProPresenter's folder,
// Documents), so that the tests can hand it made-up ones; `onThisMac` hands it the
// real ones.

import Foundation
import ProFormat

public struct WorkspaceFinder {
    /// The identifier ProPresenter keeps its settings under, which is its bundle's.
    public static let proPresenter = "com.renewedvision.propresenter"

    /// Reads one of ProPresenter's settings by its key. Nothing is ever written.
    public var proPresentersSetting: (String) -> Any?
    /// ProPresenter's own folder in Application Support.
    public var supportFolder: URL?
    /// The person's Documents folder, as the system says it is.
    public var documents: URL?

    public init(proPresentersSetting: @escaping (String) -> Any?, supportFolder: URL?, documents: URL?) {
        self.proPresentersSetting = proPresentersSetting
        self.supportFolder = supportFolder
        self.documents = documents
    }

    /// The finder for this Mac.
    public static func onThisMac() -> WorkspaceFinder {
        let fm = FileManager.default
        return WorkspaceFinder(
            proPresentersSetting: { key in CFPreferencesCopyAppValue(key as CFString, proPresenter as CFString) },
            supportFolder: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("RenewedVision/ProPresenter", isDirectory: true),
            // (Asked of the system, not built: Documents may be kept in iCloud.)
            documents: fm.urls(for: .documentDirectory, in: .userDomainMask).first
        )
    }

    /// Every workspace, each once: those of the registry (the one in use first), the
    /// database workspaces it does not list, those of the settings (the one in use
    /// first), then the folder the settings name, then Documents.
    public func workspaces() -> [Workspace] {
        var found: [Workspace] = []
        func add(_ workspace: Workspace) {
            guard let kind = Self.kind(of: workspace.folder) else { return }
            var workspace = workspace
            workspace.kind = kind
            if let k = found.firstIndex(where: { $0.id == workspace.id }) {
                found[k].isInUse = found[k].isInUse || workspace.isInUse
                return
            }
            found.append(workspace)
        }

        let registered = registry()
        for workspace in registered.filter(\.isInUse) + registered.filter({ !$0.isInUse }) { add(workspace) }
        if let support = supportFolder {
            let folders = (try? FileManager.default.contentsOfDirectory(at: support.appendingPathComponent("Workspaces"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for folder in folders.sorted(by: { $0.path < $1.path })
            where FileManager.default.fileExists(atPath: folder.appendingPathComponent("DocumentStore/workspace-v1.sqlite3").path) {
                add(Workspace(kind: .database, name: folder.lastPathComponent, folder: folder))
            }
        }
        let listed = settingsWorkspaces()
        for workspace in listed.filter(\.isInUse) + listed.filter({ !$0.isInUse }) { add(workspace) }
        if let named = proPresentersSetting("applicationShowDirectory") as? String, !named.isEmpty {
            let folder = URL(fileURLWithPath: (named as NSString).expandingTildeInPath, isDirectory: true)
            add(Workspace(kind: .folder, name: folder.lastPathComponent, folder: folder))
        }
        if let documents {
            add(Workspace(kind: .folder, name: "ProPresenter (Documents)", folder: documents.appendingPathComponent("ProPresenter", isDirectory: true)))
        }
        return found
    }

    /// What a folder is: a database workspace, a folder workspace, or neither (nil).
    static func kind(of folder: URL) -> Workspace.Kind? {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent("DocumentStore/workspace-v1.sqlite3").path) { return .database }
        var isFolder: ObjCBool = false
        if fm.fileExists(atPath: folder.appendingPathComponent("Libraries").path, isDirectory: &isFolder), isFolder.boolValue { return .folder }
        return nil
    }

    /// The workspaces the registry of the versions after 21 lists.
    func registry() -> [Workspace] {
        guard let support = supportFolder else { return [] }
        let file = support.appendingPathComponent("Workspaces/registry-v1.sqlite3")
        guard FileManager.default.fileExists(atPath: file.path), let db = try? SQLiteReader(copying: file),
              (try? db.hasTable("workspaces")) == true else { return [] }
        let active = (try? db.hasTable("meta")) == true
            ? (try? db.rows("SELECT value FROM meta WHERE key = 'active_local_uuid'"))?.first?["value"]?.text
            : nil
        let rows = (try? db.rows("SELECT * FROM workspaces")) ?? []
        return rows.compactMap { row in
            guard let path = row["root_path"]?.text, !path.isEmpty else { return nil }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let name = row["display_name"]?.text.flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
            let cloud = row["cloud_uuid"]?.text.map { !$0.isEmpty } ?? false
            let isActive = active != nil && row["local_uuid"]?.text == active
            return Workspace(kind: .database, name: name, folder: folder, isCloud: cloud, isInUse: isActive)
        }
    }

    /// The workspaces ProPresenter 21's settings list, as they are listed.
    func settingsWorkspaces() -> [Workspace] {
        let listed: [[String: Any]]
        switch proPresentersSetting("userWorkspaces") {
        case let data as Data:
            listed = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        case let text as String:
            listed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] ?? []
        case let ready as [[String: Any]]:
            listed = ready
        default:
            listed = []
        }
        return listed.compactMap { entry in
            guard let where_ = entry["url"] as? String, !where_.isEmpty else { return nil }
            // (A file URL as ProPresenter writes it; a plain path is taken too.)
            let folder = where_.hasPrefix("file:") ? URL(string: where_) : URL(fileURLWithPath: (where_ as NSString).expandingTildeInPath, isDirectory: true)
            guard let folder, folder.isFileURL else { return nil }
            let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
            return Workspace(kind: .folder, name: name, folder: folder, isInUse: entry["isActive"] as? Bool ?? false)
        }
    }
}

/// What the window and the command line read workspaces through.
public enum WorkspaceReader {
    /// A workspace's libraries and playlists.
    public static func contents(of workspace: Workspace) throws -> WorkspaceContents {
        switch workspace.kind {
        case .folder: return try FolderWorkspace.contents(of: workspace)
        case .database: return try DatabaseWorkspace.contents(of: workspace)
        }
    }

    /// A presentation kept in a database workspace, as ProPresenter's message.
    public static func presentation(store: URL, id: String) throws -> RVData_Presentation {
        try DatabaseWorkspace.presentation(store: store, id: id)
    }
}
