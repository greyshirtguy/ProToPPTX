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

## Building

```
git submodule update --init       # ProPresenter's file formats, in proto/
swift test --package-path Core    # the core, and its tests
xcodegen                          # makes ProToPPTX.xcodeproj from project.yml
open ProToPPTX.xcodeproj          # the app
```

For macOS 15 and later, built with Xcode 26.
