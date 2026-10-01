#!/usr/bin/env bash
set -euo pipefail
MACSWITCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MACSWITCH_ROOT"
case "${1:-}" in
  '') "$MACSWITCH_ROOT/script/build_and_run.sh" --build-only ;;
  --no-build)
    if pgrep -x MacSwitch >/dev/null; then
      echo 'MacSwitch is running; close it before starting the prototype.' >&2
      exit 1
    fi ;;
  *) echo "Usage: $0 [--no-build]" >&2; exit 2 ;;
esac
MACSWITCH_RESULT="$MACSWITCH_ROOT/build/cleaning-input/probe-$(date +%Y%m%d-%H%M%S).json"
mkdir -p "$(dirname "$MACSWITCH_RESULT")"
open -n "$MACSWITCH_ROOT/dist/MacSwitch.app" --args --cleaning-probe "$MACSWITCH_RESULT"
echo "Opened the timed prototype. Click Start when ready; it does not start blocking input automatically."
echo "Evidence: $MACSWITCH_RESULT"
