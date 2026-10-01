#!/usr/bin/env bash
set -euo pipefail
MACSWITCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MACSWITCH_ROOT"
mkdir -p build/probes
xcrun swiftc -swift-version 6 -parse-as-library script/AppearanceTransitionProbe.swift \
  -o build/probes/AppearanceTransitionProbe
# Default is read-only inspection. native performs 20 visible changes and
# restores the original appearance. No consent prompt is requested.
exec build/probes/AppearanceTransitionProbe "${1:-inspect}"
