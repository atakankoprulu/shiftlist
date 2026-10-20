#!/bin/bash
# Builds build.nosync/Shiftlist.dmg for sharing: ffmpeg bundled inside the app, plus English and Turkish read-mes.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh
APP=build.nosync/Shiftlist.app
IDENTITY="Shiftlist Local Signing"
security find-certificate -c "$IDENTITY" >/dev/null 2>&1 || IDENTITY="-"

python3 scripts/bundle-ffmpeg.py "$APP" "$IDENTITY"
xattr -cr "$APP"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

# The DMG opens as a styled "drag to Applications" window (background, arrow, fixed icon layout).
STAGE=build.nosync/dmg
rm -rf "$STAGE" build.nosync/Shiftlist.dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp Resources/ReadMe.txt "$STAGE/Read Me.txt"
cp Resources/BeniOku.txt "$STAGE/Beni Oku.txt"
swift scripts/make-dmg-background.swift "$STAGE"
tiffutil -cathidpicheck "$STAGE/background.png" "$STAGE/background@2x.png" -out "$STAGE/background.tiff" 2>/dev/null

[ -x scripts/.venv.nosync/bin/dmgbuild ] || { python3 -m venv scripts/.venv.nosync && scripts/.venv.nosync/bin/pip install -q dmgbuild; }
scripts/.venv.nosync/bin/dmgbuild -s scripts/dmg-settings.py \
    -D stage="$STAGE" -D background="$STAGE/background.tiff" -D icon=build.nosync/AppIcon.icns \
    "Shiftlist" build.nosync/Shiftlist.dmg >/dev/null
rm -rf "$STAGE"
cp build.nosync/Shiftlist.dmg Shiftlist.dmg
echo "Paket: Shiftlist.dmg ($(du -h Shiftlist.dmg | cut -f1))"
