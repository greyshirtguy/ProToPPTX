# For an AI model working in this repository

Read this before doing anything here. It is short on purpose; `docs/` has the rest.

## What this is

ProToPPTX turns ProPresenter presentations (`.pro`, and `.probundle`, a zip of a
presentation and its media) into PowerPoint files whose slides look the same as
ProPresenter shows them, slide for slide, with the words as text that can be edited
rather than as pictures of slides. It also finds ProPresenter's own workspaces on the
Mac, of both kinds (a folder of `.pro` files, and the newer database), and lists their
libraries and playlists to convert from (`docs/WORKSPACES.md`).

There are to be two front ends on one core: a Mac app (SwiftUI, `App/` and
`Core/Sources/AppViews`), and a command line (`Core/Sources/protopptx`) with exactly the
same options as the app. Everything either can choose is one value,
`ConversionOptions`; `docs/OPTIONS.md` lists each option and its flag.

It is one person's hobby, written by describing it to an AI model. Nobody supports it.
It is not ProPresenter and has nothing to do with Renewed Vision.

## What must stay true

1. **A presentation is only read.** Nothing here writes a `.pro` or a `.probundle`, or
   anything inside ProPresenter's folders. Its SQLite databases are copied, and the copy
   read (`Workspaces/SQLiteReader.swift` says why: opening one, even to read, can write
   beside it).
2. **Slide for slide.** Each slide ProPresenter would show, in the order it shows them,
   becomes one PowerPoint slide; what is on it is where ProPresenter puts it, as near
   as PowerPoint allows. Where the two cannot agree, say so in the report the person
   sees (`ConversionNote`), not silently.
3. **The words stay words.** Text goes over as text boxes with their fonts, sizes and
   colours, never as pictures.
4. **One set of options for both front ends.** An option the app has, the command line
   has, under the same name in `ConversionOptions` and a flag in `docs/OPTIONS.md`.
5. **What was measured is written down.** The places where ProPresenter and PowerPoint
   lay things out differently were found by measuring (`docs/NOTES.md`). A change to
   how text is placed is checked the same way before it goes in.

## The person's files

- The maintainer's real presentations sit beside the code in
  `Pro Bundles (Some with exported slides)/`. They are real church services: their
  words, pictures and names are never committed, pushed, put in a test, an issue, or a
  log pasted somewhere. `.gitignore` keeps the folder out; keep it so.
- Tests that use them (`Core/Tests/ConversionTests/RealBundlesTests.swift`) run only
  when asked (`PROTOPPTX_REAL_BUNDLES=1`) and print numbers, never words.
- ProPresenter's own workspaces on the Mac (in `~/Library/Application Support/
  RenewedVision/ProPresenter`) are the same: real services, read freely to check, never
  quoted. Their tests (`Core/Tests/ConversionTests/RealWorkspacesTests.swift`) run only
  when asked (`PROTOPPTX_REAL_WORKSPACES=1`) and print numbers.
- The one exception: `docs/images/screenshot.png`, the README's picture of the app,
  shows one of those presentations. It was put in at the maintainer's asking
  (2026-10-19), as his own picture; it is not a reason to put in anything else from
  them.
- Test data in the repository is made up (`testdata/`; `testdata/loro/make-fixtures.mjs`
  says how its Loro documents were made).
- Before deleting anything, look at what it is.

## How to work here

- `swift test --package-path Core` builds and proves everything without Xcode. The app
  is built from `project.yml` with XcodeGen (`xcodegen` in the top folder).
- Comment as the rest of the code does: every file opens by saying what it is and why
  it is the way it is; what is known about ProPresenter, what is a guess and what is not
  known is said where it matters, as KNOWN, A GUESS, NOT KNOWN. A comment that has
  become untrue is a bug.
- Never type a backslash, a `u` and four hex digits into a file through a tool call: it
  arrives as one character. Build such text from pieces (`"\\" + "u" + "8232"`).
- No new dependency without the maintainer agreeing to it first. swift-protobuf is the
  only one.
- Words the user reads say plainly what happened. They never promise help, and never
  call the app a product.

## Giving a build out

- **Nothing is published without the maintainer's word**: no tag, no release, no file
  added to one or taken down. Building a disk image for them to try publishes nothing.
- The version is `MARKETING_VERSION` in `project.yml`. `./make-dmg.sh` builds the
  Release and the image, and checks both; a release is the tag `v` and the version
  (`v0.1.0`) with that image as its file, and the README's "Try it" brought up to date
  in the same push.

## Where things are

| Path | What it is |
| --- | --- |
| `Core/` | The Swift package: everything but the app's `@main` (`Core/Package.swift` says what each library is) |
| `Core/Sources/LoroKit` | Reading a Loro document's state, written from Loro's own description of its format |
| `Core/Sources/Workspaces` | Finding ProPresenter's workspaces, and reading their libraries, playlists and presentations |
| `testdata/` | Made-up test data: `loro/` has Loro documents, with the JSON Loro itself reads from each |
| `App/` | The Mac app's start, Info.plist and icon (`ProToPPTX.icns`) |
| `App/Icon/` | What made the icon: the maintainer's picture and `make-icon.sh`; not built into the app |
| `project.yml` | XcodeGen's description of the Xcode project (and of the app's Info.plist, made from it) |
| `make-dmg.sh`, `dmg/` | The disk image a release carries, and the read-me in it |
| `proto/` | ProPresenter's file formats (a submodule: `git submodule update --init`); only `autogen-proto` is used, through `Core/generate-proto.sh`, which makes both the code and the descriptions as data |
| `docs/OPTIONS.md` | Every option, and its command-line flag |
| `docs/NOTES.md` | What was found out about ProPresenter's files and layout, and PowerPoint's |
| `docs/WORKSPACES.md` | What was found out about ProPresenter's workspaces, of both kinds |
