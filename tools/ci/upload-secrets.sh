#!/bin/zsh
# One-time: gives GitHub Actions what .github/workflows/release.yml needs to sign releases.
# Run it on the Mac that has the Developer ID identity, in a terminal on its screen (or Screen Sharing):
# macOS asks you to allow exporting the private key, which it can't do over SSH.
#
#   tools/ci/upload-secrets.sh
#
# Uploads to the repo's Actions secrets:
#   DEVELOPER_ID_P12_BASE64 / DEVELOPER_ID_P12_PASSWORD   the "Developer ID Application" identity
#   NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_APP_PASSWORD an app-specific password for notarytool
#   SPARKLE_ED_PRIVATE_KEY                                 the EdDSA key that signs updates
# Nothing is written outside a private temp directory, which is deleted at the end.
set -euo pipefail
ROOT="${0:A:h:h:h}"
cd "$ROOT"
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
TEAM_ID="T98555J4F3"
IDENTITY="Developer ID Application: FormKit Inc. ($TEAM_ID)"
TMP=$(mktemp -d); chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT

only="${1:-all}"

if [[ "$only" == all || "$only" == cert ]]; then
  PASS=$(openssl rand -base64 30)
  echo "→ Exporting \"$IDENTITY\" (approve the keychain prompt; enter your login password if asked)…"
  P12="$TMP/devid.p12"
  if ! security export -t identities -f pkcs12 -P "$PASS" -o "$TMP/all.p12" 2>/dev/null; then
    echo "  Automatic export failed. In Keychain Access → login → My Certificates, right-click"
    echo "  \"$IDENTITY\" → Export… as .p12, then drag the file here and press return:"
    read -r "P12IN?  .p12 path: "; P12IN="${P12IN//\\ / }"; P12IN="${P12IN%\"}"; P12IN="${P12IN#\"}"
    read -rs "PASS?  its password: "; echo
    cp "$P12IN" "$P12"
  else
    # The export holds every identity in the keychain; keep only the Developer ID one.
    openssl pkcs12 -in "$TMP/all.p12" -passin "pass:$PASS" -nodes -out "$TMP/all.pem" 2>/dev/null \
      || openssl pkcs12 -legacy -in "$TMP/all.p12" -passin "pass:$PASS" -nodes -out "$TMP/all.pem"
    python3 -I - "$TMP/all.pem" "$TMP/devid.pem" "$IDENTITY" <<'PY'
import re, subprocess, sys
src, dst, name = sys.argv[1:4]
blocks = re.findall(r"(?:Bag Attributes.*?\n)?-----BEGIN [^-]+-----.*?-----END [^-]+-----\n", open(src).read(), re.S)
keyid = None
for b in blocks:
    if "CERTIFICATE" in b and name in b:
        cert = b; keyid = re.search(r"localKeyID: ([0-9A-F ]+)", b).group(1); break
if not keyid: sys.exit("Developer ID certificate not found in the export")
key = next(b for b in blocks if "PRIVATE KEY" in b and keyid in b)
open(dst, "w").write(cert + key)
PY
    openssl pkcs12 -export -in "$TMP/devid.pem" -out "$P12" -passout "pass:$PASS" \
      -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
  fi
  base64 -i "$P12" | gh secret set DEVELOPER_ID_P12_BASE64 -R "$REPO"
  printf '%s' "$PASS" | gh secret set DEVELOPER_ID_P12_PASSWORD -R "$REPO"
  echo "  ✓ Developer ID identity"
fi

if [[ "$only" == all || "$only" == notary ]]; then
  echo "→ Notarization: an app-specific password for your Apple ID (appleid.apple.com → Sign-In and Security"
  echo "  → App-Specific Passwords). The one notarytool already uses here works too."
  read -r "APPLE_ID?  Apple ID email: "
  read -rs "APP_PW?  App-specific password: "; echo
  xcrun notarytool history --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PW" >/dev/null \
    || { echo "  Apple didn't accept those credentials." >&2; exit 1; }
  printf '%s' "$APPLE_ID" | gh secret set NOTARY_APPLE_ID -R "$REPO"
  printf '%s' "$TEAM_ID" | gh secret set NOTARY_TEAM_ID -R "$REPO"
  printf '%s' "$APP_PW" | gh secret set NOTARY_APP_PASSWORD -R "$REPO"
  echo "  ✓ Notarization credentials"
fi

if [[ "$only" == all || "$only" == sparkle ]]; then
  GENERATE_KEYS=$(find "$ROOT/build/dev/SourcePackages/artifacts/sparkle" -type f -perm -u+x -path "*/bin/generate_keys" | head -1)
  [[ -n "$GENERATE_KEYS" ]] || { echo "Build the app once (tools/build.sh) so Sparkle's tools are present." >&2; exit 1; }
  "$GENERATE_KEYS" -x "$TMP/sparkle.key" >/dev/null
  gh secret set SPARKLE_ED_PRIVATE_KEY -R "$REPO" < "$TMP/sparkle.key"
  echo "  ✓ Sparkle update key"
fi
echo "Done. Release with: tools/tag-release.sh <version>"
