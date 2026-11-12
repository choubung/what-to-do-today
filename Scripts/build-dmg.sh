#!/bin/bash
set -euo pipefail

if [[ $# != 1 || "$1" != *.dmg ]]; then
    printf '사용법: %s [출력 .dmg 경로]\n' "$0" >&2
    exit 2
fi

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
output_dir="$(cd -- "$(dirname -- "$1")" && pwd -P)"
output="$output_dir/$(basename -- "$1")"
if [[ -e "$output" || -L "$output" ]]; then
    printf '%s\n' '아직 존재하지 않는 .dmg 경로를 지정해 주세요.' >&2
    exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/what-to-do-today-dmg.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
xcodebuild -project "$script_dir/../WhatToDoToday.xcodeproj" \
    -scheme WhatToDoTodayStandalone -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$work/build" \
    ARCHS=arm64 build

app_name='What to Do Today (DMG).app'
app="$work/build/Build/Products/Release/$app_name"
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
if [[ "$identifier" != 'com.choubung.whattodotoday.standalone' || -d "$app/Contents/PlugIns" ]]; then
    printf '%s\n' '위젯이 없는 DMG용 앱을 빌드해 주세요.' >&2
    exit 1
fi
codesign --verify --deep --strict "$app"

mkdir "$work/image"
ditto "$app" "$work/image/$app_name"
ln -s /Applications "$work/image/Applications"
hdiutil create -srcfolder "$work/image" -volname 'What to Do Today' -format UDZO "$output"
