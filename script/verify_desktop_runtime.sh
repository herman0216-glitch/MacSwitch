#!/usr/bin/env bash
set -euo pipefail
MACSWITCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACSWITCH_MODE="${1:---inventory}"
case "$MACSWITCH_MODE" in
  --inventory) MACSWITCH_PROBE_MODE=inventory ;;
  --run) MACSWITCH_PROBE_MODE=run ;;
  --build-only) MACSWITCH_PROBE_MODE=build ;;
  *) echo "Usage: $0 [--inventory|--run|--build-only]" >&2; exit 2 ;;
esac
MACSWITCH_PROBE_DIR="$MACSWITCH_ROOT/script/desktop-runtime-probe"
MACSWITCH_OUTPUT="$MACSWITCH_ROOT/build/DesktopRuntimeProbe"
MACSWITCH_APP="$MACSWITCH_OUTPUT/DesktopRuntimeProbe.app"
mkdir -p "$MACSWITCH_APP/Contents/MacOS"
xcrun swiftc -swift-version 6 -parse-as-library \
  "$MACSWITCH_PROBE_DIR/ProbeLogic.swift" "$MACSWITCH_PROBE_DIR/ProbeLogicTests.swift" \
  -o "$MACSWITCH_OUTPUT/ProbeLogicTests"
"$MACSWITCH_OUTPUT/ProbeLogicTests"
xcrun swiftc -swift-version 6 -parse-as-library \
  "$MACSWITCH_PROBE_DIR/ProbeLogic.swift" "$MACSWITCH_PROBE_DIR/SkyLight.swift" "$MACSWITCH_PROBE_DIR/RuntimeProbe.swift" \
  -framework AppKit -framework Security -o "$MACSWITCH_APP/Contents/MacOS/DesktopRuntimeProbe"
cat > "$MACSWITCH_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DesktopRuntimeProbe</string>
<key>CFBundleIdentifier</key><string>local.macswitch.desktop-runtime-probe</string>
<key>CFBundleName</key><string>DesktopRuntimeProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$MACSWITCH_APP"
if [[ "$MACSWITCH_PROBE_MODE" == build ]]; then echo "Built: $MACSWITCH_APP"; exit 0; fi
MACSWITCH_RUN_DIR="$MACSWITCH_OUTPUT/$(date +%Y%m%d-%H%M%S)-$MACSWITCH_PROBE_MODE-$$"
mkdir -p "$MACSWITCH_RUN_DIR"
echo "Evidence: $MACSWITCH_RUN_DIR"
/usr/bin/open -n -g -W "$MACSWITCH_APP" --args --mode "$MACSWITCH_PROBE_MODE" --directory "$MACSWITCH_RUN_DIR"
if [[ "$MACSWITCH_PROBE_MODE" == inventory ]]; then
  cat "$MACSWITCH_RUN_DIR/inventory.json"
else
  [[ -f "$MACSWITCH_RUN_DIR/result.json" ]] || { echo "Probe stopped; inspect error JSON in $MACSWITCH_RUN_DIR" >&2; exit 1; }
  cat "$MACSWITCH_RUN_DIR/result.json"
fi
echo
