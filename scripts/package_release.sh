#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-}"
if [[ -z "$version" ]]; then
    version="$(sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$root/_meta.lua" | head -n 1)"
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must use X.Y.Z format (got: ${version:-missing})" >&2
    exit 1
fi

archive="${2:-$root/dist/Weread_Annotation_Lite.koplugin.v${version}.zip}"
stage="$(mktemp -d)"
plugin="$stage/Weread_Annotation_Lite.koplugin"
mkdir -p "$plugin" "$(dirname "$archive")"

cp "$root/_meta.lua" "$root/main.lua" "$root/settings.lua" "$root/LICENSE" "$root/README.md" "$plugin/"
cp -R "$root/lib" "$root/ui" "$plugin/"

rm -f "$archive"
(cd "$stage" && zip -r "$archive" Weread_Annotation_Lite.koplugin >/dev/null)
rm -rf "$stage"
echo "$archive"
