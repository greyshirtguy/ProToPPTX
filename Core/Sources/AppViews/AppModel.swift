// AppModel: what the window shows and does, with no view in it.
//
// The person adds presentations (dropped on the window, chosen with Add…, or opened from
// the Finder); each is read straight away, in the background, into a Deck, and its
// slides are drawn as the preview. The options apply to every presentation: changing
// one reads them all again, so that what is shown is always what would be written. A
// presentation, or all of them, is then written out as .pptx.
//
// The options are kept between runs (in the app's settings, as the JSON that
// ConversionOptions is Codable to), so that the command line can be handed the same set
// one day (docs/OPTIONS.md).

import AppKit
import Conversion
import ProImport
import DeckModel
import DeckPreview
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
public final class AppModel {
    public private(set) var presentations: [PresentationItem] = []
    public var selection: PresentationItem.ID?
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

    public init() {
        options = Self.savedOptions()
    }

    public var selected: PresentationItem? { presentations.first { $0.id == selection } }

    // MARK: - Adding and removing

    /// The file types this app reads: ProPresenter's presentations and bundles.
    public static let presentationExtensions: Set<String> = ["pro", "probundle"]

    /// Adds presentations: files, or every presentation in a folder (and the folders in
    /// it). One already in the list is not added twice.
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
        let known = Set(presentations.map { $0.url.standardizedFileURL })
        var added: [PresentationItem] = []
        for url in found.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        where !known.contains(url.standardizedFileURL) && !added.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            let item = PresentationItem(url: url)
            added.append(item)
            item.load(options: options)
        }
        presentations.append(contentsOf: added)
        if selection == nil || !presentations.contains(where: { $0.id == selection }) { selection = added.first?.id ?? presentations.first?.id }
    }

    public func remove(_ id: PresentationItem.ID) {
        presentations.removeAll { $0.id == id }
        if selection == id { selection = presentations.first?.id }
    }

    public func removeAll() {
        presentations.removeAll()
        selection = nil
    }

    private func reloadAll() {
        for item in presentations { item.load(options: options) }
    }

    // MARK: - Exporting

    /// Writes one presentation to `url`.
    public func export(_ item: PresentationItem, to url: URL) {
        export([(item, url)])
    }

    /// Writes every presentation into `folder`, each under its own name.
    public func exportAll(into folder: URL) {
        let jobs = presentations.map { item in
            (item, Self.uniqueURL(folder.appendingPathComponent(Converter.defaultOutputName(for: item.url))))
        }
        export(jobs)
    }

    private func export(_ jobs: [(PresentationItem, URL)]) {
        guard !jobs.isEmpty, !isExporting else { return }
        isExporting = true
        exportMessage = nil
        let options = self.options
        let work = jobs.map { (input: $0.0.url, output: $0.1, loaded: $0.0.loaded) }
        Task {
            var written: [URL] = []
            var failures: [String] = []
            for job in work {
                let outcome: Result<[ConversionNote], Error> = await Task.detached {
                    Result {
                        // A presentation already read with these options is not read again.
                        let loaded = try job.loaded ?? Converter.load(job.input, options: options)
                        return try Converter.write(loaded, to: job.output, options: options)
                    }
                }.value
                switch outcome {
                case .success: written.append(job.output)
                case .failure(let error): failures.append("\(job.input.lastPathComponent): \(error)")
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

/// One presentation in the list: what was read of it, and the pictures of its slides.
@MainActor @Observable
public final class PresentationItem: Identifiable {
    public enum State {
        case reading
        case ready
        case failed(String)
    }

    public let id = UUID()
    public let url: URL
    public private(set) var state: State = .reading
    public private(set) var loaded: ImportResult?
    /// Small pictures of the slides, by index, as they are drawn.
    public private(set) var thumbnails: [Int: CGImage] = [:]

    private var generation = 0
    private let renderer = SlideRenderer()

    init(url: URL) {
        self.url = url
    }

    public var name: String { url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespaces) }
    public var deck: Deck? { loaded?.deck }
    public var notes: [ConversionNote] { loaded?.notes ?? [] }

    /// Reads the presentation (again) with these options, then draws its slides.
    func load(options: ConversionOptions) {
        generation += 1
        let mine = generation
        state = .reading
        let url = self.url
        Task {
            let outcome: Result<ImportResult, Error> = await Task.detached { Result { try Converter.load(url, options: options) } }.value
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
