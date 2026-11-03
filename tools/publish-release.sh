#!/bin/zsh
# Builds a release on this Mac and publishes it to GitHub Releases.
#
#   tools/publish-release.sh <version> [notes.md]
#
# 1. Sets MARKETING_VERSION to <version> and bumps CURRENT_PROJECT_VERSION in project.yml.
# 2. Builds Release, signs with Developer ID, notarizes and staples (tools/release.sh).
# 3. Commits the version bump, tags v<version>, pushes main and the tag.
# 4. Signs the zip with the Sparkle EdDSA key and adds it to appcast.xml (the previous release's
#    appcast is downloaded and extended, so older items are kept).
# 5. Creates the GitHub release with StandardMusic.zip and appcast.xml attached. The asset names never
#    change, so https://github.com/<owner>/<repo>/releases/latest/download/StandardMusic.zip always
#    points at the newest build (the website's Download buttons use it) and …/appcast.xml is the feed
#    the app's SUFeedURL reads.
#
# Sparkle's private EdDSA key is in this Mac's login keychain (item "Private key for signing Sparkle
# updates", account "ed25519"), created by Sparkle's generate_keys. It is never in the repo. Back it up
# with `generate_keys -x <file>`; restore on another Mac with `generate_keys -f <file>`.
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
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

# Sparkle's tools come with its SPM binary artifact; resolve packages if they aren't there yet.
sparkle_tool() { find "$ROOT/build/dev/SourcePackages/artifacts/sparkle" -type f -perm -u+x -path "*/bin/$1" 2>/dev/null | head -1; }
if [[ -z "$(sparkle_tool sign_update)" ]]; then
  xcodebuild -resolvePackageDependencies -project StandardMusic.xcodeproj -scheme StandardMusic \
    -derivedDataPath "$ROOT/build/dev" >/dev/null
fi
SIGN_UPDATE=$(sparkle_tool sign_update); GENERATE_KEYS=$(sparkle_tool generate_keys)
[[ -n "$SIGN_UPDATE" && -n "$GENERATE_KEYS" ]] || { echo "Couldn't find Sparkle's sign_update/generate_keys." >&2; exit 1; }
KEYCHAIN_KEY=$("$GENERATE_KEYS" -p 2>/dev/null) || { echo "No Sparkle signing key in the keychain (see the note at the top)." >&2; exit 1; }
PLIST_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' StandardMusic/Info.plist)
[[ "$KEYCHAIN_KEY" == "$PLIST_KEY" ]] || { echo "The keychain's Sparkle key doesn't match SUPublicEDKey in Info.plist." >&2; exit 1; }

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
BUILT_NUMBER=$(defaults read "$ROOT/build/release/Standard Music.app/Contents/Info" CFBundleVersion)
[[ "$BUILT_NUMBER" == "$BUILD" ]] || { echo "Built app reports build $BUILT_NUMBER, expected $BUILD." >&2; exit 1; }

# Appcast: extend the current one (if the latest release has it) with this build.
APPCAST_DIR=$(mktemp -d)
APPCAST="$APPCAST_DIR/appcast.xml"
gh release download --repo "$REPO" --pattern appcast.xml --dir "$APPCAST_DIR" 2>/dev/null || true
# sign_update reading the keychain itself waits on an access prompt nobody sees over SSH, so
# generate_keys (which owns the item) exports the key to a private temp file for a moment.
KEY_DIR=$(mktemp -d); chmod 700 "$KEY_DIR"
trap 'rm -rf "$KEY_DIR"' EXIT
STATUS=0; SIGNED=""
"$GENERATE_KEYS" -x "$KEY_DIR/key" >/dev/null && SIGNED=$("$SIGN_UPDATE" --ed-key-file "$KEY_DIR/key" "$ZIP") || STATUS=$?
rm -rf "$KEY_DIR"
(( STATUS == 0 )) || { echo "sign_update failed: $SIGNED" >&2; exit 1; }
python3 -I "$ROOT/tools/appcast.py" "$APPCAST" "$VERSION" "$BUILD" \
  "https://github.com/$REPO/releases/download/$TAG/StandardMusic.zip" \
  "https://github.com/$REPO/releases/tag/$TAG" "$SIGNED"

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
gh release create "$TAG" "$ZIP#Standard Music $VERSION for macOS (zip)" "$APPCAST#Update feed (Sparkle appcast)" \
  --title "Standard Music $VERSION" --notes-file "$NOTES" --latest
rm -rf "$NOTES" "$APPCAST_DIR"
echo "PUBLISHED: $(gh release view "$TAG" --json url -q .url)"
