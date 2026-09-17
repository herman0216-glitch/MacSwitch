#!/usr/bin/env bash
set -euo pipefail
MACSWITCH_MODE="${1:-run}"
MACSWITCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MACSWITCH_ROOT"
case "$MACSWITCH_MODE" in
  run|--verify|--debug|--logs|--telemetry|--build-only) ;;
  *) echo "usage: $0 [--verify|--debug|--logs|--telemetry|--build-only]" >&2; exit 2 ;;
esac
if pgrep -x MacSwitch >/dev/null; then
  pkill -TERM -x MacSwitch || true
  for ((attempt=0; attempt<50; attempt++)); do
    if ! pgrep -x MacSwitch >/dev/null; then break; fi
    sleep 0.1
  done
  if pgrep -x MacSwitch >/dev/null; then
    echo "MacSwitch is still stopping. Close it and retry." >&2
    exit 1
  fi
fi
if command -v xcodegen >/dev/null; then
  xcodegen generate --spec project.yml
elif [[ ! -d MacSwitch.xcodeproj ]]; then
  echo "XcodeGen is required to generate MacSwitch.xcodeproj." >&2
  exit 1
fi
mkdir -p build/logs dist
xcodebuild -project MacSwitch.xcodeproj -scheme MacSwitch -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build \
  >build/logs/build.log 2>&1 || { tail -n 100 build/logs/build.log; exit 1; }
MACSWITCH_BUNDLE="$MACSWITCH_ROOT/build/DerivedData/Build/Products/Debug/MacSwitch.app"
ditto "$MACSWITCH_BUNDLE" "$MACSWITCH_ROOT/dist/MacSwitch.app"
echo "Built: $MACSWITCH_ROOT/dist/MacSwitch.app"
case "$MACSWITCH_MODE" in
  --build-only) exit 0 ;;
  --debug) exec lldb -- "$MACSWITCH_ROOT/dist/MacSwitch.app/Contents/MacOS/MacSwitch" ;;
esac
open -n "$MACSWITCH_ROOT/dist/MacSwitch.app"
for ((attempt=0; attempt<50; attempt++)); do
  if pgrep -x MacSwitch >/dev/null; then break; fi
  sleep 0.1
done
pgrep -x MacSwitch >/dev/null || { echo 'MacSwitch failed to launch.' >&2; exit 1; }
echo "Running: MacSwitch (PID $(pgrep -x MacSwitch | head -n 1))"
case "$MACSWITCH_MODE" in
  --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "MacSwitch"' ;;
  --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.herman.MacSwitch"' ;;
esac
