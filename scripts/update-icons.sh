#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ICON="$REPO_ROOT/icon/fire.png"
ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/burnrate-icons.XXXXXX")"
trap 'rm -rf "$ICON_WORK_DIR"' EXIT
ICONSET="$ICON_WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET" "$REPO_ROOT/Sources/Burnrate/Resources"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE_ICON" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$SOURCE_ICON" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$REPO_ROOT/Resources/AppIcon.icns"
cp "$SOURCE_ICON" "$REPO_ROOT/Resources/icon.png"
cp "$SOURCE_ICON" "$REPO_ROOT/Sources/Burnrate/Resources/fire.png"
