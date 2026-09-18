#!/usr/bin/env bash
# Copies the wire fixtures this repo generates into the backend repo, so both
# suites assert against the same bytes.
#
#   1. Run the Swift generator:  xcodebuild ... -only-testing:KanbanTests/FixtureGenerator
#   2. Run this script.
#   3. Run the backend suite:    cd ../kanban-backend && pytest
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend="${1:-$here/../kanban-backend}"

if [[ ! -d "$backend" ]]; then
  echo "backend repo not found at: $backend" >&2
  echo "usage: $0 [path-to-kanban-backend]" >&2
  exit 1
fi

mkdir -p "$backend/tests/fixtures"
cp "$here"/Tests/Fixtures/*.json "$backend/tests/fixtures/"
echo "synced $(ls -1 "$here"/Tests/Fixtures/*.json | wc -l | tr -d ' ') fixture(s) -> $backend/tests/fixtures"
