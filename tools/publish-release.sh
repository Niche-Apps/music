#!/bin/zsh
# Builds a release on this Mac and publishes it to GitHub Releases.
#
#   tools/publish-release.sh <version> [notes.md]
#
# 1. Sets MARKETING_VERSION to <version> and bumps CURRENT_PROJECT_VERSION in project.yml.
# 2. Builds Release, signs with Developer ID, notarizes and staples (tools/release.sh).
# 3. Commits the version bump, tags v<version>, pushes main and the tag.
# 4. Creates the GitHub release with StandardMusic.zip attached. The asset name never changes, so
#    https://github.com/<owner>/<repo>/releases/latest/download/StandardMusic.zip always points at
#    the newest build (the website's Download buttons use it).
#
# Release notes come from notes.md if given, otherwise from the commit subjects since the last tag.
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"

VERSION="${1:-}"
NOTES_FILE="${2:-}"
[[ -n "$VERSION" ]] || { echo "usage: tools/publish-release.sh <version> [notes.md]" >&2; exit 1; }
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { echo "Version must look like 1.2 or 1.2.3" >&2; exit 1; }
TAG="v$VERSION"

[[ "$(git branch --show-current)" == "main" ]] || { echo "Release from main." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "main isn't in sync with origin/main; push or pull first." >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in with: gh auth login" >&2; exit 1; }

# Version bump
BUILD=$(( $(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml | head -1) + 1 ))
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/; s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
xcodegen generate -q

# Build, sign, notarize
if ! tools/release.sh; then
  git checkout -- project.yml
  echo "Release build failed; version bump undone." >&2
  exit 1
fi
ZIP="$ROOT/build/release/StandardMusic.zip"
BUILT=$(defaults read "$ROOT/build/release/Standard Music.app/Contents/Info" CFBundleShortVersionString)
[[ "$BUILT" == "$VERSION" ]] || { echo "Built app reports $BUILT, expected $VERSION." >&2; exit 1; }

# Notes
NOTES=$(mktemp)
if [[ -n "$NOTES_FILE" ]]; then
  cat "$NOTES_FILE" > "$NOTES"
else
  LAST=$(git describe --tags --abbrev=0 2>/dev/null || true)
  { echo "## What's new"; echo; git log --no-merges --format='- %s' ${LAST:+$LAST..}HEAD; } > "$NOTES"
fi
cat >> "$NOTES" <<EOF

---
**Install:** unzip, move **Standard Music** to Applications and open it. Requires macOS 26 on Apple silicon,
about 5 GB of free space for the music model, and a ChatGPT account for writing. Signed with Developer ID
and notarized by Apple.
EOF

# Commit, tag, push, publish
git add project.yml
git commit -q -m "Release $TAG"
git tag -a "$TAG" -m "Standard Music $VERSION"
git push -q origin main "$TAG"
gh release create "$TAG" "$ZIP#Standard Music $VERSION for macOS (zip)" \
  --title "Standard Music $VERSION" --notes-file "$NOTES" --latest
rm -f "$NOTES"
echo "PUBLISHED: $(gh release view "$TAG" --json url -q .url)"
