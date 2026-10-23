// swift-tools-version: 6.1
//
// Everything of ProToPPTX that has no window in it, as one Swift package, so that it can
// be built and proved from the command line without Xcode ever being opened:
//
//     swift test --package-path Core
//
// The libraries, each knowing only of those above it in this list:
//
//   ZipKit       Reading and writing zip archives: a .probundle is one, and so is a
//                .pptx. Plain Swift and Apple's Compression; no other dependency.
//   LoroKit      Reading what a Loro document (loro.dev) holds, from a snapshot of it,
//                written from Loro's own description of its format; no other
//                dependency. ProPresenter's newer workspaces keep their documents so.
//   ProFormat    The reader of a .pro file, generated from the descriptions of
//                ProPresenter's format (generate-proto.sh). Nothing in it is written by
//                hand except the file that says so.
//   DeckModel    What goes on PowerPoint slides, said without PowerPoint's XML and
//                without ProPresenter's protobufs: slides, shapes, text runs, pictures,
//                media. The meeting point of the two sides.
//   DeckPreview  A Deck's slide drawn into a picture, for the window's preview and for
//                the tests to look at; and the measuring of text, with macOS's own text
//                system, which ProImport needs too.
//   Workspaces   ProPresenter's workspaces on this Mac, both kinds (folders of .pro
//                files, and databases of Loro documents), their libraries and
//                playlists, and a presentation in one read as ProPresenter's message.
//                It reads ProPresenter's databases with macOS's own SQLite, which is
//                no new dependency.
//   ProImport    A .pro, a .probundle, or a presentation from a workspace's
//                database, read into a Deck: the slides in the order
//                ProPresenter plays them, their text from its RTF, their media found,
//                and what background is on screen at each slide.
//   PPTXWriter   A Deck written out as a .pptx (Office Open XML). It measures text
//                with DeckPreview, to put PowerPoint's lines where ProPresenter's are.
//   Conversion   The one thing the window and the command line both call: options in,
//                a .pptx and a report of what could not be carried over out.
//   AppViews     The window, in SwiftUI, with no `@main` in it, so that `swift test`
//                can build it.
//
// And one executable, `protopptx`, the command line: the same Conversion with the same
// options as the window (docs/OPTIONS.md).
//
// The app (../App, made by ../project.yml) is a thin thing on top: the few lines that
// start it and show AppViews' window.
//
// swift-protobuf is the one dependency. Add no other without the maintainer's yes
// (AGENTS.md).

import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ZipKit", targets: ["ZipKit"]),
        .library(name: "LoroKit", targets: ["LoroKit"]),
        .library(name: "ProFormat", targets: ["ProFormat"]),
        .library(name: "Workspaces", targets: ["Workspaces"]),
        .library(name: "DeckModel", targets: ["DeckModel"]),
        .library(name: "ProImport", targets: ["ProImport"]),
        .library(name: "PPTXWriter", targets: ["PPTXWriter"]),
        .library(name: "DeckPreview", targets: ["DeckPreview"]),
        .library(name: "Conversion", targets: ["Conversion"]),
        .library(name: "AppViews", targets: ["AppViews"]),
        .executable(name: "protopptx", targets: ["protopptx"]),
    ],
    dependencies: [
        // Not older than the protoc-gen-swift that made Sources/ProFormat/Generated
        // (Generated/MadeFrom.swift says which that was).
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
    ],
    targets: [
        .target(name: "ZipKit"),
        .target(name: "LoroKit"),
        .target(
            name: "ProFormat",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .target(
            name: "Workspaces",
            dependencies: ["LoroKit", "ProFormat", .product(name: "SwiftProtobuf", package: "swift-protobuf")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "DeckModel", dependencies: ["ZipKit"]),
        .target(
            name: "ProImport",
            dependencies: [
                "ZipKit", "ProFormat", "DeckModel", "DeckPreview",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(name: "PPTXWriter", dependencies: ["ZipKit", "DeckModel", "DeckPreview"]),
        .target(name: "DeckPreview", dependencies: ["DeckModel"]),
        .target(name: "Conversion", dependencies: ["ProImport", "PPTXWriter", "DeckModel", "DeckPreview", "Workspaces"]),
        .target(name: "AppViews", dependencies: ["Conversion", "ProImport", "DeckModel", "DeckPreview", "Workspaces"]),
        .executableTarget(name: "protopptx", dependencies: ["Conversion", "Workspaces"]),

        // Where the tests find what they test against. Not a test target itself.
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "ZipKitTests", dependencies: ["ZipKit", "TestSupport"]),
        .testTarget(name: "LoroKitTests", dependencies: ["LoroKit", "TestSupport"]),
        .testTarget(
            name: "WorkspacesTests",
            dependencies: [
                "Workspaces", "LoroKit", "ProFormat", "Conversion", "DeckModel", "TestSupport",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "ProImportTests",
            dependencies: [
                "ProImport", "ProFormat", "DeckModel", "ZipKit", "TestSupport",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(name: "PPTXWriterTests", dependencies: ["PPTXWriter", "DeckModel", "ZipKit", "TestSupport"]),
        .testTarget(name: "AppViewsTests", dependencies: ["AppViews", "Conversion", "DeckModel", "Workspaces", "TestSupport"]),
        .testTarget(
            name: "ConversionTests",
            dependencies: ["Conversion", "ProImport", "ProFormat", "DeckModel", "DeckPreview", "ZipKit", "Workspaces", "TestSupport"]
        ),
    ]
)
