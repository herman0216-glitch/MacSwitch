#!/usr/bin/env bash
set -euo pipefail
MACSWITCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MACSWITCH_ROOT"
mkdir -p build/probes
xcrun swiftc -swift-version 6 -parse-as-library \
  MacSwitch/Models/SwitchFeature.swift MacSwitch/Models/AwakeDuration.swift \
  MacSwitch/Support/ProcessRunner.swift MacSwitch/Services/DesktopService.swift \
  MacSwitch/Services/AppearanceService.swift MacSwitch/Services/AudioMuteService.swift \
  MacSwitch/Services/KeepAwakeService.swift script/SystemProbe.swift -o build/probes/MacSwitchSystemProbe
exec build/probes/MacSwitchSystemProbe "${1:-read}"
