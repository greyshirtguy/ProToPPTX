# ProPresenter's workspaces

How this app finds ProPresenter's workspaces on a Mac and reads their libraries,
playlists and presentations. Found on the maintainer's Mac in October 2026, with
ProPresenter 21.4 and the 22.7 beta installed side by side, by reading only. Marked
KNOWN where read or measured, A GUESS where reasoned, NOT KNOWN where open, as
`docs/NOTES.md` is.

What it says of the versions after 21 was found on a beta (22.7), and was published
once the maintainer said that version had been announced (2026-10-23). A released
version may differ.

## Two kinds

| | A folder | A database |
| --- | --- | --- |
| Kept by | ProPresenter 7 up to 21 (and the versions after can open one) | The versions after 21 |
| Where | `UserWorkspaces/<name>` in ProPresenter's folder; before workspaces, `Documents/ProPresenter` | `Workspaces/<id>` in ProPresenter's folder |
| A presentation | `Libraries/<library>/<name>.pro`, a protobuf `rv.data.Presentation` | A row of `DocumentStore/workspace-v1.sqlite3`: a Loro document |
| The playlists | `Playlists/Library`, a protobuf `rv.data.PlaylistDocument` | The row of kind `PlaylistLibrary`: a Loro document |
| Media | `Media/Assets/…` in the workspace's folder | The same |

ProPresenter's folder is `~/Library/Application Support/RenewedVision/ProPresenter`. The
versions share one set of settings, `com.renewedvision.propresenter`.

KNOWN: the first time a version after 21 opens a folder workspace, it copies it into a
new database workspace and leaves the folder as it was (the registry's `meta` table
then says `copied_from:<id>`, with the folder). So the same presentations can be on one
Mac twice, once of each kind, and then go their own ways.

## Finding them

`Core/Sources/Workspaces/WorkspaceFinder.swift`, in this order, each folder once:

1. KNOWN: the registry of the versions after 21, `Workspaces/registry-v1.sqlite3`.
   Table `workspaces(local_uuid, root_path, display_name, cloud_uuid, schema_version,
   availability)`, one row each; table `meta`, whose `active_local_uuid` is the one in
   use. It lists its database workspaces and any folder workspace it has opened as a
   folder (`schema_version` 22.0.0, no cloud id, on the maintainer's Mac). A
   `cloud_uuid` means the workspace is kept in step with ProPresenter's cloud.
2. A GUESS: any `Workspaces/<id>` with a `DocumentStore/workspace-v1.sqlite3` that the
   registry does not list.
3. KNOWN: version 21's setting `userWorkspaces`: JSON, kept as data, a list of `name`,
   `url` (the folder) and `isActive` (and, since 22, `minimumRequiredProPresenterVersion`).
4. A GUESS: the folder the setting `applicationShowDirectory` names (with 21 it names the
   workspace in use; before workspaces, where the one folder was moved to).
5. `Documents/ProPresenter`, the folder from before workspaces.

A folder with neither `Libraries` nor a `DocumentStore` is left out. The settings are
read with `CFPreferencesCopyAppValue`, which only reads.

**KNOWN: the registry kept all of its rows in its write-ahead log.** It was 4 KB of
database and 125 KB of `-wal`, and opened unchangeable (`immutable=1`) it had not even
its tables. Opened the ordinary way, even only to read, SQLite may write the
shared-memory file beside it. So every SQLite file of ProPresenter's is copied, with its
`-wal`, into a folder of this app's own, and the copy is read
(`Workspaces/SQLiteReader.swift`); the copy is made again if the files change while it
is made, and a workspace's store again whenever its size or date has changed since.

## A database workspace

`DocumentStore/workspace-v1.sqlite3`, table `workspace_streams`, one row for each
document and scope:

| Column | |
| --- | --- |
| `document_id` | 16 bytes. KNOWN: a presentation's is its own id |
| `scope` | 0 for what is shared; 1 for this Mac's own (which playlists are open, and so on) |
| `kind` | `Presentation`, `PlaylistLibrary`, `LibraryData`, `Theme`, `Workspace`, `Macros`, … |
| `location_type`, `core_path` | For a presentation, 1 and `<library>/<name>` (no ending); `core_path_key` is it in small letters |
| `availability` | 1 for a document the cloud has and this Mac has not yet (no snapshot) |
| `snapshot` | The document: a Loro snapshot |

Beside it, things this app does not read: `version_vector`, `sha256`, receipts of
operations, and in the folder `media-projection-cache-v1.json` (where each media file
a document names is) and `MediaStore`.

### Loro

KNOWN: every snapshot starts `loro`: it is a [Loro](https://loro.dev) document, a kind
that several people can change at once and that is merged afterwards. Loro describes
its binary format itself (`docs/encoding*.md` in github.com/loro-dev/loro), and
`Core/Sources/LoroKit` reads it from that description: the envelope and its xxHash32
checksum, the state table (an SSTable of LZ4-compressed blocks), and each container's
value (maps, lists, movable lists, trees, texts, counters), not its history. Loro's
"mergeable" children (a container named by where it is: KNOWN, the playlists are one)
are read as Loro's source code makes them.

Checked: every one of the 106 documents of the maintainer's database workspace reads to
the same JSON as Loro's own JavaScript package (loro-crdt 1.16.3) reads out of it. The
repository's tests check made-up documents the same way (`testdata/loro`).

### A presentation

KNOWN: the root map `root` is the presentation's protobuf message, part for part, named
as the message's fields are named in the descriptions (`proto/autogen-proto`).
`Workspaces/LoroMessage.swift` makes the message of it by going through those
descriptions (generated as data with the code, `Core/generate-proto.sh`), and undoes
what differs:

- An id (`rv.data.UUID`) is its text.
- A oneof is a part named for the oneof, with `__tag` naming the field chosen.
- A message field not set is null; a field at its default is there.
- A few names differ from 21.4's (`hot_key` for `hotKey`): matched without underscores
  or case.
- An arrangement's groups are `group_identifiers_v2`, and 21.4's `group_identifiers`
  is not there.
- The slides (`cues`) are a map, by id.
- The groups are a Loro tree, `cue_group_placements`, in place of `cue_groups`: each
  top node a group (its `meta` the group's id, and under `Kind`/`group` its name and
  colour), each node under it a slide of the group, in order
  (`Workspaces/PresentationTree.swift`).
- A media item has no URL of its own; its image's or video's `file.local_url` names it
  in the workspace (ROOT_SHOW, `Media/Assets/…`).
- New since 21.4, and not read: a media item's `asset_id` and
  `identity_schema_version`, an image's or video's `source`,
  `element_build_order_v2`, `value_array_migration_version`.
- Gone since 21.4, and not used by this app: `is_superscript_standardized`, a video's
  `should_fade_in` and `should_fade_out`, the document's `application_info`; a text
  scroller's `repeat_distance` is in other units.

KNOWN: the version after 21, copying a folder workspace, renames a presentation to its
file's name when the two differ (3 of 64 on the maintainer's Mac). The app names every
presentation in a workspace by its file's name (or its `core_path`'s), as ProPresenter
lists them.

**Checked: all 64 presentations of the maintainer's database workspace become the same
deck as the same presentation read from the folder workspace it was copied from**,
slide for slide, every text box, shape, picture and note, but for where each media file
is (each workspace has its own copy). (`Core/Tests/ConversionTests/RealWorkspacesTests.swift`,
run with `PROTOPPTX_REAL_WORKSPACES=1`.) On the way it found two things the app now does
for every presentation, of either kind (`docs/NOTES.md`): a media item with no type of
its own is taken as its file's ending says; and media named only by its whole path on
another Mac is looked for in the workspace's own `Media`.

### Libraries and playlists

- `LibraryData` lists the libraries: `root.rootLibrary`, its `libraryChildren`, each
  with a URL `Libraries/<library>`. Presentations are placed in them by their
  `core_path`.
- `PlaylistLibrary` (scope 0): `root.playlists`, a tree. Its top node is ProPresenter's
  root, not shown (KNOWN: it has the same id as the folder workspace's root playlist);
  under it folders (`Kind` `group`) and playlists (`Kind` `playlist`); under a playlist
  its items (`Kind` `item`, with `ItemType` as `rv.data.PlaylistItem` has it). A
  presentation item names its presentation by the path it had in the folder workspace,
  `Libraries/<library>/<name>.pro`, found by `core_path` without regard to case.

## A folder workspace

As Pro7ChordEditor's `spec/06-library.md` and Simple Presenter found it: each folder in
`Libraries` a library, each `.pro` directly in one a presentation, shown by its file
name. `Playlists/Library` is a `PlaylistDocument`: a root playlist, not shown, holding
folders (`playlists`) and playlists (`items`). A presentation item names its file by a
path in the workspace (ROOT_SHOW) and by the whole path it had where it was saved.

A GUESS: an item whose file is not where it says is looked for by its file's name, then
by its own name, among the libraries. (One item on the maintainer's Mac names a file
whose name starts with a dot, where the library has the presentation under another
name; it is shown as not found.)

## Playlists and arrangements

A playlist's item can choose an arrangement of the presentation. KNOWN (the
maintainer's playlist): 7 of its 19 items do, and 5 of those 7 presentations have none
chosen of their own. A presentation read from a playlist follows its item's choice (A
GUESS that ProPresenter plays it so from the playlist; it is what the item keeps it
for), or the presentation's own if the item's is not one it has.

## Not known

- How a released version keeps workspaces, and from which version number.
- Whether a slide can be at the top of the groups' tree, outside every group, or a group
  in a group (taken as: left out; one more group).
- What `element_build_order_v2` and `cue_identifiers_v2` (seen by Pro7ChordEditor) hold.
- Where a cloud workspace on a second Mac keeps media it has downloaded (`asset_id`,
  `MediaStore`, `Media/Downloads`): media is looked for in `Media` by path and by name.
- Windows: none of this was looked at there.
