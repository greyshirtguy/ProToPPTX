// VideoStills: a still and a length for every video in a deck.
//
// PowerPoint shows a video as a picture until it plays, and will not open a deck whose
// video has none; and to start a video by itself it wants to know how long it runs.
// ProPresenter keeps neither in the presentation. AVFoundation gives both, from the file
// itself: the still is taken a moment in (the very first frame of a video is often
// black), or at ProPresenter's own thumbnail position when the presentation says one.
//
// A video inside a .probundle is copied out to a temporary folder for AVFoundation to
// read, and the folder is removed when the work is done. A video that cannot be read
// keeps no still, and the writer then leaves it out and says so.

@preconcurrency import AVFoundation
import DeckModel
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VideoStills {
    static func prepare(_ deck: Deck) -> Deck {
        var deck = deck
        var made: [MediaSource: (still: MediaSource?, duration: Double?)] = [:]
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ProToPPTX-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        func fill(_ media: inout Media) {
            guard media.kind == .video, media.still == nil, !media.isMissing else { return }
            if made[media.source] == nil { made[media.source] = still(of: media, temporary: temporary) }
            media.still = made[media.source]?.still
            media.duration = made[media.source]?.duration
        }

        for s in deck.slides.indices {
            if var bg = deck.slides[s].background {
                fill(&bg.media)
                deck.slides[s].background = bg
            }
            for i in deck.slides[s].items.indices {
                if case .video(var v) = deck.slides[s].items[i] {
                    fill(&v.media)
                    deck.slides[s].items[i] = .video(v)
                }
            }
        }
        return deck
    }

    private static func still(of media: Media, temporary: URL) -> (MediaSource?, Double?) {
        let url: URL
        switch media.source {
        case .file(let u):
            url = u
        case .zipEntry, .data:
            guard let data = try? media.source.load() else { return (nil, nil) }
            try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            url = temporary.appendingPathComponent("\(UUID().uuidString).\(media.fileExtension.isEmpty ? "mov" : media.fileExtension)")
            guard (try? data.write(to: url)) != nil else { return (nil, nil) }
        case .missing:
            return (nil, nil)
        }

        let work = StillWork(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [work] in
            await work.run()
            semaphore.signal()
        }
        semaphore.wait()
        let seconds = work.seconds
        let image = work.image

        guard let image else { return (nil, seconds) }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return (nil, seconds) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return (nil, seconds) }
        return (.data(out as Data, id: "still:\(media.fileName):\(media.source.hashValue)"), seconds)
    }
}

/// AVFoundation's asynchronous loading, waited on from the synchronous conversion. The
/// one task that touches it runs alone, so sharing it with that task is safe.
private final class StillWork: @unchecked Sendable {
    let asset: AVURLAsset
    let generator: AVAssetImageGenerator
    var seconds: Double?
    var image: CGImage?

    init(url: URL) {
        asset = AVURLAsset(url: url)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
    }

    func run() async {
        if let d = try? await asset.load(.duration), d.isNumeric { seconds = d.seconds }
        let at = CMTime(seconds: min(1, (seconds ?? 2) / 2), preferredTimescale: 600)
        image = try? await generator.image(at: at).image
    }
}
