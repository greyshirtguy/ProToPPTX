// MainWindow: the app's one window.
//
// On the left, where presentations come from: a ProPresenter workspace's libraries and
// playlists (the workspace chosen at the top, as ProPresenter itself chooses one), and
// the files added by hand (dropped on the window, or Add…). In the middle, the
// presentations of the one chosen there: a library's in order of name, a playlist's
// items in the playlist's order, its headings among them. On the right, the chosen
// presentation's slides as they will be in PowerPoint, each marked if its background
// was carried on from an earlier slide; and at the far right the options, which apply
// to every presentation, and what could not be carried over of the chosen one.
//
// Several presentations can be chosen at once. Export writes the chosen ones; Export
// All writes every one listed in the middle, into one folder (a playlist's numbered in
// its order). A presentation's menu (a right click) exports it, or every one chosen if
// it is one of them, as the Finder's menus do.

import AppKit
import Conversion
import DeckModel
import SwiftUI
import UniformTypeIdentifiers
import Workspaces

public struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var showOptions = true
    @State private var isTargeted = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            SourceList(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
        } content: {
            PresentationList(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 460)
        } detail: {
            Group {
                if let item = model.selected {
                    SlideGrid(item: item)
                } else if model.selection.count > 1 {
                    SeveralChosen(model: model)
                } else if model.source == .added, model.added.isEmpty {
                    DropHint(add: chooseFiles)
                } else {
                    Text(model.rows.isEmpty ? "Nothing here to convert." : "Choose a presentation.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let message = model.exportMessage { ExportBanner(message: message) { model.exportMessage = nil } }
            }
        }
        .inspector(isPresented: $showOptions) {
            OptionsPanel(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar(id: "main") {
            ToolbarItem(id: ToolbarTips.add, placement: .primaryAction) {
                Button(action: chooseFiles) { Label("Add…", systemImage: "plus") }
            }
            ToolbarItem(id: ToolbarTips.export, placement: .primaryAction) {
                Button(action: exportSelected) { Label(exportTitle, systemImage: "square.and.arrow.up") }
                    .disabled(model.selectedItems.isEmpty || model.isExporting)
            }
            ToolbarItem(id: ToolbarTips.exportAll, placement: .primaryAction) {
                Button(action: exportAll) { Label("Export All…", systemImage: "square.and.arrow.up.on.square") }
                    .disabled(model.listedItems.isEmpty || model.isExporting)
            }
            ToolbarItem(id: ToolbarTips.options, placement: .primaryAction) {
                Toggle(isOn: $showOptions) { Label("Options", systemImage: "sidebar.right") }
            }
        }
        .background(ToolbarTips())
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(6).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .navigationTitle(model.selected?.name ?? model.sourceTitle.name)
        .navigationSubtitle(model.sourceTitle.workspace ?? "")
        .task { model.findWorkspaces() }
    }

    private var exportTitle: String {
        let n = model.selectedItems.count
        return n > 1 ? "Export \(n)…" : "Export…"
    }

    func chooseFiles() { AppActions.chooseFiles(model) }
    func exportSelected() { AppActions.exportSelected(model) }
    func exportAll() { AppActions.exportAll(model) }
}

/// What the toolbar and the menus do, in one place for both.
@MainActor
public enum AppActions {
    public static func chooseFiles(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = AppTypes.presentations
        panel.message = "Choose ProPresenter presentations, or folders of them"
        panel.prompt = "Add"
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    public static func exportSelected(_ model: AppModel) {
        export(model.selectedItems, model)
    }

    /// One: asks where, by name. Several: asks for a folder.
    public static func export(_ chosen: [PresentationItem], _ model: AppModel) {
        if chosen.count == 1, let item = chosen.first {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [AppTypes.pptx]
            panel.nameFieldStringValue = Converter.defaultOutputName(named: item.name)
            if let file = item.fileURL { panel.directoryURL = file.deletingLastPathComponent() }
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url { model.export(item, to: url) }
        } else if !chosen.isEmpty, let folder = chooseFolder(for: chosen, model) {
            model.export(chosen, into: folder, numbered: isPlaylist(model))
        }
    }

    public static func exportAll(_ model: AppModel) {
        let all = model.listedItems
        guard !all.isEmpty, let folder = chooseFolder(for: all, model) else { return }
        model.export(all, into: folder, numbered: isPlaylist(model))
    }

    private static func isPlaylist(_ model: AppModel) -> Bool {
        if case .playlist? = model.source { return true }
        return false
    }

    private static func chooseFolder(for items: [PresentationItem], _ model: AppModel) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = isPlaylist(model)
            ? "Choose a folder for the \(items.count) PowerPoint files. Each is numbered in the playlist's order."
            : "Choose a folder for the \(items.count) PowerPoint files"
        panel.directoryURL = items.first?.fileURL?.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// The File menu's own items.
public struct AppCommands: Commands {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Presentations…") { AppActions.chooseFiles(model) }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Export…") { AppActions.exportSelected(model) }
                .keyboardShortcut("e")
                .disabled(model.selectedItems.isEmpty || model.isExporting)
            Button("Export All…") { AppActions.exportAll(model) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.listedItems.isEmpty || model.isExporting)
            Divider()
            Button("Look for Workspaces Again") { model.findWorkspaces() }
                .keyboardShortcut("r")
            Button("Remove from List") { model.removeAdded(model.selection) }
                .disabled(model.source != .added || model.selection.isEmpty)
        }
    }
}

enum AppTypes {
    static let pro = UTType(importedAs: "com.renewedvision.pro.presentation", conformingTo: .data)
    static let probundle = UTType(importedAs: "com.renewedvision.pro.presentation.bundle", conformingTo: .data)
    static let pptx = UTType("org.openxmlformats.presentationml.presentation") ?? UTType(filenameExtension: "pptx")!
    static var presentations: [UTType] { [pro, probundle, .folder] }
}

/// The toolbar's tooltips. (KNOWN, macOS 26.4: SwiftUI's `.help` on a button in the
/// toolbar reaches neither the screen nor accessibility; on a toggle it does. So each
/// item is named, and its tooltip set on AppKit's own item of that name, which shows.
/// Named, the toolbar is also one the person can rearrange, as the Finder's is.)
struct ToolbarTips: NSViewRepresentable {
    static let add = "add", export = "export", exportAll = "exportAll", options = "options"

    static let tips: [String: String] = [
        add: "Add ProPresenter presentation files (.pro or .probundle), or folders of them",
        export: "Save the chosen presentations as PowerPoint files",
        exportAll: "Save every presentation listed as PowerPoint files, into one folder",
        options: "Show or hide the options",
        // (SwiftUI's own button, by the name it gives it.)
        "com.apple.SwiftUI.navigationSplitView.toggleSidebar": "Show or hide the libraries and playlists",
    ]

    func makeNSView(context: Context) -> NSView { Watcher() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Watcher)?.setTips() }

    /// Sets the tips when it is put in its window, and on every item added after.
    final class Watcher: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil else { return }
            observer = NotificationCenter.default.addObserver(forName: NSToolbar.willAddItemNotification, object: nil, queue: .main) { [weak self] note in
                guard let item = note.userInfo?["item"] as? NSToolbarItem else { return }
                MainActor.assumeIsolated {
                    if item.toolbar == nil || item.toolbar === self?.window?.toolbar { ToolbarTips.setTip(item) }
                }
            }
            // (The toolbar's items can be made after this view is in the window.)
            DispatchQueue.main.async { [weak self] in self?.setTips() }
        }

        func setTips() {
            for item in window?.toolbar?.items ?? [] { ToolbarTips.setTip(item) }
        }
    }

    @MainActor static func setTip(_ item: NSToolbarItem) {
        if let tip = tips[item.itemIdentifier.rawValue], item.toolTip != tip { item.toolTip = tip }
    }
}

// MARK: - The list in the middle

struct PresentationList: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.rows) { row in
                switch row {
                case .presentation(let item, let id):
                    PresentationRow(item: item)
                        .tag(id)
                case .heading(_, let name):
                    PlaylistHeadingRow(name: name)
                        .selectionDisabled()
                case .other(_, let name, let why):
                    OtherItemRow(name: name, why: why)
                        .selectionDisabled()
                }
            }
        }
        .contextMenu(forSelectionType: AppModel.Row.ID.self) { ids in
            menu(for: ids)
        }
        .overlay {
            if model.rows.isEmpty {
                Text(emptyText).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
        .onDeleteCommand { if model.source == .added { model.removeAdded(model.selection) } }
        .safeAreaInset(edge: .bottom) {
            if !model.listedItems.isEmpty {
                Text(countText).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(.bar)
            }
        }
    }

    private var emptyText: String {
        switch model.source {
        case .added?, nil: return "Drop presentations here"
        case .library?: return "This library has no presentations."
        case .playlist?: return "This playlist has no presentations."
        }
    }

    private var countText: String {
        let n = model.listedItems.count, chosen = model.selection.count
        let all = "\(n) presentation\(n == 1 ? "" : "s")"
        return chosen > 1 ? "\(chosen) of \(all) chosen" : all
    }

    /// The menu of the rows clicked: the one, or every one chosen if it was one of them.
    /// (A heading's is empty, and so not shown.)
    @ViewBuilder private func menu(for ids: Set<AppModel.Row.ID>) -> some View {
        let items = model.items(inRows: ids)
        if !items.isEmpty {
            Button(items.count > 1 ? "Export \(items.count) as PowerPoint…" : "Export as PowerPoint…") {
                AppActions.export(items, model)
            }
            .disabled(model.isExporting)
            let files = items.compactMap(\.fileURL)
            if !files.isEmpty {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files) }
            }
            if model.source == .added {
                Divider()
                Button("Remove from List") { model.removeAdded(ids) }
            }
        }
    }
}

struct PresentationRow: View {
    let item: PresentationItem

    var body: some View {
        HStack(spacing: 8) {
            PresentationIcon()
                .frame(width: 15, height: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Group {
                    switch item.state {
                    case .notRead:
                        Text(notReadText)
                    case .reading:
                        Text("Reading…")
                    case .ready:
                        Text(summary)
                    case .failed(let why):
                        Text(why).foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .opacity(item.ref.isAvailable ? 1 : 0.5)
    }

    var notReadText: String {
        if !item.ref.isAvailable { return "In the cloud, not yet on this Mac" }
        if item.arrangement != nil { return "With the arrangement the playlist chose" }
        return " "
    }

    var summary: String {
        let slides = item.deck?.slides.count ?? 0
        let notes = item.notes.count
        var text = "\(slides) slide\(slides == 1 ? "" : "s")"
        if let arrangement = item.loaded?.arrangement, item.arrangement != nil { text += " · \(arrangement)" }
        if notes > 0 { text += " · \(notes) note\(notes == 1 ? "" : "s")" }
        return text
    }
}

/// A playlist's heading, as a line across the list.
struct PlaylistHeadingRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            Text(name.isEmpty ? "Heading" : name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .padding(.top, 6)
    }
}

/// A playlist's item that is not a presentation this app can read.
struct OtherItemRow: View {
    let name: String
    let why: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "minus.circle").foregroundStyle(.tertiary).frame(width: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? "Untitled" : name).lineLimit(1)
                Text(why).font(.caption)
            }
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .help(why)
    }
}

// MARK: - The right: several chosen, nothing yet, the export banner

struct SeveralChosen: View {
    @Bindable var model: AppModel

    var body: some View {
        let chosen = model.selectedItems
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("\(chosen.count) presentations chosen").font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(chosen.prefix(8)) { item in
                    Text(item.name).lineLimit(1).foregroundStyle(.secondary)
                }
                if chosen.count > 8 { Text("and \(chosen.count - 8) more").foregroundStyle(.tertiary) }
            }
            Button("Export \(chosen.count)…") { AppActions.exportSelected(model) }
                .controlSize(.large)
                .disabled(model.isExporting)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DropHint: View {
    let add: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop ProPresenter presentations here")
                .font(.title2)
            Text(".pro files, .probundle files, or folders of them")
                .foregroundStyle(.secondary)
            Button("Add…", action: add)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ExportBanner: View {
    let message: AppModel.ExportMessage
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(message.isError ? .orange : .green)
            Text(message.text).lineLimit(2)
            Spacer()
            if message.files.count == 1 {
                Button("Open") { NSWorkspace.shared.open(message.files[0]) }
            }
            if !message.files.isEmpty {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(message.files) }
            }
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }
}
