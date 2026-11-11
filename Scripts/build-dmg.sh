#!/bin/bash
set -euo pipefail

if [[ $# != 2 ]]; then
    printf '사용법: %s [서명된 .app 경로] [출력 .dmg 경로]\n' "$0" >&2
    exit 2
fi

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
app="$(cd -- "$1" && pwd -P)"
output="$2"
if [[ "$output" != *.dmg || -e "$output" ]]; then
    printf '%s\n' '아직 존재하지 않는 .dmg 경로를 지정해 주세요.' >&2
    exit 2
fi
codesign --verify --deep --strict "$app"

staging="$(mktemp -d "${TMPDIR:-/tmp}/what-to-do-today-dmg.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
ditto "$app" "$staging/What to Do Today.app"
install -m 755 "$script_dir/install.sh" "$staging/Install What to Do Today.command"
hdiutil create -srcfolder "$staging" -volname 'What to Do Today' -format UDZO "$output"
