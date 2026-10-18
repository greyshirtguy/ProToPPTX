# The options

Every choice the person can make about a conversion is a field of `ConversionOptions`
(`Core/Sources/DeckModel/ConversionOptions.swift`). The app shows each one; the command
line takes each one as a flag. Adding an option means adding it in all three places:
the struct, the app's settings, and a flag here and in `protopptx`.

| Option (`ConversionOptions`) | Default | In the app | Command-line flag |
| --- | --- | --- | --- |
| `carryBackgroundForward` | on | Keep background media on following slides | `--no-carry-backgrounds` turns it off |
| `backgroundPlacement` | `slideBackground` | Put background pictures: as the slide's background / as a picture at the back | `--backgrounds-as-pictures` |
| `videos` | `embed` | Videos: put the video in / a still only / leave out | `--videos embed\|stillOnly\|leaveOut` |
| `skipDisabledSlides` | on | Leave out slides turned off in ProPresenter | `--include-disabled` puts them in |
| `includeNotes` | on | Put slide notes into speaker notes | `--no-notes` |
| `groupsAsSections` | on | Make groups into PowerPoint sections | `--no-sections` |
| `followArrangement` | on | Follow the chosen arrangement | `--ignore-arrangement` |

## The command line today

`protopptx` exists so far for development, but already takes the flags above:

```
protopptx convert <presentation.pro|.probundle> [-o <output.pptx>] [flags]
protopptx preview <presentation.pro|.probundle> <folder> [flags]
```

`preview` draws each slide as the app's preview does, into numbered PNGs.

## For the command line still to come

- Many presentations at once (a folder, or several files), each to a `.pptx` beside it
  or into a folder given with `-o`.
- `--options <file.json>`: the options as the app saves them (`ConversionOptions` is
  Codable), so a set chosen in the app can be used in a script.
- The report (`ConversionNote`) as plain lines, or as JSON with `--json`, and an exit
  code that says whether anything was missing.
