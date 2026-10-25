#!/usr/bin/env bash
# BSideMac architecture gate. Exit != 0 means violation. Run before every commit.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

viol() { echo "ARCH-GATE VIOLATION: $1"; fail=1; }

# 1. BSideCore purity: no App-layer / platform imports
core_bad_imports='^\s*import\s+(AppKit|SwiftUI|Cocoa|AVFoundation|AVFAudio|CoreAudio|MediaPlayer|ServiceManagement|IOKit|CoreMedia|Combine)\b'
if grep -rEn "$core_bad_imports" Sources/BSideCore --include='*.swift' | grep -q .; then
  viol "BSideCore imports a forbidden module:"
  grep -rEn "$core_bad_imports" Sources/BSideCore --include='*.swift' | head -10
fi

# 2. BSideCore must not depend on BSidePlatform symbols
if grep -rEn "^\s*import\s+BSidePlatform\b" Sources/BSideCore --include='*.swift' | grep -q .; then
  viol "BSideCore imports BSidePlatform (dependency direction violation)"
fi

# 3. ControlApp must not own media playback or desktop windows
ctrl_bad='AVQueuePlayer|AVPlayerLooper|AVPlayerLayer|DesktopHost|CGWindowLevelForKey'
if grep -rEn "$ctrl_bad" Sources/BSideControlApp --include='*.swift' | grep -v '^\s*//' | grep -q .; then
  viol "BSideControlApp references playback/desktop-window APIs (UI must go through Command/IPC):"
  grep -rEn "$ctrl_bad" Sources/BSideControlApp --include='*.swift' | head -10
fi

# 4. Official assets / reference clones must not be tracked
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git ls-files | grep -qE '^(BSide-win64|BSide-working|references)/|\.mp4$|\.mp3$'; then
    viol "Protected paths or media files are tracked in git"
  fi
fi

# 4b. ControlApp must not import AVFoundation (UI only; playback lives in Agent/Platform)
if grep -rEn "^\s*import\s+AVFoundation" Sources/BSideControlApp --include='*.swift' | grep -q .; then
  viol "BSideControlApp imports AVFoundation"
fi

# 4c. OfficialAssetProvider may be referenced ONLY by the resource-selection coordinator
#     (AppDelegate) — onboarding/settings must reuse the same business path (prompt rule #16)
if grep -rl "OfficialAssetProvider" Sources/BSideControlApp --include='*.swift' | grep -vq "AppDelegate.swift"; then
  viol "OfficialAssetProvider referenced outside AppDelegate (duplicate resource-selection path)"
fi

# 5. No hardcoded absolute paths to official assets in sources
#    (exception: Sources/BSidePlatform/DefaultLocations.swift — sanctioned first-run hints)
if grep -rEn "Development/BSideMacLab/(BSide-win64|BSide-working)" Sources Tests --include='*.swift' \
   | grep -v "DefaultLocations.swift" | grep -q .; then
  viol "Source code hardcodes official asset paths (must come from user selection/bookmark):"
  grep -rEn "Development/BSideMacLab/(BSide-win64|BSide-working)" Sources Tests --include='*.swift' | head -5
fi

if [ "$fail" -eq 0 ]; then echo "arch-gate: PASS"; fi
exit "$fail"
