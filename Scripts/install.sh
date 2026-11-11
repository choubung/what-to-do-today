#!/bin/bash
set -euo pipefail

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

if [[ $# -gt 1 || "${1:-}" == "--help" ]]; then
    printf '사용법: %s [서명된 .app 경로]\n' "$0"
    exit 0
fi

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
app_name='What to Do Today.app'
destination="/Applications/$app_name"
source_app="${1:-$script_dir/$app_name}"
widget_path='Contents/PlugIns/TodoWidget.appex'
app_executable="$destination/Contents/MacOS/What to Do Today"
widget_executable="$destination/$widget_path/Contents/MacOS/TodoWidget"
user_id="$(id -u)"

[[ "$user_id" != 0 ]] || fail '로그인한 Mac 사용자로 설치 스크립트를 실행해 주세요.'
[[ -d "$source_app" ]] || fail "앱 번들을 찾을 수 없어요: $source_app"
source_app="$(cd -- "$source_app" && pwd -P)"
[[ "$source_app" != "$destination" ]] || fail '설치할 새 앱 번들 경로를 입력해 주세요.'
[[ ! -L "$destination" ]] || fail '응용 프로그램 폴더의 앱이 심볼릭 링크예요. 기존 설치 경로를 확인해 주세요.'

verify_bundle() {
    local app="$1"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == 'com.choubung.whattodotoday' ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/$widget_path/Contents/Info.plist")" == 'com.choubung.whattodotoday.widget' ]] &&
    codesign --verify --deep --strict "$app"
}

team_identifier() {
    codesign -dv --verbose=4 "$1" 2>&1 | awk -F= '$1 == "TeamIdentifier" { print $2 }'
}

running_pids() {
    local executable="$1"
    ps -xww -U "$user_id" -o pid= -o comm= | awk -v path="$executable" '
        { pid = $1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "") }
        $0 == path { print pid }
    '
}

ensure_app_closed() {
    local pids pid args
    pids="$(running_pids "$app_executable")"
    for pid in $pids; do
        args="$(ps -ww -p "$pid" -o args=)" || continue
        case "$args" in
            "$app_executable --mcp"|"$app_executable --mcp "*) ;;
            *) fail 'What to Do Today를 ⌘Q로 종료한 뒤 다시 실행해 주세요.' ;;
        esac
    done
}

stop_installed_widget() {
    local pids pid attempt
    pids="$(running_pids "$widget_executable")"
    for pid in $pids; do
        [[ "$(ps -p "$pid" -o comm=)" == "$widget_executable" ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
        for ((attempt = 0; attempt < 50; attempt++)); do
            [[ "$(ps -p "$pid" -o comm=)" == "$widget_executable" ]] || break
            sleep 0.1
        done
        [[ "$(ps -p "$pid" -o comm=)" != "$widget_executable" ]] ||
            fail '이전 위젯이 종료되지 않았어요. 설치 스크립트를 다시 실행해 주세요.'
    done
}

verify_bundle "$source_app" || fail '앱 또는 위젯 서명을 확인할 수 없어요.'
new_team="$(team_identifier "$source_app")"
[[ -n "$new_team" && "$new_team" != "not set" ]] || fail '개발 팀으로 서명한 앱을 사용해 주세요.'
if [[ -e "$destination" ]]; then
    [[ "$(team_identifier "$destination")" == "$new_team" ]] ||
        fail '기존 앱의 데이터에 접근하려면 같은 개발 팀으로 서명해야 해요.'
fi
ensure_app_closed

staging="$(mktemp -d /Applications/.what-to-do-today-install.XXXXXX)"
backup="$staging/previous.app"
cleanup() {
    local status=$?
    if [[ -e "$backup" && ! -e "$destination" ]]; then
        if ! mv "$backup" "$destination"; then
            printf '기존 앱 복구 위치: %s\n' "$backup" >&2
            return 1
        fi
    fi
    rm -rf -- "$staging"
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ditto "$source_app" "$staging/$app_name"
verify_bundle "$staging/$app_name" || fail '복사한 앱의 서명이 올바르지 않아요.'
ensure_app_closed
if [[ -e "$destination" ]]; then mv "$destination" "$backup"; fi
mv "$staging/$app_name" "$destination"

# WidgetKit may still use the executable mapped before the bundle replacement.
pluginkit -a "$destination/$widget_path"
stop_installed_widget
open -a "$destination"
printf '%s\n' '설치 완료. 앱이 시작되면 위젯 목록을 다시 불러옵니다.'
