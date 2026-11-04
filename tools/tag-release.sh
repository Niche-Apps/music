#!/bin/zsh
# Releases a version: tags main and pushes the tag. GitHub Actions (.github/workflows/release.yml) builds,
# signs, notarizes and publishes it, and installed copies offer the update in the sidebar.
#
#   tools/tag-release.sh <version> [notes.md]
#
# The notes become the release notes (markdown); without them, the commit subjects since the last tag.
set -euo pipefail
cd "${0:A:h:h}"
VERSION="${1:-}"; NOTES_FILE="${2:-}"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { echo "usage: tools/tag-release.sh <1.2 | 1.2.3> [notes.md]" >&2; exit 1; }
TAG="v$VERSION"
[[ "$(git branch --show-current)" == "main" ]] || { echo "Release from main." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
git fetch -q --tags origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "Push main first." >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists." >&2; exit 1; }
if [[ -n "$NOTES_FILE" ]]; then git tag -a "$TAG" -F "$NOTES_FILE"; else git tag -a "$TAG" -m "Standard Music $VERSION"; fi
git push -q origin "$TAG"
echo "Tagged $TAG. Building: $(gh repo view --json url -q .url)/actions/workflows/release.yml"
