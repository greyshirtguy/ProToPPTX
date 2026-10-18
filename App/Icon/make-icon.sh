#!/bin/sh
# Makes App/ProToPPTX.icns, the app's icon, from App/Icon/ProToPPTX-source.png (the
# maintainer's picture): MakeIcon.swift cuts the icon out and puts it on Apple's grid,
# then every size an .icns holds is made from that and put together by iconutil.
#
#     App/Icon/make-icon.sh
#
# Run it again only when the picture changes; the .icns it makes is kept in the
# repository, so a build needs neither this nor the picture.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ProToPPTX-icon.XXXXXX")
trap 'case "$WORK" in */ProToPPTX-icon.*) rm -rf "$WORK" ;; esac' EXIT

swift "$HERE/MakeIcon.swift" "$HERE/ProToPPTX-source.png" "$WORK/icon-1024.png"
SET="$WORK/ProToPPTX.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}.png" > /dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$SET" -o "$HERE/../ProToPPTX.icns"
cp "$WORK/icon-1024.png" "$HERE/ProToPPTX-1024.png"
echo "wrote $HERE/../ProToPPTX.icns"
