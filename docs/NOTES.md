# What was found out

What these notes say about ProPresenter was found by reading the maintainer's
presentations (ProPresenter 21.4, 2026) and measuring ProPresenter's own exported slide
pictures against this app's drawing of the same slides, row of pixels by row of pixels.
What they say about PowerPoint was found the same way against PowerPoint 16 for the
Mac's PDF of the decks this app writes. Marked KNOWN where measured or read, A GUESS
where reasoned, NOT KNOWN where open.

## ProPresenter's files

- KNOWN: a `.probundle` is a zip: the `.pro` under its bare name, every media file under
  the whole path it had on the Mac that made the bundle, all stored (not compressed), no
  permissions, and a ZIP64 end record that ProPresenter also counts in the central
  directory's size (98 bytes too many). `ZipReader` reads by count, not by size.
- KNOWN: a slide lists its elements front to back: the first is on top.
- KNOWN: elements ProPresenter made from a PowerPoint slide say `opacity: 100` for
  opaque; its own say 1.
- KNOWN: fills, strokes, shadows and feathers each have `enable`; a disabled one is kept
  in the file but not drawn. (Text boxes made from PowerPoint carry a blue fill and a
  white stroke, both disabled.)
- KNOWN: a gradient whose stops all say position 0 is drawn as if spread evenly. Its
  angle is anticlockwise from the right, the first stop at the tail.
- KNOWN: RTF `\b` and `\i` mean "the family's bold (italic) face", as macOS reads them:
  `CMGSans-Regular` with `\b` is drawn in CMG Sans Bold.
- KNOWN: the text's own default font size for an empty last line is the one in force at
  the end of the RTF (a bug here once gave it 12 points, and moved centred text 35
  pixels).
- A GUESS: a foreground media cue shows with its own slide only; the background comes
  back on the next. Fill and Input layers are taken as Background.
- NOT KNOWN: what a macro does (its actions are in ProPresenter's settings, not the
  presentation). The maintainer's macros are all stream-look switches.

## ProPresenter's layout of text

Measured to the pixel on the maintainer's slides:

- Text starts 5 units in from each side of the box beyond its margins (macOS's text
  container padding), and 5 down from the top.
- A line's height is macOS's for the font (`NSLayoutManager.defaultLineHeight`): 1.2 ×
  the size for Helvetica, 1.22 for CMG Sans.
- Superscripts are drawn small (A GUESS: 0.6 of the size, raised 0.38) and do not make
  their line taller ("standardized superscripts" in the file).
- A line multiple other than 1: the lines are that many line heights apart. Where the
  extra space goes is NOT KNOWN in general:
  - Helvetica, multiple 1.5, top-aligned (four slides): all of it below each line,
    pixel exact.
  - CMG Sans Light, multiple 1.4, top-aligned (one slide): about half above
    (ProPresenter's first line is 13 pixels lower than "all below" puts it).
  - CMG Sans, multiple 0.9, centred (two slides): about half of the reduction is taken
    from above (ProPresenter's lines are 10 to 15 pixels lower than macOS's own layout).
  The code takes "all below" for now. A presentation made for the purpose (boxes in
  several fonts, multiples and alignments), exported to pictures by ProPresenter, would
  settle it.

## PowerPoint's layout of text

From a deck made for the purpose (`Core/Tests/ConversionTests/CalibrationDeck.swift`):
four fonts, two sizes, four multiples, top and centred.

- Given its line spacing as a percentage, PowerPoint for the Mac spaces lines 1.2 × the
  size × the percentage whatever the font, and puts the first baseline 0.9 × the size ×
  the percentage down. Given none, it uses the font's metrics, a few pixels from macOS's
  either way.
- Centred: the block it centres is its lines' spacing added up, less 0.4 × size ×
  (percentage − 1) when the percentage is over 1 (fitted; within 4 pixels).
- At a percentage near 100, the first baseline is a little lower than 0.9 × the size, by
  an amount that depends on the font (up to 9 pixels at 120 points in Helvetica Neue).
  NOT KNOWN why; left as it is.
- An inset less than nought is honoured, and kept; a paragraph's left margin (`marL`)
  less than nought is not valid, and makes PowerPoint offer to repair the whole deck.
  ProPresenter's text can reach left of its margin (RTF `\li-100`), so the writer moves
  the box's inset instead (2026-10-19, found by the maintainer in one of his decks).
- Its horizontal layout of the same words, in the same box, matches macOS's to the pixel.
- A face whose name table does not follow Office's four-faces rule (Apple's Helvetica
  Neue: "Condensed Black", "Medium") is found by its full name.

`PPTXWriter/TextFit.swift` uses all of this: each paragraph's percentage gives
ProPresenter's distance between lines exactly, and the first line is moved into place
with the insets.

## Checking that PowerPoint takes a deck

KNOWN (2026-10-19): a deck PowerPoint opens by AppleScript (`open`) is opened without
its "found a problem with content … Repair" prompt, whatever is wrong with it. Opened as
a double-click opens it (`open -a "Microsoft PowerPoint" deck.pptx`), the prompt comes,
and can be seen through System Events (the window's static text) and cancelled. So only
the second is a check that a deck is valid. `Core/Tests/TestSupport/OOXMLLint.swift`
checks the values the standard bounds without PowerPoint; the tests run it on every
deck they write.

## How the comparing was done

On the maintainer's Mac, with the scratch tools of the session that wrote this (not in
the repository): PowerPoint was driven by AppleScript to save a PDF of each deck, from
a folder inside its own sandbox (`~/Library/Containers/com.microsoft.Powerpoint/Data/
tmp`), since it asks for permission for any other; the PDF's pages were drawn to PNG
and compared with ProPresenter's exports, by the mean difference of the whole picture
and by rows of bright pixels.

Results, with "keep background media" off so that slides compare like for like:
across the four bundles that have exported pictures (95 slides), most slides' text is
within 0 to 4 pixels of ProPresenter's in PowerPoint; the exceptions are the three
slides of the multiple question above.
