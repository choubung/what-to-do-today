#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
icon_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/today-icon.XXXXXX")"
trap 'rm -rf "$icon_work_dir"' EXIT
iconset="$icon_work_dir/AppIcon.iconset"
mkdir -p "$iconset"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" App/Resources/AppIcon.png \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" App/Resources/AppIcon.png \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o App/Resources/AppIcon.icns
echo "Built App/Resources/AppIcon.icns"
