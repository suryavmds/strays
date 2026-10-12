#!/bin/bash
# Renders the app's views to PNGs with demo data, off screen.
#   scripts/snapshots.sh <output-directory>
set -euo pipefail
out="${1:?usage: scripts/snapshots.sh <output-directory>}"
app="build/Build/Products/Debug/Strays.app/Contents/MacOS/Strays"
[ -x "$app" ] || { echo "Build first: make build"; exit 1; }
mkdir -p "$out"
"$app" --render-snapshots "$out" &
pid=$!
# The renderer exits on its own; this only guards against a hang.
( sleep 60; kill "$pid" 2>/dev/null ) &
guard=$!
wait "$pid" 2>/dev/null || true
kill "$guard" 2>/dev/null || true
ls "$out"
