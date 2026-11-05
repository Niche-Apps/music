#!/bin/zsh
# One-time: gives GitHub Actions what .github/workflows/release.yml needs to sign releases. Works over SSH.
#
#   tools/ci/upload-secrets.sh [all|keychain|sparkle]
#
# Uploads to the repo's Actions secrets:
#   NOTARY_KEYCHAIN_BASE64 / NOTARY_KEYCHAIN_PASSWORD  the release Mac's build keychain, copied as is: it holds
#                                                      the Developer ID identity and notarytool's saved
#                                                      credentials (profile "standard-code-notary")
#   SPARKLE_ED_PRIVATE_KEY                             the EdDSA key that signs updates
# Nothing is written outside a private temp directory, which is deleted at the end.
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
KC_DIR="${SM_BUILD_KEYCHAIN_DIR:-$HOME/.local/share/standard-code/build-keychain}"
TMP=$(mktemp -d); chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT

only="${1:-all}"

if [[ "$only" == all || "$only" == keychain ]]; then
  KC="$KC_DIR/notary.keychain-db"
  [[ -f "$KC" && -f "$KC_DIR/unlock-password" ]] || { echo "No build keychain at $KC_DIR" >&2; exit 1; }
  security unlock-keychain -p "$(cat "$KC_DIR/unlock-password")" "$KC"
  security find-identity -v -p codesigning "$KC" | grep -q "Developer ID Application" \
    || { echo "No Developer ID identity in $KC" >&2; exit 1; }
  xcrun notarytool history --keychain-profile standard-code-notary --keychain "$KC" >/dev/null \
    || { echo "notarytool can't use the saved credentials in $KC" >&2; exit 1; }
  base64 -i "$KC" | gh secret set NOTARY_KEYCHAIN_BASE64 -R "$REPO"
  tr -d '\n' < "$KC_DIR/unlock-password" | gh secret set NOTARY_KEYCHAIN_PASSWORD -R "$REPO"
  echo "  ✓ Build keychain (Developer ID identity and notarization credentials)"
fi

if [[ "$only" == all || "$only" == sparkle ]]; then
  GENERATE_KEYS=$(find "$ROOT/build/dev/SourcePackages/artifacts/sparkle" -type f -perm -u+x -path "*/bin/generate_keys" | head -1)
  [[ -n "$GENERATE_KEYS" ]] || { echo "Build the app once (tools/build.sh) so Sparkle's tools are present." >&2; exit 1; }
  "$GENERATE_KEYS" -x "$TMP/sparkle.key" >/dev/null
  gh secret set SPARKLE_ED_PRIVATE_KEY -R "$REPO" < "$TMP/sparkle.key"
  echo "  ✓ Sparkle update key"
fi
echo "Done. Release with: tools/tag-release.sh <version>"
