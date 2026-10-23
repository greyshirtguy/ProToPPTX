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
// its order).

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
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: chooseFiles) { Label("Add…", systemImage: "plus") }
                    .help("Add ProPresenter presentation files (.pro or .probundle), or folders of them")
                Button(action: exportSelected) { Label(exportTitle, systemImage: "square.and.arrow.up") }
                    .disabled(model.selectedItems.isEmpty || model.isExporting)
                    .help("Save the chosen presentations as PowerPoint files")
                Button(action: exportAll) { Label("Export All…", systemImage: "square.and.arrow.up.on.square") }
                    .disabled(model.listedItems.isEmpty || model.isExporting)
                    .help("Save every presentation listed as PowerPoint files, into one folder")
                Toggle(isOn: $showOptions) { Label("Options", systemImage: "sidebar.right") }
                    .help("Show or hide the options")
            }
        }
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

    /// One chosen: asks where, by name. Several: asks for a folder.
    public static func exportSelected(_ model: AppModel) {
        let chosen = model.selectedItems
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
                        .contextMenu { menu(for: item, row: id) }
                case .heading(_, let name):
                    PlaylistHeadingRow(name: name)
                        .selectionDisabled()
                case .other(_, let name, let why):
                    OtherItemRow(name: name, why: why)
                        .selectionDisabled()
                }
            }
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

    @ViewBuilder private func menu(for item: PresentationItem, row: String) -> some View {
        if let file = item.fileURL {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
        if model.source == .added {
            Divider()
            Button("Remove from List") { model.removeAdded(model.selection.contains(row) ? model.selection : [row]) }
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
