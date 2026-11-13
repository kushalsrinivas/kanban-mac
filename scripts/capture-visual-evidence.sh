#!/usr/bin/env bash
# Captures deterministic screenshots of the real app for visual regression evidence.
#
#   scripts/capture-visual-evidence.sh after
#   scripts/capture-visual-evidence.sh before
#
# The app runs against a throwaway support directory, defaults suite and keychain
# service, seeds the demo board, renders its own window hierarchy to PNGs, and quits.
# No screen-recording or UI-automation permission is needed.
set -euo pipefail

phase="${1:-after}"
if [[ "$phase" != "before" && "$phase" != "after" ]]; then
  echo "usage: $0 [before|after]" >&2
  exit 1
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$here/VisualEvidence/$phase"
derived="${TMPDIR:-/tmp}/kanban-evidence-build-$phase"
support="${TMPDIR:-/tmp}/kanban-evidence-support-$phase"

rm -rf "$out" "$derived" "$support"
mkdir -p "$out" "$support"

cd "$here"
xcodegen generate >/dev/null
xcodebuild -project Kanban.xcodeproj -scheme Kanban \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived" -quiet build

app="$derived/Build/Products/Debug/Kanban.app/Contents/MacOS/Kanban"
if [[ ! -x "$app" ]]; then
  echo "app binary not found at $app" >&2
  exit 1
fi

suite="com.kanban.evidence.$phase.$(date +%s)"
KANBAN_SUPPORT_DIR="$support" \
KANBAN_DEFAULTS_SUITE="$suite" \
KANBAN_KEYCHAIN_SERVICE="com.kanban.evidence.$phase" \
KANBAN_DEMO_DATA=1 \
KANBAN_SCREENSHOT_DIR="$out" \
KANBAN_AUTO_QUIT=1 \
"$app" -ApplePersistenceIgnoreState YES >"${TMPDIR:-/tmp}/kanban-evidence-$phase.log" 2>&1 &
pid=$!

for _ in $(seq 1 60); do
  if ! kill -0 "$pid" 2>/dev/null; then break; fi
  sleep 1
done

if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  echo "capture timed out; see ${TMPDIR:-/tmp}/kanban-evidence-$phase.log" >&2
  exit 1
fi

count=$(find "$out" -name '*.png' | wc -l | tr -d ' ')
echo "captured $count screenshots into $out"
ls -1 "$out"
