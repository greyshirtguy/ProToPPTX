// The Mac app of ProToPPTX: where it starts.
//
// The app is the thin thing on top. Everything it shows and does is in the package
// beside this folder (../Core): reading presentations, writing PowerPoint files, and the
// window itself, which is the library AppViews. What is here is only what an app must
// have and a package cannot: the place it starts, the menus it puts the window's actions
// in, and (in Info.plist) what it says of itself to macOS, such as which files it opens.
//
// One window: the list of presentations is the app. Closing it quits the app.

import AppKit
import AppViews
import SwiftUI

@main
struct ProToPPTXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("ProToPPTX", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    delegate.model = model
                    Snapshot.startIfAsked(model)
                }
        }
        .defaultSize(width: 1360, height: 860)
        .commands { AppCommands(model: model) }
    }
}

/// Presentations opened from the Finder (or dropped on the app's icon) go into the list.
/// The Finder can ask before the window is up, so they wait until it is.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel? {
        didSet {
            if let model, !waiting.isEmpty {
                model.add(waiting)
                waiting = []
            }
        }
    }

    @MainActor private var waiting: [URL] = []

    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.add(urls) } else { waiting.append(contentsOf: urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
