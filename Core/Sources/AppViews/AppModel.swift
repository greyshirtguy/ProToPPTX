// AppModel: what the window shows and does, with no view in it.
//
// Presentations come from two places. The person can add files (dropped on the
// window, chosen with Add…, or opened from the Finder), which are listed under "Added".
// And every ProPresenter workspace on this Mac is found (Workspaces), of either kind,
// with its libraries and playlists; choosing one lists its presentations, or the
// playlist's items in order, its headings among them.
//
// A presentation is read into a Deck in the background, and its slides drawn as the
// preview: one added at once, one in a workspace when it is first chosen (a library can
// have hundreds). The options apply to every presentation: changing one reads again
// every presentation that has been read, so that what is shown is always what would be
// written. The chosen presentations, or all those listed, are then written out as .pptx.
//
// A presentation chosen from a playlist is read with the arrangement the playlist's item
// chose, if it chose one (PlayOrder says more).
//
// The options are kept between runs (in the app's settings, as the JSON that
// ConversionOptions is Codable to), so that the command line can be handed the same set
// one day (docs/OPTIONS.md).

import AppKit
import Conversion
import DeckModel
import DeckPreview
import Foundation
import Observation
import ProImport
import UniformTypeIdentifiers
import Workspaces

@MainActor @Observable
public final class AppModel {
    /// Where the presentations listed come from.
    public enum Source: Hashable, Sendable {
        case added
        case library(workspace: Workspace.ID, name: String)
        case playlist(workspace: Workspace.ID, id: String)
    }

    /// A workspace's libraries and playlists, as far as they have been read.
    public enum WorkspaceState {
        case reading
        case ready(WorkspaceContents)
        case failed(String)
    }

    /// A row of the list of presentations. (A playlist can have one presentation twice:
    /// each row is its own, the item read for both is one.)
    public enum Row: Identifiable {
        case presentation(PresentationItem, row: String)
        /// A playlist's heading.
        case heading(id: String, name: String)
        /// A playlist's item that is not a presentation that can be read: media, or a
        /// presentation that was not found.
        case other(id: String, name: String, why: String)

        public var id: String {
            switch self {
            case .presentation(_, let row): return row
            case .heading(let id, _), .other(let id, _, _): return "row:" + id
            }
        }
    }

    public private(set) var workspaces: [Workspace] = []
    public private(set) var workspaceStates: [Workspace.ID: WorkspaceState] = [:]
    public private(set) var isFindingWorkspaces = false
    /// The workspace whose libraries and playlists are shown. Remembered between runs;
    /// at first, the first found (the one in use, of the newest kind).
    public var chosenWorkspace: Workspace.ID? {
        didSet {
            guard chosenWorkspace != oldValue else { return }
            UserDefaults.standard.set(chosenWorkspace, forKey: Self.workspaceKey)
            switch source {
            case .library(let w, _)?, .playlist(let w, _)?:
                if w != chosenWorkspace { source = firstLibrary(of: chosenWorkspace) }
            default:
                break
            }
        }
    }
    public var source: Source? = .added {
        didSet {
            guard source != oldValue else { return }
            rebuildRows()
            selection = rows.first { $0.presentationItem != nil }.map { [$0.id] } ?? []
        }
    }
    public private(set) var added: [PresentationItem] = []
    /// What is listed for the source chosen.
    public private(set) var rows: [Row] = []
    /// The rows chosen, by their ids.
    public var selection: Set<Row.ID> = [] {
        didSet { if let item = selected, item.hasNotBeenRead { item.load(options: options) } }
    }
    public var options: ConversionOptions {
        didSet {
            guard options != oldValue else { return }
            Self.save(options)
            reloadAll()
        }
    }
    /// A short message about the last export, shown until the next.
    public var exportMessage: ExportMessage?
    public private(set) var isExporting = false

    public struct ExportMessage: Equatable {
        public var text: String
        public var files: [URL]
        public var isError: Bool
    }

    /// Every presentation item made so far, by its id, so that one chosen again is not
    /// read again.
    @ObservationIgnored private var items: [PresentationItem.ID: PresentationItem] = [:]

    public init() {
        options = Self.savedOptions()
        rebuildRows()
    }

    /// The one presentation chosen, if exactly one is.
    public var selected: PresentationItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return rows.first { $0.id == id }?.presentationItem
    }

    /// The presentations chosen, in the order they are listed.
    public var selectedItems: [PresentationItem] {
        rows.filter { selection.contains($0.id) }.compactMap(\.presentationItem)
    }

    /// Every presentation listed.
    public var listedItems: [PresentationItem] { rows.compactMap(\.presentationItem) }

    // MARK: - Workspaces

    /// Finds the workspaces again, and reads what each has.
    public func findWorkspaces() {
        guard !isFindingWorkspaces else { return }
        isFindingWorkspaces = true
        Task {
            let found = await Task.detached { WorkspaceFinder.onThisMac().workspaces() }.value
            show(found)
        }
    }

    /// Shows these workspaces, and reads what each has. What was read of their
    /// presentations is forgotten, to be read again when they are next chosen.
    func show(_ found: [Workspace]) {
        items = items.filter { $0.value.ref.workspaceFolder == nil }
        workspaces = found
        isFindingWorkspaces = false
        if chosenWorkspace == nil || !found.contains(where: { $0.id == chosenWorkspace }) {
            let remembered = UserDefaults.standard.string(forKey: Self.workspaceKey)
            chosenWorkspace = found.first { $0.id == remembered }?.id ?? found.first?.id
        }
        for workspace in found { readContents(of: workspace) }
        if case .library(let w, _)? = source, !found.contains(where: { $0.id == w }) { source = .added }
        if case .playlist(let w, _)? = source, !found.contains(where: { $0.id == w }) { source = .added }
    }

    /// Shows a workspace whose contents are already at hand (for the tests' pictures).
    func show(_ workspace: Workspace, contents: WorkspaceContents) {
        workspaces = [workspace]
        workspaceStates[workspace.id] = .ready(contents)
        chosenWorkspace = workspace.id
        rebuildRows()
    }

    private static let workspaceKey = "ChosenWorkspace"

    /// The first library of a workspace, as a source.
    private func firstLibrary(of workspace: Workspace.ID?) -> Source? {
        guard let workspace, let library = contents(of: workspace)?.libraries.first else { return nil }
        return .library(workspace: workspace, name: library.name)
    }

    private func readContents(of workspace: Workspace) {
        if workspaceStates[workspace.id] == nil { workspaceStates[workspace.id] = .reading }
        Task {
            let outcome = await Task.detached { Result { try WorkspaceReader.contents(of: workspace) } }.value
            switch outcome {
            case .success(let contents): workspaceStates[workspace.id] = .ready(contents)
            case .failure(let error): workspaceStates[workspace.id] = .failed("\(error)")
            }
            // The chosen workspace, read for the first time: its first library is shown,
            // unless something else is.
            if workspace.id == chosenWorkspace, source == nil || (source == .added && added.isEmpty) {
                source = firstLibrary(of: workspace.id)
            }
            rebuildRows()
            if selection.isEmpty, let first = rows.first(where: { $0.presentationItem != nil }) { selection = [first.id] }
            if let item = selected, item.hasNotBeenRead { item.load(options: options) }
        }
    }

    public func contents(of workspace: Workspace.ID) -> WorkspaceContents? {
        if case .ready(let c)? = workspaceStates[workspace] { return c }
        return nil
    }

    /// What to call the source chosen, and the workspace it is in.
    public var sourceTitle: (name: String, workspace: String?) {
        switch source {
        case .added?, nil:
            return ("Added", nil)
        case .library(let w, let name)?:
            return (name, workspaces.first { $0.id == w }?.name)
        case .playlist(let w, let id)?:
            let name = contents(of: w)?.playlists.flatMap(\.allPlaylists).first { $0.id == id }?.name ?? "Playlist"
            return (name, workspaces.first { $0.id == w }?.name)
        }
    }

    private func rebuildRows() {
        switch source {
        case .added?, nil:
            rows = added.map { .presentation($0, row: $0.id) }
        case .library(let w, let name)?:
            let refs = contents(of: w)?.libraries.first { $0.name == name }?.presentations ?? []
            rows = refs.map { ref in
                let item = item(for: ref, arrangement: nil)
                return .presentation(item, row: item.id)
            }
        case .playlist(let w, let id)?:
            let playlist = contents(of: w)?.playlists.flatMap(\.allPlaylists).first { $0.id == id }
            rows = (playlist?.entries ?? []).enumerated().map { k, entry in
                switch entry.kind {
                case .header:
                    return .heading(id: "\(k)-" + entry.id, name: entry.name)
                case .presentation(let ref?, let arrangement):
                    return .presentation(item(for: ref, arrangement: arrangement), row: "\(k)-" + entry.id)
                case .presentation(nil, _):
                    return .other(id: "\(k)-" + entry.id, name: entry.name, why: "Not found in the workspace's libraries")
                case .other:
                    return .other(id: "\(k)-" + entry.id, name: entry.name, why: "Not a presentation")
                }
            }
        }
    }

    /// The item for a presentation (with the arrangement a playlist chose for it), made
    /// the first time it is asked for.
    private func item(for ref: PresentationRef, arrangement: String?) -> PresentationItem {
        let id = PresentationItem.id(ref, arrangement: arrangement)
        if let known = items[id] { return known }
        let item = PresentationItem(ref: ref, arrangement: arrangement)
        items[id] = item
        return item
    }

    // MARK: - Adding and removing files

    /// The file types this app reads: ProPresenter's presentations and bundles.
    public static let presentationExtensions: Set<String> = ["pro", "probundle"]

    /// Adds presentations: files, or every presentation in a folder (and the folders in
    /// it). One already in the list is not added twice. The list of what was added is
    /// then the one shown.
    public func add(_ urls: [URL]) {
        var found: [URL] = []
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let item = walker?.nextObject() as? URL {
                    if Self.presentationExtensions.contains(item.pathExtension.lowercased()) { found.append(item) }
                }
            } else if Self.presentationExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        var new: [PresentationItem] = []
        for url in found.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let item = item(for: .file(url), arrangement: nil)
            guard !added.contains(where: { $0.id == item.id }), !new.contains(where: { $0.id == item.id }) else { continue }
            new.append(item)
            if item.hasNotBeenRead { item.load(options: options) }
        }
        added.append(contentsOf: new)
        if source != .added {
            source = .added
        } else {
            rebuildRows()
        }
        if let first = new.first {
            selection = [first.id]
        } else if selection.isEmpty, let first = added.first {
            selection = [first.id]
        }
    }

    /// Takes presentations out of the list of those added, by their rows' ids (which,
    /// in that list, are theirs).
    public func removeAdded(_ ids: Set<Row.ID>) {
        added.removeAll { ids.contains($0.id) }
        rebuildRows()
        selection.subtract(ids)
        if selection.isEmpty, let first = added.first, source == .added { selection = [first.id] }
    }

    public func removeAllAdded() {
        added.removeAll()
        rebuildRows()
        if source == .added { selection = [] }
    }

    private func reloadAll() {
        for item in items.values where !item.hasNotBeenRead { item.load(options: options) }
    }

    // MARK: - Exporting

    /// Writes one presentation to `url`.
    public func export(_ item: PresentationItem, to url: URL) {
        export([(item, url)])
    }

    /// Writes presentations into `folder`, each under its own name. `numbered` puts
    /// each one's place in the list before its name ("01 Song.pptx"), so that the files
    /// sort as a playlist has them.
    public func export(_ items: [PresentationItem], into folder: URL, numbered: Bool = false) {
        let width = String(items.count).count < 2 ? 2 : String(items.count).count
        var taken = Set<String>()
        let jobs = items.enumerated().map { k, item -> (PresentationItem, URL) in
            var name = Converter.defaultOutputName(named: item.name)
            if numbered {
                let number = String(k + 1)
                name = String(repeating: "0", count: max(0, width - number.count)) + number + " " + name
            }
            var url = Self.uniqueURL(folder.appendingPathComponent(name))
            // (Two of the list can want one name: the second is numbered, as a file
            // already there would be.)
            var n = 2
            while taken.contains(url.lastPathComponent.lowercased()) {
                url = folder.appendingPathComponent((name as NSString).deletingPathExtension + " \(n).pptx")
                n += 1
            }
            taken.insert(url.lastPathComponent.lowercased())
            return (item, url)
        }
        export(jobs)
    }

    private func export(_ jobs: [(PresentationItem, URL)]) {
        guard !jobs.isEmpty, !isExporting else { return }
        isExporting = true
        exportMessage = nil
        let options = self.options
        let work = jobs.map { (ref: $0.0.ref, arrangement: $0.0.arrangement, name: $0.0.name, output: $0.1, loaded: $0.0.loaded) }
        Task {
            var written: [URL] = []
            var failures: [String] = []
            for job in work {
                let outcome: Result<[ConversionNote], Error> = await Task.detached {
                    Result {
                        // A presentation already read with these options is not read again.
                        let loaded = try job.loaded ?? Converter.load(job.ref, arrangement: job.arrangement, options: options)
                        return try Converter.write(loaded, to: job.output, options: options)
                    }
                }.value
                switch outcome {
                case .success: written.append(job.output)
                case .failure(let error): failures.append("\(job.name): \(error)")
                }
            }
            isExporting = false
            if failures.isEmpty {
                let text = written.count == 1 ? "Saved \(written[0].lastPathComponent)." : "Saved \(written.count) PowerPoint files."
                exportMessage = ExportMessage(text: text, files: written, isError: false)
            } else {
                exportMessage = ExportMessage(text: (written.isEmpty ? "" : "Saved \(written.count); ") + "could not save " + failures.joined(separator: "; "), files: written, isError: true)
            }
        }
    }

    /// The URL itself if nothing is there, else the same name with a number.
    static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for n in 2...999 {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    // MARK: - Options kept between runs

    private static let optionsKey = "ConversionOptions"

    private static func savedOptions() -> ConversionOptions {
        guard let data = UserDefaults.standard.data(forKey: optionsKey),
              let options = try? JSONDecoder().decode(ConversionOptions.self, from: data) else { return .defaults }
        return options
    }

    private static func save(_ options: ConversionOptions) {
        if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: optionsKey) }
    }
}

extension AppModel.Row {
    public var presentationItem: PresentationItem? {
        if case .presentation(let item, _) = self { return item }
        return nil
    }
}

/// One presentation: what was read of it, and the pictures of its slides.
@MainActor @Observable
public final class PresentationItem: Identifiable {
    public enum State {
        case notRead
        case reading
        case ready
        case failed(String)
    }

    public let id: String
    public let ref: PresentationRef
    /// The arrangement a playlist's item chose for it, by id.
    public let arrangement: String?
    public private(set) var state: State = .notRead
    public private(set) var loaded: ImportResult?
    /// Small pictures of the slides, by index, as they are drawn.
    public private(set) var thumbnails: [Int: CGImage] = [:]

    private var generation = 0
    private let renderer = SlideRenderer()

    init(ref: PresentationRef, arrangement: String?) {
        self.id = Self.id(ref, arrangement: arrangement)
        self.ref = ref
        self.arrangement = arrangement
    }

    static func id(_ ref: PresentationRef, arrangement: String?) -> String {
        ref.id + (arrangement.map { "|" + $0 } ?? "")
    }

    public var name: String { ref.name }
    public var deck: Deck? { loaded?.deck }
    public var notes: [ConversionNote] { loaded?.notes ?? [] }
    public var fileURL: URL? { ref.fileURL }
    public var hasNotBeenRead: Bool { if case .notRead = state { return true } else { return false } }

    /// Reads the presentation (again) with these options, then draws its slides.
    func load(options: ConversionOptions) {
        generation += 1
        let mine = generation
        state = .reading
        let ref = self.ref, arrangement = self.arrangement
        Task {
            let outcome: Result<ImportResult, Error> = await Task.detached {
                Result { try Converter.load(ref, arrangement: arrangement, options: options) }
            }.value
            guard mine == generation else { return } // read again since
            switch outcome {
            case .success(let result):
                loaded = result
                state = .ready
                drawThumbnails(result.deck, generation: mine)
            case .failure(let error):
                loaded = nil
                thumbnails = [:]
                state = .failed("\(error)")
            }
        }
    }

    /// A larger picture of one slide, for looking at it closely.
    public func picture(of index: Int, width: Int) async -> CGImage? {
        guard let deck, deck.slides.indices.contains(index) else { return nil }
        let renderer = self.renderer
        let slide = deck.slides[index], size = deck.size
        return await Task.detached { renderer.render(slide, deckSize: size, pixelWidth: width) }.value
    }

    private func drawThumbnails(_ deck: Deck, generation mine: Int) {
        let renderer = self.renderer
        Task {
            for (k, slide) in deck.slides.enumerated() {
                let image = await Task.detached(priority: .userInitiated) { renderer.render(slide, deckSize: deck.size, pixelWidth: 640) }.value
                guard mine == generation else { return }
                if let image { thumbnails[k] = image }
            }
        }
    }
}
