#!/usr/bin/env bash
set -euo pipefail
MACSWITCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACSWITCH_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MACSWITCH_ROOT/MacSwitch/Resources/Info.plist")"
MACSWITCH_OUTPUT="$MACSWITCH_ROOT/dist/releases/$MACSWITCH_VERSION"
if [[ -e "$MACSWITCH_OUTPUT" ]]; then
  echo "Refusing to overwrite release directory: $MACSWITCH_OUTPUT" >&2
  exit 1
fi
mkdir -p "$MACSWITCH_OUTPUT"
"$MACSWITCH_ROOT/script/package_dmg.sh" "$MACSWITCH_OUTPUT/MacSwitch-$MACSWITCH_VERSION-universal.dmg"
MACSWITCH_APP="$MACSWITCH_ROOT/build/MacSwitch.xcarchive/Products/Applications/MacSwitch.app"
codesign --verify --deep --strict --verbose=2 "$MACSWITCH_APP"
lipo "$MACSWITCH_APP/Contents/MacOS/MacSwitch" -verify_arch arm64
lipo "$MACSWITCH_APP/Contents/MacOS/MacSwitch" -verify_arch x86_64
ditto -c -k --sequesterRsrc --keepParent "$MACSWITCH_APP" "$MACSWITCH_OUTPUT/MacSwitch-$MACSWITCH_VERSION-universal.zip"
cp "$MACSWITCH_ROOT/docs/FIRST-RUN.txt" "$MACSWITCH_OUTPUT/FIRST-RUN.txt"
cp "$MACSWITCH_ROOT/LICENSE" "$MACSWITCH_OUTPUT/LICENSE.txt"
cd "$MACSWITCH_OUTPUT"
shasum -a 256 "MacSwitch-$MACSWITCH_VERSION-universal.dmg" "MacSwitch-$MACSWITCH_VERSION-universal.zip" FIRST-RUN.txt LICENSE.txt > SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt
echo "Release assets: $MACSWITCH_OUTPUT"
