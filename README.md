# ProToPPTX

Turns ProPresenter presentations (`.pro` and `.probundle`) into PowerPoint files that
look the same, slide for slide, with the words as text boxes that can be edited, not
pictures of slides.

- Each slide ProPresenter would show, in its order, with its text boxes, shapes and
  pictures where ProPresenter puts them, in the same fonts, sizes and colours.
- Media cues go over too: a slide's background picture or video goes behind it.
- **Keep background media on following slides**: in ProPresenter, a background stays up
  while the slides after it, with no media of their own, are clicked through. PowerPoint
  has no such thing, so by default each such slide is given the background that would
  be on screen.
- Notes go to the speaker notes; groups become PowerPoint sections.

A Mac app, and (to come) a command line with the same options (`docs/OPTIONS.md`).

It is one person's hobby. It is not ProPresenter and has nothing to do with Renewed
Vision.

## Try it

Download `ProToPPTX-mac-0.1.2.dmg` from
[the latest release](https://github.com/greyshirtguy/ProToPPTX/releases/latest), open it,
and drag ProToPPTX to Applications. It is not signed with an Apple developer
certificate, so the first time macOS will not open it at a double-click: open System
Settings, Privacy & Security, and click Open Anyway beside ProToPPTX (the read-me in the
image says it step by step). For macOS 15 and later, on Apple's chips and Intel's.

It only reads presentations; it never changes them.

## Building

```
git submodule update --init       # ProPresenter's file formats, in proto/
swift test --package-path Core    # the core, and its tests
xcodegen                          # makes ProToPPTX.xcodeproj from project.yml
open ProToPPTX.xcodeproj          # the app
```

For macOS 15 and later, built with Xcode 26. `./make-dmg.sh` builds the app as a Release
and makes the disk image a release carries (`build/ProToPPTX-mac-<version>.dmg`).

## Licence

MIT: see [LICENSE](LICENSE).
