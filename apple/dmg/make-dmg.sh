#!/usr/bin/env bash
# Puts an app into a compressed DMG whose window shows the app, an arrow and the
# Applications folder, so it installs by dragging.
#
#   apple/dmg/make-dmg.sh <Pendenz.app> <out.dmg>
#
# Finder lays out the window, so this opens a Finder window for a few seconds, and the first
# run asks once for permission to control Finder.
set -euo pipefail

[[ $# -eq 2 ]] || {
    echo "usage: apple/dmg/make-dmg.sh <app> <out.dmg>" >&2
    exit 64
}
app=$1
out=$2
name=Pendenz
here=$(cd "$(dirname "$0")" && pwd)

fail() {
    echo "make-dmg: $*" >&2
    exit 1
}

[[ -d $app ]] || fail "no app at $app"
[[ ! -e /Volumes/$name ]] || fail "a volume named $name is mounted already: eject it first"

work=$(mktemp -d "${TMPDIR:-/tmp}/pendenz-dmg.XXXXXX")
mount=
cleanup() {
    [[ -n $mount ]] && hdiutil detach -quiet "$mount" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/stage/.background"
ditto "$app" "$work/stage/$name.app"
ln -s /Applications "$work/stage/Applications"
chflags hidden "$work/stage/.background"
swift "$here/background.swift" "$work"
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" \
    -out "$work/stage/.background/background.tiff" 2>/dev/null

# A writable image first, with room for the folder settings Finder writes.
size=$(($(du -sm "$work/stage" | cut -f1) + 20))
hdiutil create -quiet -volname "$name" -srcfolder "$work/stage" -fs HFS+ \
    -format UDRW -size "${size}m" "$work/rw.dmg"
mount=$(hdiutil attach -readwrite -noverify -noautoopen "$work/rw.dmg" \
    | grep -o "/Volumes/$name.*$" | head -1 || true)
[[ $mount == "/Volumes/$name" ]] || fail "the image did not mount at /Volumes/$name"

# The window is 600 by 400 points below its title bar, as the background is drawn.
osascript <<EOF
tell application "Finder"
    -- A window of its own: where tabs are preferred, "open" adds a tab to another window.
    set win to make new Finder window to disk "$name"
    set current view of win to icon view
    set toolbar visible of win to false
    set statusbar visible of win to false
    set pathbar visible of win to false
    set bounds of win to {200, 120, 800, 552}
    set options to the icon view options of win
    set arrangement of options to not arranged
    set icon size of options to 128
    set text size of options to 13
    set background picture of options to file ".background:background.tiff" of disk "$name"
    -- The icon centres, level with the arrow in the background.
    set position of item "$name.app" of disk "$name" to {160, 180}
    set position of item "Applications" of disk "$name" to {440, 180}
    -- Out of sight also where Finder shows hidden files.
    set position of item ".background" of disk "$name" to {700, 600}
    update disk "$name" without registering applications
    delay 1
    close win
end tell
EOF

# Finder writes .DS_Store a moment after the window closes.
for _ in {1..20}; do
    [[ -f $mount/.DS_Store ]] && break
    sleep 0.5
done
[[ -f $mount/.DS_Store ]] || fail "Finder did not save the window layout"
sleep 1
rm -rf "$mount/.fseventsd"
sync
hdiutil detach -quiet "$mount"
mount=

rm -f "$out"
hdiutil convert -quiet "$work/rw.dmg" -format ULFO -o "$out"
