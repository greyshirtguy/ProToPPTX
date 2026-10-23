// MediaLayers: what media ProPresenter has on screen at each slide, when the slides are
// clicked through in order.
//
// This is the reason for the app's main option. In ProPresenter a slide's media cue
// puts a picture or video on the media layer, and it stays there while later slides
// with no media cue of their own are clicked: their words go up over the same
// background. PowerPoint has no such layer: each slide shows only what is on it. So
// the deck would show the background on the slide whose cue put it there and on no
// other. With "keep background media" on, each slide is given the background that
// would be on screen, as if the slides were clicked through in order.
//
// The rules, as ProPresenter is understood to work:
//
// - KNOWN: a media action whose layer is Background (the default, and what the
//   maintainer's presentations nearly all use) replaces what is on the background layer
//   and stays until something else replaces or clears it.
// - KNOWN: a Clear action whose target is All or Background (Media) takes it off.
// - A GUESS: a media action on the Foreground layer is shown with its own slide only,
//   and leaves the background that was up before it to come back on the next slide.
//   (Asked of the maintainer: see docs/NOTES.md.) Its picture is drawn over the
//   background and under the slide's own words.
// - A GUESS: Fill and Input layers are taken as Background.
// - NOT KNOWN: what a macro does. Macros are kept in ProPresenter's settings, not in the
//   presentation, so one that clears the background, or puts one up, cannot be
//   followed. They are listed in the report so the person can check those slides.
// - Audio cues are not pictures and are not carried on; they are noted in the report.
// - A slide that is turned off cannot be clicked in ProPresenter, so it changes nothing
//   here either, when such slides are left out (the default). When they are put in,
//   they are taken as clicked in their place.

import Foundation
import ProFormat

/// A media action of a cue, with the media it plays.
struct MediaCue {
    enum Layer { case background, foreground }

    let media: RVData_Media
    let layer: Layer
    let action: RVData_MediaAction
    /// The number, from 1, of the slide (as written) whose cue it is.
    let slideNumber: Int
}

typealias RVData_MediaAction = RVData_Action.MediaType

struct MediaLayers {
    /// What the background layer has on it now.
    private(set) var background: MediaCue?

    /// What one slide shows of the media layers.
    struct Shown {
        /// The background media of the slide's own cue, if it has one.
        var own: MediaCue?
        /// What is on the background layer while the slide is up: its own, or one left
        /// there by an earlier slide.
        var live: MediaCue?
        /// Foreground media of the slide's own cue.
        var foreground: MediaCue?
        /// True if the cue cleared the background layer (and so shows none, carried or not).
        var cleared: Bool
        /// Names of the cue's macros: they may change the media layers in ways this cannot see.
        var macros: [String]
        /// File names of the cue's audio.
        var audio: [String]
    }

    /// Takes one slide's actions as ProPresenter would when it is clicked.
    mutating func click(_ cue: RVData_Cue, slideNumber: Int) -> Shown {
        var shown = Shown(own: nil, live: nil, foreground: nil, cleared: false, macros: [], audio: [])
        for action in cue.actions where action.isEnabled {
            switch action.type {
            case .media:
                let mediaAction = action.media
                let media = mediaAction.element
                switch ProSource.kind(of: media) {
                case .audio?:
                    shown.audio.append(ProSource.fileName(of: media))
                    continue
                case .image?, .video?:
                    break
                case nil:
                    // Live video and web pages: nothing to put on a slide.
                    continue
                }
                let layer: MediaCue.Layer = mediaAction.layerType == .foreground ? .foreground : .background
                let found = MediaCue(media: media, layer: layer, action: mediaAction, slideNumber: slideNumber)
                if layer == .background {
                    background = found
                    shown.own = found
                    shown.cleared = false
                } else {
                    shown.foreground = found
                }
            case .clear:
                switch action.clear.targetLayer {
                case .all, .background:
                    background = nil
                    shown.own = nil
                    shown.foreground = nil
                    shown.cleared = true
                default:
                    break
                }
            case .macro:
                shown.macros.append(action.macro.identification.parameterName.isEmpty ? action.name : action.macro.identification.parameterName)
            default:
                break
            }
        }
        shown.live = background
        return shown
    }
}
