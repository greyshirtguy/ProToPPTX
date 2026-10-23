// SourceList: the left of the window, where presentations come from.
//
// At the top, the ProPresenter workspace whose libraries and playlists are shown,
// chosen from every one found on this Mac (Workspaces/WorkspaceFinder), as ProPresenter
// itself shows one workspace at a time. Each is named as ProPresenter names it, with
// what kind it is ("Cloud", "Database" or "Folder", Workspace.swift says what the kinds
// are) and whether ProPresenter has it in use. Under it, as in ProPresenter's own
// window, its libraries and then its playlists, in their folders. At the bottom, the
// files added by hand.

import SwiftUI
import Workspaces

struct SourceList: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.source) {
            if let id = model.chosenWorkspace {
                switch model.workspaceStates[id] {
                case .ready(let contents)?:
                    Section("Libraries") {
                        ForEach(contents.libraries) { library in
                            LibraryRow(name: library.name, count: library.presentations.count)
                                .tag(AppModel.Source.library(workspace: id, name: library.name))
                        }
                        if contents.libraries.isEmpty { EmptyRow(text: "No libraries") }
                    }
                    Section("Playlists") {
                        OutlineGroup(contents.playlists, children: \.children) { node in
                            playlistRow(node, workspace: id)
                        }
                        if contents.playlists.isEmpty { EmptyRow(text: "No playlists") }
                    }
                case .failed(let why)?:
                    Section("Libraries") {
                        Label(why, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary).font(.callout).lineLimit(4)
                            .selectionDisabled()
                    }
                default:
                    Section("Libraries") {
                        HStack { ProgressView().controlSize(.small); Text("Reading…").foregroundStyle(.secondary) }
                            .selectionDisabled()
                    }
                }
            }
            Section("Files") {
                AddedRow(count: model.added.count)
                    .tag(AppModel.Source.added)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            WorkspacePicker(model: model)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder private func playlistRow(_ node: PlaylistNode, workspace: Workspace.ID) -> some View {
        if node.isFolder {
            // (Not tagged, so not to be chosen: a folder lists nothing of its own.)
            FolderRow(name: node.name)
        } else {
            PlaylistRow(name: node.name, count: node.entries.filter { $0.presentation != nil }.count)
                .tag(AppModel.Source.playlist(workspace: workspace, id: node.id))
        }
    }
}

/// The workspace shown, chosen from those found.
struct WorkspacePicker: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            if model.workspaces.isEmpty {
                Text(model.isFindingWorkspaces ? "Looking for workspaces…" : "No ProPresenter workspace found")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("Workspace", selection: $model.chosenWorkspace) {
                    ForEach(model.workspaces) { workspace in
                        WorkspaceLabel(workspace: workspace).tag(Optional(workspace.id))
                    }
                }
                .labelsHidden()
                .help(model.workspaces.first { $0.id == model.chosenWorkspace }.map(WorkspaceLabel.describe) ?? "")
            }
            Button { model.findWorkspaces() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.isFindingWorkspaces)
                .help("Look for ProPresenter's workspaces again, and read them again")
        }
    }
}

/// A workspace's name, with what kind it is and whether it is in use.
struct WorkspaceLabel: View {
    let workspace: Workspace

    var body: some View {
        Text(workspace.name) + Text("  " + Self.kind(workspace) + (workspace.isInUse ? " · in use" : "")).foregroundStyle(.secondary)
    }

    static func kind(_ w: Workspace) -> String {
        switch w.kind {
        case .database: return w.isCloud ? "Cloud" : "Database"
        case .folder: return "Folder"
        }
    }

    /// A sentence for the workspace, for its tooltip.
    static func describe(_ w: Workspace) -> String {
        let kind: String
        switch w.kind {
        case .database: kind = w.isCloud ? "A cloud workspace, kept in a database." : "A workspace kept in a database."
        case .folder: kind = "A workspace kept as a folder of files."
        }
        return kind + (w.isInUse ? " ProPresenter has it in use." : "") + "\n" + w.folder.path
    }
}

struct LibraryRow: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            LibraryIcon().frame(width: 16, height: 16)
            Text(name).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit().font(.callout)
        }
    }
}

struct PlaylistRow: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary).frame(width: 16)
            Text(name).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit().font(.callout)
        }
    }
}

struct FolderRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 16)
            Text(name).lineLimit(1)
        }

    }
}

struct AddedRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary).frame(width: 16)
            Text("Added").lineLimit(1)
            Spacer(minLength: 4)
            if count > 0 { Text("\(count)").foregroundStyle(.secondary).monospacedDigit().font(.callout) }
        }
        .help("Presentation files dropped on the window or added with Add…")
    }
}

struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text).foregroundStyle(.tertiary).selectionDisabled()
    }
}
