#!/bin/sh
# Makes the Swift code that reads a ProPresenter presentation
# (Sources/ProFormat/Generated), from the descriptions of the format in the proto/
# submodule (greyshirtguy/ProPresenter7-Proto, its autogen-proto folder: the set taken
# from ProPresenter itself). This is the command that made that code; run it again when
# the submodule moves on.
#
#     Core/generate-proto.sh
#
# Why the code is kept in the repository and not made at each build: swift-protobuf's
# build plug-in only takes .proto files that are inside the package, and these are in a
# submodule outside it. Kept, the package builds from a clone with no submodule and no
# protoc. The price is that this must be run again by hand when the submodule moves on,
# which MadeFrom.swift is there to show: it says what the code beside it was made from.
#
# Only what this app reads is generated: a presentation (presentation.proto), a folder
# workspace's playlists (PlaylistDocument, in propresenter.proto), and everything they
# import, worked out by protoc itself so that the list cannot go stale. (The same
# approach as Pro7ChordEditor's mac/Core/generate-proto.sh, which this was copied from.)
#
# Beside the code, the same descriptions as data (Descriptions.swift): a workspace kept
# in a database keeps each document as a tree whose parts are named as the messages'
# fields are, and that tree is made into a message by going through the message's own
# description (Workspaces/LoroMessage.swift), which the generated code does not keep.
#
# protoc will warn, once for nearly every file, that an import of customOptions.proto
# is unused. It is, and it does no harm: the descriptions are taken out of ProPresenter
# by a program, which leaves those lines in.
#
# Needs protoc and protoc-gen-swift (`brew install protobuf swift-protobuf`), and the
# submodule (`git submodule update --init`). The library the code is built against
# (Package.swift) must not be older than the protoc-gen-swift that made it.
set -eu

ROOTS="presentation.proto propresenter.proto"

HERE=$(cd "$(dirname "$0")" && pwd)
PROTO="$HERE/../proto/autogen-proto"
OUT="$HERE/Sources/ProFormat/Generated"

command -v protoc >/dev/null || { echo "protoc is not installed: brew install protobuf" >&2; exit 1; }
command -v protoc-gen-swift >/dev/null || { echo "protoc-gen-swift is not installed: brew install swift-protobuf" >&2; exit 1; }
[ -f "$PROTO/presentation.proto" ] || { echo "proto/ is empty: run git submodule update --init" >&2; exit 1; }
[ -d "$OUT" ] || { echo "there is no $OUT to write into" >&2; exit 1; }

# Every file the roots import, by way of protoc's own account of them. The names of the
# files are the only lines of that account indented by exactly two spaces and starting
# `name:`. Google's own files are left out: the library has those already.
# shellcheck disable=SC2086
FILES=$(protoc -I "$PROTO" --include_imports --descriptor_set_out=/dev/stdout $ROOTS \
    | protoc -I "$PROTO" --decode google.protobuf.FileDescriptorSet google/protobuf/descriptor.proto \
    | sed -n 's/^  name: "\(.*\)"$/\1/p' \
    | grep -v '^google/protobuf/' \
    | sort)
[ -n "$FILES" ] || { echo "protoc named no files" >&2; exit 1; }

# Made in a folder of its own first, so that a failure leaves what was there alone.
NEW=$(mktemp -d)
trap 'rm -rf "$NEW"' EXIT
# shellcheck disable=SC2086
protoc -I "$PROTO" --swift_out="$NEW" --swift_opt=Visibility=Public $FILES

# The descriptions as data: every file above and Google's that they import, as one
# FileDescriptorSet, kept as Base64 text so that it is plain Swift.
# shellcheck disable=SC2086
protoc -I "$PROTO" --include_imports --descriptor_set_out="$NEW/descriptions.pb" $FILES
{
    echo "// The descriptions of the messages the code beside this was made from, as a"
    echo "// FileDescriptorSet in Base64. Written by generate-proto.sh: do not edit it, run that"
    echo "// again."
    echo
    echo "/// What ProPresenter's messages are made of, field by field, for reading a message out of"
    echo "/// something other than its own bytes."
    echo "public enum Descriptions {"
    echo "    /// The FileDescriptorSet, Base64."
    printf '    public static let fileDescriptorSet = "'
    base64 < "$NEW/descriptions.pb" | tr -d '\n'
    echo '"'
    echo "}"
} > "$NEW/Descriptions.swift"

rm -f "$OUT"/*.pb.swift "$OUT/Descriptions.swift"
cp "$NEW"/*.pb.swift "$NEW/Descriptions.swift" "$OUT"/

cat > "$OUT/MadeFrom.swift" <<EOF
// What the code in this folder was made from. Written by generate-proto.sh, with the
// rest of the folder: do not edit it, run that again.

/// What the generated reader of ProPresenter's files was made from, and with what.
public enum MadeFrom {
    /// The version of ProPresenter the descriptions were taken from (proto/autogen-proto/version.txt).
    public static let proPresenterVersion = "$(tr -d '[:space:]' < "$PROTO/version.txt")"
    /// The commit of the proto/ submodule.
    public static let protoCommit = "$(git -C "$HERE/../proto" rev-parse --short HEAD)"
    /// The generator.
    public static let generator = "$(protoc-gen-swift --version), $(protoc --version)"
    /// How many .proto files the code was made from.
    public static let fileCount = $(echo "$FILES" | wc -l | tr -d ' ')
}
EOF

echo "$(echo "$FILES" | wc -l | tr -d ' ') files, from ProPresenter $(tr -d '[:space:]' < "$PROTO/version.txt"), into $OUT"
