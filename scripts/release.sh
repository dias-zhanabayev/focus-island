#!/bin/zsh

set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "Usage: zsh scripts/release.sh X.Y.Z" >&2
    exit 1
fi
tag="v$version"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
notes_path="$repo_root/docs/releases/$tag.md"
package_root="$repo_root/output/package"
app_name="Focus Island"
sign_identity="${OPEN_ISLAND_SIGN_IDENTITY:-Open Island Dev Local}"

cd "$repo_root"

[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || { echo "Release from main only." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree is not clean — commit first." >&2; exit 1; }
git fetch -q origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "main differs from origin/main — push or pull first." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "Tag $tag already exists." >&2
    exit 1
fi
if [[ ! -f "$notes_path" ]]; then
    echo "Missing release notes: docs/releases/$tag.md (first line: # Focus Island $tag — Title)" >&2
    exit 1
fi
if ! security find-identity -p codesigning -v | grep -q "\"$sign_identity\""; then
    echo "Signing identity \"$sign_identity\" not found — run: zsh scripts/setup-dev-signing.sh" >&2
    exit 1
fi

title="$(head -n 1 "$notes_path" | sed -e 's/^#[[:space:]]*//')"
body_path="$(mktemp)"
tail -n +2 "$notes_path" > "$body_path"
trap 'rm -f "$body_path"' EXIT

zsh scripts/test-clt.sh

OPEN_ISLAND_UNIVERSAL=true \
OPEN_ISLAND_VERSION="$version" \
OPEN_ISLAND_SIGN_IDENTITY="$sign_identity" \
    zsh scripts/package-app.sh

git tag -a "$tag" -m "$title"
git push origin "$tag"

gh release create "$tag" \
    "$package_root/$app_name.dmg" \
    "$package_root/$app_name.zip" \
    "$repo_root/scripts/install.sh" \
    --title "$title" \
    --notes-file "$body_path" \
    --verify-tag

echo "Released $tag"
