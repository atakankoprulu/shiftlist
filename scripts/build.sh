#!/bin/bash
# Builds build.nosync/Shiftlist.app. With --install, also copies it to /Applications (where the DMG installs too) and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."

# One build per architecture, joined into a universal binary (a single multi-arch build needs full Xcode).
# Each gets its own scratch path; sharing one confuses SwiftPM on the next build.
for ARCH in arm64 x86_64; do
    swift build -c release --arch "$ARCH" --scratch-path ".build.nosync/$ARCH"
done

APP=build.nosync/Shiftlist.app
rm -rf "$APP"
mkdir -p build.nosync "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build.nosync/arm64/arm64-apple-macosx/release/Shiftlist .build.nosync/x86_64/x86_64-apple-macosx/release/Shiftlist -output "$APP/Contents/MacOS/Shiftlist"
cp Resources/Info.plist "$APP/Contents/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
[ -f build.nosync/AppIcon.icns ] || swift scripts/make-icon.swift build.nosync/AppIcon.icns
cp build.nosync/AppIcon.icns "$APP/Contents/Resources/"
# A stable identity keeps macOS privacy permissions across rebuilds (see scripts/make-signing-cert.sh);
# ad-hoc signatures change every build, so Accessibility has to be granted again each time.
IDENTITY="Shiftlist Local Signing"
# iCloud (the project lives on the synced Desktop) tags files with xattrs that codesign rejects.
xattr -cr "$APP"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Hazır: $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x Shiftlist || true
    # Older builds installed to ~/Applications; a leftover copy there would run alongside this one.
    rm -rf ~/Applications/Shiftlist.app /Applications/Shiftlist.app
    cp -R "$APP" /Applications/
    open /Applications/Shiftlist.app
    echo "Kuruldu: /Applications/Shiftlist.app"
fi
