#!/bin/sh
# Makes a disk image of the Mac app to give to other people:
#
#     ./make-dmg.sh              writes build/ProToPPTX-mac-<version>.dmg
#
# The same steps as Pro7ChordEditor's mac/make-dmg.sh, which this was copied from; that
# script's head says why each is there. In short, stopping at the first thing that is
# not as it should be:
#
#   1. Makes the Xcode project from project.yml (XcodeGen), and builds the app as a
#      Release for both kinds of Mac (Apple's chips and Intel's), in a build folder of
#      its own, without leave to be debugged (get-task-allow), and stripped of what a
#      debugger goes by (which names the folders of the Mac it was built on).
#   2. Looks at what it built: its version, both kinds of Mac, its signature, that it
#      has no leave to be debugged, and that nothing in it names a folder of this Mac.
#   3. Lays out a folder: the app, a way to Applications to drag it onto, and the
#      read-me kept in dmg/.
#   4. Makes a compressed image of it, mounts it, and holds the app in it against the
#      one that was built.
#
# The version is MARKETING_VERSION in project.yml: change it there, not here.
#
# It is signed "to run locally" (ad hoc), which names no one, and Apple has not
# checked it: on another Mac the person has to allow it once in System Settings, and
# the read-me says how. With a Developer ID it would be signed with it, notarized
# (xcrun notarytool submit … --wait) and stapled (xcrun stapler staple); none of that
# is here yet.
#
# Needs Xcode and XcodeGen (brew install xcodegen); hdiutil, codesign, lipo and
# PlistBuddy come with macOS.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
BUILD="$HERE/build"
DERIVED="$BUILD/ReleaseData"
NAME="ProToPPTX"
APP="$DERIVED/Build/Products/Release/$NAME.app"
README="$HERE/dmg/Read Me First.txt"

[ -f "$README" ] || { echo "there is no $README to put in the image" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "XcodeGen is not installed: brew install xcodegen" >&2; exit 1; }
mkdir -p "$BUILD"

echo "Making the project, and building the app..."
(cd "$HERE" && xcodegen -q)
xcodebuild \
    -project "$HERE/ProToPPTX.xcodeproj" \
    -scheme ProToPPTX \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    DEPLOYMENT_POSTPROCESSING=YES \
    STRIP_INSTALLED_PRODUCT=YES \
    build > "$BUILD/build.log" 2>&1 || { tail -40 "$BUILD/build.log" >&2; echo "the build failed: all of what it said is in $BUILD/build.log" >&2; exit 1; }
[ -d "$APP" ] || { echo "the build did not leave $APP" >&2; exit 1; }

# ---- What was built
PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
NEEDS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST")
ARCHS=$(lipo -archs "$APP/Contents/MacOS/$NAME")
case "$ARCHS" in *arm64*) ;; *) echo "the app was not built for Apple's own chips: $ARCHS" >&2; exit 1 ;; esac
case "$ARCHS" in *x86_64*) ;; *) echo "the app was not built for Intel's chips: $ARCHS" >&2; exit 1 ;; esac
codesign --verify --deep --strict "$APP" || { echo "the app's signature does not hold" >&2; exit 1; }
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then
    echo "the app was built with leave to be debugged (get-task-allow), which a build to give out must not have" >&2
    exit 1
fi
SIGNED=$(codesign -dv "$APP" 2>&1 | sed -n 's/^Signature=//p; s/^Authority=//p' | head -1)
[ -n "$SIGNED" ] || SIGNED="in a way this script does not know"
for WHERE in "$HOME" "$HERE"; do
    NAMED=$(LC_ALL=C grep -r -a -l -F "$WHERE" "$APP" | head -3 || true)
    if [ -n "$NAMED" ]; then
        echo "the app names a folder of this Mac ($WHERE), in:" >&2
        echo "$NAMED" >&2
        exit 1
    fi
done

# ---- The folder the image is made of
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/ProToPPTX-dmg.XXXXXX")
MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/ProToPPTX-dmg-mounted.XXXXXX")
tidy() {
    # Only ever the two folders made just above, and only if they are named as such.
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    case "$STAGE" in */ProToPPTX-dmg.*) rm -rf "$STAGE" ;; esac
    case "$MOUNT" in */ProToPPTX-dmg-mounted.*) rmdir "$MOUNT" 2>/dev/null || true ;; esac
}
trap tidy EXIT

ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
cp "$README" "$STAGE/Read Me First.txt"

# ---- The image
OUT="$BUILD/ProToPPTX-mac-$VERSION.dmg"
echo "Making the image..."
hdiutil create -volname "$NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov -quiet "$OUT"
hdiutil verify -quiet "$OUT"

hdiutil attach "$OUT" -nobrowse -readonly -mountpoint "$MOUNT" -quiet
codesign --verify --deep --strict "$MOUNT/$NAME.app" || { echo "the app in the image has lost its signature" >&2; exit 1; }
diff -r "$APP" "$MOUNT/$NAME.app" > /dev/null || { echo "the app in the image is not the app that was built" >&2; exit 1; }
[ -L "$MOUNT/Applications" ] && [ -f "$MOUNT/Read Me First.txt" ] || { echo "the image has not got all it should have in it" >&2; exit 1; }
hdiutil detach "$MOUNT" -quiet

echo
echo "$OUT"
echo "  $NAME $VERSION ($NUMBER), for macOS $NEEDS and later, on $ARCHS"
echo "  signed: $SIGNED"
echo "  $(du -h "$OUT" | cut -f1 | tr -d ' '), sha256 $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
case "$SIGNED" in
    adhoc) echo "  Not notarized: on another Mac it has to be allowed in System Settings before it opens. The read-me in the image says how." ;;
esac
