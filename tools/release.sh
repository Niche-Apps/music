#!/bin/zsh
# Builds Release, signs with Developer ID (hardened runtime), notarizes and staples.
#   tools/release.sh            → build/release/StandardMusic.zip
# Needs the "Developer ID Application" identity in the keychain and a notarytool keychain profile
# (override with SM_SIGN_IDENTITY / SM_NOTARY_PROFILE).
set -euo pipefail
ROOT="${0:A:h:h}"
IDENTITY="${SM_SIGN_IDENTITY:-Developer ID Application: FormKit Inc. (T98555J4F3)}"
PROFILE="${SM_NOTARY_PROFILE:-standard-code-notary}"
OUT="$ROOT/build/release"
APP="$OUT/Standard Music.app"
ENTITLEMENTS="$ROOT/StandardMusic/StandardMusic.entitlements"

"$ROOT/tools/build.sh" Release
rm -rf "$OUT"; mkdir -p "$OUT"
ditto "$ROOT/build/dev/Build/Products/Release/Standard Music.app" "$APP"

# Inside out: the helper first, then the app (which seals the resource bundles).
codesign --force --timestamp --options runtime --sign "$IDENTITY" \
  --identifier com.standardmusic.engine "$APP/Contents/MacOS/StandardMusicEngine"
codesign --force --timestamp --options runtime --sign "$IDENTITY" \
  --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm "$OUT/notarize.zip"
ditto -c -k --keepParent "$APP" "$OUT/StandardMusic.zip"
echo "RELEASE READY: $OUT/StandardMusic.zip"
