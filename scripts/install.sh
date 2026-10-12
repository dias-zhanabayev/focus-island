#!/bin/zsh

set -euo pipefail

repo="${FOCUS_ISLAND_REPO:-dias-zhanabayev/focus-island}"
tag="${1:-}"
app_name="Focus Island"
target="/Applications/$app_name.app"

if ! command -v gh >/dev/null 2>&1; then
    echo "Нужен GitHub CLI: brew install gh && gh auth login" >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Скачиваю ${tag:-последний релиз} из $repo…"
gh release download ${tag:+"$tag"} -R "$repo" -p '*.zip' -D "$work"
archive="$(ls "$work"/*.zip | head -n 1)"
ditto -x -k "$archive" "$work/unpacked"
downloaded="$(find "$work/unpacked" -maxdepth 1 -name '*.app' | head -n 1)"
[[ -n "$downloaded" ]] || { echo "В архиве нет приложения." >&2; exit 1; }

osascript -e "tell application \"$app_name\" to quit" >/dev/null 2>&1 || true
sleep 1
pkill -f "$app_name.app/Contents/MacOS/OpenIslandApp" 2>/dev/null || true

rm -rf "$target"
ditto "$downloaded" "$target"
xattr -dr com.apple.quarantine "$target" 2>/dev/null || true

version="$(defaults read "$target/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo "Установлено: $target ($version)"
if [[ -d "$HOME/Applications/$app_name.app" ]]; then
    echo "Внимание: есть ещё dev-сборка в ~/Applications/$app_name.app — запускай одну из них."
fi
open "$target"
