// protopptx: the command line. So far: `convert` and `preview` of a presentation file,
// `workspaces`, which lists ProPresenter's workspaces on this Mac as the window shows
// them, and `export`, which writes a library's or a playlist's presentations, each with
// every option the window has (docs/OPTIONS.md). What is still to come is described
// there too.

import AppKit
import Conversion
import DeckModel
import DeckPreview
import Foundation
import Workspaces

let args = CommandLine.arguments

func usage() -> Never {
    print("""
    usage: protopptx convert <presentation.pro|.probundle> [-o <output.pptx>] [options]
           protopptx preview <presentation.pro|.probundle> <folder for pictures> [options]
           protopptx workspaces
           protopptx export <workspace> (--library <name> | --playlist <name>) [--presentation <name>]
                            -o <folder> [options]
    options: --no-carry-backgrounds  --backgrounds-as-pictures  --include-disabled
             --no-notes  --no-sections  --ignore-arrangement  --videos embed|stillOnly|leaveOut
    """)
    exit(2)
}

guard args.count >= 2 else { usage() }

if args[1] == "workspaces" {
    listWorkspaces()
    exit(0)
}

guard args.count >= 3 else { usage() }
let input = URL(fileURLWithPath: args[2])

// The options, one flag each, as docs/OPTIONS.md lists them.
var options = ConversionOptions()
var k = 3
while k < args.count {
    switch args[k] {
    case "--no-carry-backgrounds": options.carryBackgroundForward = false
    case "--backgrounds-as-pictures": options.backgroundPlacement = .pictureAtBack
    case "--include-disabled": options.skipDisabledSlides = false
    case "--no-notes": options.includeNotes = false
    case "--no-sections": options.groupsAsSections = false
    case "--ignore-arrangement": options.followArrangement = false
    case "--videos":
        k += 1
        guard k < args.count, let v = ConversionOptions.VideoHandling(rawValue: args[k]) else { usage() }
        options.videos = v
    case "-o", "--library", "--playlist", "--presentation": k += 1
    default: if !(["preview", "export"].contains(args[1]) && k == 3) { usage() }
    }
    k += 1
}

/// The value after a flag, if the flag is there.
func value(of flag: String) -> String? {
    guard let k = args.firstIndex(of: flag), k + 1 < args.count else { return nil }
    return args[k + 1]
}

do {
    switch args[1] {
    case "convert":
        var output = input.deletingLastPathComponent().appendingPathComponent(Converter.defaultOutputName(for: input))
        if let o = args.firstIndex(of: "-o"), o + 1 < args.count { output = URL(fileURLWithPath: args[o + 1]) }
        let notes = try Converter.convert(input, to: output, options: options)
        print("Wrote \(output.path)")
        for note in notes { print("  \(note.message)\(note.slides.isEmpty ? "" : " (\(note.slidesText))")") }
    case "preview":
        guard args.count >= 4 else { usage() }
        let folder = URL(fileURLWithPath: args[3])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = try Converter.load(input, options: options)
        let renderer = SlideRenderer()
        for (k, slide) in result.deck.slides.enumerated() {
            guard let image = renderer.render(slide, deckSize: result.deck.size, pixelWidth: 1920) else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("\(k + 1).png"))
            let bg = slide.background.map { "\($0.media.fileName)\($0.isCarriedOver ? " (carried from \($0.fromSlide ?? 0))" : "")" } ?? "-"
            print("\(k + 1)\t\(slide.caption)\tbackground: \(bg)\titems: \(slide.items.count)")
        }
        for note in result.notes { print("  \(note.message)\(note.slides.isEmpty ? "" : " (\(note.slidesText))")") }
    case "export":
        try export(workspaceNamed: args[2], options: options)
    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("protopptx: \(error)\n".utf8))
    exit(1)
}

// MARK: - Workspaces

/// Every workspace, with its libraries and playlists, as the window lists them.
@MainActor func listWorkspaces() {
    let workspaces = WorkspaceFinder.onThisMac().workspaces()
    if workspaces.isEmpty { print("No ProPresenter workspace found on this Mac.") }
    for workspace in workspaces {
        let kind = workspace.kind == .database ? (workspace.isCloud ? "cloud" : "database") : "folder"
        print("\(workspace.name)  (\(kind)\(workspace.isInUse ? ", in use" : ""))  \(workspace.folder.path)")
        do {
            let contents = try WorkspaceReader.contents(of: workspace)
            for library in contents.libraries {
                print("  library  \(library.name)  (\(library.presentations.count))")
            }
            func show(_ node: PlaylistNode, depth: Int) {
                let indent = String(repeating: "  ", count: depth)
                if let children = node.children {
                    print("\(indent)  folder   \(node.name)")
                    for child in children { show(child, depth: depth + 1) }
                } else {
                    print("\(indent)  playlist \(node.name)  (\(node.entries.filter { $0.presentation != nil }.count))")
                }
            }
            for node in contents.playlists { show(node, depth: 0) }
        } catch {
            print("  could not be read: \(error)")
        }
    }
}

/// Writes a library's or a playlist's presentations (or one of them) into the folder
/// `-o` names: a playlist's numbered in its order, each with the arrangement its item
/// chose, as the window's Export All does.
func export(workspaceNamed name: String, options: ConversionOptions) throws {
    let workspaces = WorkspaceFinder.onThisMac().workspaces()
    guard let workspace = workspaces.first(where: { $0.name == name }) ?? workspaces.first(where: { $0.name.lowercased() == name.lowercased() }) else {
        throw CommandLineError("there is no workspace named \"\(name)\" (protopptx workspaces lists them)")
    }
    guard let out = value(of: "-o") else { usage() }
    let contents = try WorkspaceReader.contents(of: workspace)
    var jobs: [(ref: PresentationRef, arrangement: String?)] = []
    var numbered = false
    if let libraryName = value(of: "--library") {
        guard let library = contents.libraries.first(where: { $0.name.lowercased() == libraryName.lowercased() }) else {
            throw CommandLineError("\(workspace.name) has no library named \"\(libraryName)\"")
        }
        jobs = library.presentations.map { ($0, nil) }
    } else if let playlistName = value(of: "--playlist") {
        guard let playlist = contents.playlists.flatMap(\.allPlaylists).first(where: { $0.name.lowercased() == playlistName.lowercased() }) else {
            throw CommandLineError("\(workspace.name) has no playlist named \"\(playlistName)\"")
        }
        jobs = playlist.entries.compactMap { entry in entry.presentation.map { ($0, entry.arrangement) } }
        numbered = true
    } else {
        usage()
    }
    if let only = value(of: "--presentation") {
        jobs = jobs.filter { $0.ref.name.lowercased() == only.lowercased() }
        guard !jobs.isEmpty else { throw CommandLineError("there is no presentation named \"\(only)\" there") }
        numbered = false
    }
    let folder = URL(fileURLWithPath: out, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let width = max(2, String(jobs.count).count)
    var failed = 0
    for (k, job) in jobs.enumerated() {
        var file = Converter.defaultOutputName(named: job.ref.name)
        if numbered {
            let number = String(k + 1)
            file = String(repeating: "0", count: width - number.count) + number + " " + file
        }
        let output = folder.appendingPathComponent(file)
        do {
            let loaded = try Converter.load(job.ref, arrangement: job.arrangement, options: options)
            let notes = try Converter.write(loaded, to: output, options: options)
            print("Wrote \(output.path)")
            for note in notes { print("  \(note.message)\(note.slides.isEmpty ? "" : " (\(note.slidesText))")") }
        } catch {
            failed += 1
            FileHandle.standardError.write(Data("protopptx: \(job.ref.name): \(error)\n".utf8))
        }
    }
    if failed > 0 { exit(1) }
}

struct CommandLineError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
