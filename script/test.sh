#!/usr/bin/env bash
set -euo pipefail
MACSWITCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MACSWITCH_ROOT"
if command -v xcodegen >/dev/null; then xcodegen generate --spec project.yml; fi
mkdir -p build/logs
MACSWITCH_RESULTS="build/TestResults-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -project MacSwitch.xcodeproj -scheme MacSwitch -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData -resultBundlePath "$MACSWITCH_RESULTS" test \
  >build/logs/test.log 2>&1 || { tail -n 100 build/logs/test.log; exit 1; }
tail -n 40 build/logs/test.log
echo "Results: $MACSWITCH_RESULTS"
