// MainWindow: the app's one window.
//
// On the left, the presentations added (drop them on the window, or Add…). In the
// middle, the chosen one's slides as they will be in PowerPoint, each marked if its
// background was carried on from an earlier slide. On the right, the options, which
// apply to every presentation, and what could not be carried over of the chosen one.
// Export writes the chosen presentation; Export All writes every one into a folder.

import AppKit
import Conversion
import DeckModel
import SwiftUI
import UniformTypeIdentifiers

public struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var showOptions = true
    @State private var isTargeted = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            PresentationList(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
        } detail: {
            Group {
                if let item = model.selected {
                    SlideGrid(item: item)
                } else {
                    DropHint(add: chooseFiles)
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
                    .help("Add ProPresenter presentations (.pro or .probundle), or folders of them")
                Button(action: exportSelected) { Label("Export…", systemImage: "square.and.arrow.up") }
                    .disabled(model.selected?.loaded == nil || model.isExporting)
                    .help("Save the chosen presentation as a PowerPoint file")
                Button(action: exportAll) { Label("Export All…", systemImage: "square.and.arrow.up.on.square") }
                    .disabled(model.presentations.isEmpty || model.isExporting)
                    .help("Save every presentation in the list as PowerPoint files, into one folder")
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
        .navigationTitle(model.selected?.name ?? "ProToPPTX")
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
        guard let item = model.selected, item.loaded != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [AppTypes.pptx]
        panel.nameFieldStringValue = Converter.defaultOutputName(for: item.url)
        panel.directoryURL = item.url.deletingLastPathComponent()
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { model.export(item, to: url) }
    }

    public static func exportAll(_ model: AppModel) {
        guard !model.presentations.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the PowerPoint files"
        panel.directoryURL = model.presentations.first?.url.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { model.exportAll(into: url) }
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
                .disabled(model.selected?.loaded == nil || model.isExporting)
            Button("Export All…") { AppActions.exportAll(model) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.presentations.isEmpty || model.isExporting)
            Divider()
            Button("Remove from List") { if let id = model.selection { model.remove(id) } }
                .disabled(model.selection == nil)
        }
    }
}

enum AppTypes {
    static let pro = UTType(importedAs: "com.renewedvision.pro.presentation", conformingTo: .data)
    static let probundle = UTType(importedAs: "com.renewedvision.pro.presentation.bundle", conformingTo: .data)
    static let pptx = UTType("org.openxmlformats.presentationml.presentation") ?? UTType(filenameExtension: "pptx")!
    static var presentations: [UTType] { [pro, probundle, .folder] }
}

// MARK: - The list on the left

struct PresentationList: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.presentations) { item in
                PresentationRow(item: item)
                    .tag(item.id)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Divider()
                        Button("Remove from List") { model.remove(item.id) }
                    }
            }
            .onDelete { offsets in
                for i in offsets { model.remove(model.presentations[i].id) }
            }
        }
        .overlay {
            if model.presentations.isEmpty {
                Text("Drop presentations here").foregroundStyle(.secondary)
            }
        }
        .onDeleteCommand { if let id = model.selection { model.remove(id) } }
    }
}

struct PresentationRow: View {
    let item: PresentationItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.url.pathExtension.lowercased() == "probundle" ? "shippingbox" : "doc.richtext")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Group {
                    switch item.state {
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
    }

    var summary: String {
        let slides = item.deck?.slides.count ?? 0
        let notes = item.notes.count
        return "\(slides) slide\(slides == 1 ? "" : "s")" + (notes > 0 ? " · \(notes) note\(notes == 1 ? "" : "s")" : "")
    }
}

// MARK: - Empty state and the export banner

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
