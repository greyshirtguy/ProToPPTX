// ConversionOptions: every choice the person can make about a conversion, in one value.
//
// Why it is here, in the lowest module but one: both sides read it (ProImport decides
// which slides and which media; PPTXWriter decides how a background is put on a slide),
// and both front ends set it: the window's settings, and the command line's flags. The
// command line is to have exactly the options the window has, each a flag of its own,
// so every option added here gets a line in docs/OPTIONS.md saying what its flag is to
// be. It is Codable so that the window can keep the last choices, and so that a set of
// options can be written down and handed to the command line as a file.
//
// The defaults are what the maintainer asked for at the start (2026-10-18): slide for
// slide as ProPresenter shows them, editable text, media cues kept, and background
// media carried on to the slides after it, as ProPresenter does when they are clicked
// through in order.

import Foundation

public struct ConversionOptions: Codable, Sendable, Equatable {
    /// How a picture behind the slide is put into PowerPoint.
    public enum BackgroundPlacement: String, Codable, Sendable, CaseIterable {
        /// As the slide's own background (Format Background): it cannot be clicked on or
        /// moved by mistake while the text is edited. Videos cannot go there and are
        /// always put in as `pictureAtBack`.
        case slideBackground
        /// As a picture at the back of the slide, which can be selected, moved and
        /// replaced like anything else.
        case pictureAtBack
    }

    /// What becomes of a video cue.
    public enum VideoHandling: String, Codable, Sendable, CaseIterable {
        /// The video file is put into the .pptx and plays when the slide comes up.
        case embed
        /// Only a still from the video is put in: a smaller file.
        case stillOnly
        /// Left out altogether.
        case leaveOut
    }

    /// Keep background media on following slides that have no media cue of their own,
    /// as ProPresenter does when the slides are clicked through in order.
    public var carryBackgroundForward: Bool = true
    public var backgroundPlacement: BackgroundPlacement = .slideBackground
    public var videos: VideoHandling = .embed
    /// Leave out slides that are turned off in ProPresenter (they cannot be shown there).
    public var skipDisabledSlides: Bool = true
    /// Put each slide's notes into PowerPoint's speaker notes.
    public var includeNotes: Bool = true
    /// Make ProPresenter's groups into PowerPoint sections.
    public var groupsAsSections: Bool = true
    /// When the presentation has an arrangement chosen, put the slides in its order
    /// (slides repeated as often as the arrangement repeats their group). Otherwise, and
    /// when this is off, every group once, in the order the presentation lists them.
    public var followArrangement: Bool = true

    public init() {}

    // Read leniently: an option missing from a saved set (one added since it was saved)
    // takes its default rather than making the whole set unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ConversionOptions.defaults
        carryBackgroundForward = try c.decodeIfPresent(Bool.self, forKey: .carryBackgroundForward) ?? d.carryBackgroundForward
        backgroundPlacement = try c.decodeIfPresent(BackgroundPlacement.self, forKey: .backgroundPlacement) ?? d.backgroundPlacement
        videos = try c.decodeIfPresent(VideoHandling.self, forKey: .videos) ?? d.videos
        skipDisabledSlides = try c.decodeIfPresent(Bool.self, forKey: .skipDisabledSlides) ?? d.skipDisabledSlides
        includeNotes = try c.decodeIfPresent(Bool.self, forKey: .includeNotes) ?? d.includeNotes
        groupsAsSections = try c.decodeIfPresent(Bool.self, forKey: .groupsAsSections) ?? d.groupsAsSections
        followArrangement = try c.decodeIfPresent(Bool.self, forKey: .followArrangement) ?? d.followArrangement
    }

    public static let defaults = ConversionOptions()
}
