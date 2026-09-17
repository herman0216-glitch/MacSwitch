#!/usr/bin/env bash
set -euo pipefail

MACSWITCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACSWITCH_ARCHIVE="$MACSWITCH_ROOT/build/MacSwitch.xcarchive"
MACSWITCH_STAGE=""
USER_DESKTOP="${HOME}/Desktop"

cleanup() {
  if [[ -n "$MACSWITCH_STAGE" && -d "$MACSWITCH_STAGE" ]]; then
    rm -rf "$MACSWITCH_STAGE"
  fi
}
trap cleanup EXIT

cd "$MACSWITCH_ROOT"

if command -v xcodegen >/dev/null; then
  xcodegen generate --spec project.yml
elif [[ ! -d MacSwitch.xcodeproj ]]; then
  echo "XcodeGen is required to generate MacSwitch.xcodeproj." >&2
  exit 1
fi

mkdir -p "$MACSWITCH_ROOT/build"
xcodebuild -project MacSwitch.xcodeproj -scheme MacSwitch -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$MACSWITCH_ROOT/build/ReleaseDerivedData" \
  -archivePath "$MACSWITCH_ARCHIVE" archive CODE_SIGN_IDENTITY=- 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO

MACSWITCH_APP="$MACSWITCH_ARCHIVE/Products/Applications/MacSwitch.app"
if [[ ! -d "$MACSWITCH_APP" ]]; then
  echo "Archive did not contain MacSwitch.app." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$MACSWITCH_APP"
MACSWITCH_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MACSWITCH_APP/Contents/Info.plist")"
MACSWITCH_OUTPUT="${1:-$USER_DESKTOP/MacSwitch-${MACSWITCH_VERSION}.dmg}"

if [[ -e "$MACSWITCH_OUTPUT" ]]; then
  echo "Refusing to overwrite existing file: $MACSWITCH_OUTPUT" >&2
  exit 1
fi

MACSWITCH_STAGE="$(mktemp -d "$MACSWITCH_ROOT/build/MacSwitch-dmg.XXXXXX")"
ditto "$MACSWITCH_APP" "$MACSWITCH_STAGE/MacSwitch.app"
ln -s /Applications "$MACSWITCH_STAGE/Applications"
cp "$MACSWITCH_ROOT/docs/FIRST-RUN.txt" "$MACSWITCH_STAGE/首次启动说明.txt"
cp "$MACSWITCH_ROOT/LICENSE" "$MACSWITCH_STAGE/LICENSE.txt"
hdiutil create -volname "MacSwitch" -srcfolder "$MACSWITCH_STAGE" -format UDZO -imagekey zlib-level=9 -ov "$MACSWITCH_OUTPUT"

echo "DMG: $MACSWITCH_OUTPUT"
