// Snapshot: the window drawn into a picture file, for checking the app with no hand on
// a mouse (the model that builds this app cannot see the screen).
//
//     PROTOPPTX_OPEN="<file>\n<file>"  presentations to add at the start, one a line
//     PROTOPPTX_SNAPSHOT=<file.png>    when they are read and drawn, the window as a
//                                      picture, after which the app quits
//
// Neither is set when the app is used; nothing here runs then.

import AppKit
import Foundation

@MainActor
public enum Snapshot {
    /// Adds what PROTOPPTX_OPEN names, and arranges for the picture if one is asked for.
    public static func startIfAsked(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let open = env["PROTOPPTX_OPEN"] {
            model.add(open.split(separator: "\n").map { URL(fileURLWithPath: String($0)) })
        }
        guard let path = env["PROTOPPTX_SNAPSHOT"] else { return }
        Task {
            // Wait for every presentation to be read and its slides drawn.
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(250))
                let done = model.presentations.allSatisfy { item in
                    if case .reading = item.state { return false }
                    return item.thumbnails.count == (item.deck?.slides.count ?? 0)
                }
                if done { break }
            }
            try? await Task.sleep(for: .milliseconds(800))
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
               let view = window.contentView?.superview ?? window.contentView {
                write(view, to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    /// Draws the view's layers, as Core Animation has them, into a PNG: AppKit's own
    /// cacheDisplay leaves out the materials and glass the window is made of.
    static func write(_ view: NSView, to url: URL) {
        let scale = view.window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let layer = view.layer,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        context.scaleBy(x: scale, y: scale)
        if !view.isFlipped {
            // Core Animation draws with y down here; turn it the right way up.
        }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}
