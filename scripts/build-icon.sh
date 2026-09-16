#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# This PNG is the visually checked rendering of mipad2mac-app-icon-v8.svg.
SOURCE="$PWD/assets/branding/mipad2mac-app-icon-v8.png"
OUTPUT="${1:-$PWD/assets/branding/MiPad2Mac.icns}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mipad-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/MiPad2Mac.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUTPUT"
