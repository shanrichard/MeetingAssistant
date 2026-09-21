#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE="${1:-Resources/Artwork/MeetingAssistant-icon-source.png}"
ICONSET="$PWD/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 1024 1024 "$SOURCE" --out Resources/AppIcon.png >/dev/null
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo 'Built Resources/AppIcon.png and Resources/AppIcon.icns'
