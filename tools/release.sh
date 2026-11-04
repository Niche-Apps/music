#!/bin/zsh
# Builds Release, signs with Developer ID (hardened runtime), notarizes and staples.
#   tools/release.sh            → build/release/StandardMusic.zip
# Needs the "Developer ID Application" identity in the keychain and a notarytool keychain profile
# (override with SM_SIGN_IDENTITY / SM_NOTARY_PROFILE / SM_NOTARY_KEYCHAIN). CI runs this from
# .github/workflows/release.yml.
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

# Inside out: the helper and Sparkle's nested executables first, then the app (which seals the
# resource bundles and frameworks). Sparkle's order follows its "Sandboxing/Code Signing" docs; the app
# isn't sandboxed, so its XPC services aren't used and are removed rather than shipped.
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
sign --identifier com.standardmusic.engine "$APP/Contents/MacOS/StandardMusicEngine"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null)" ]] \
  || { echo "Info.plist has no SUPublicEDKey; updates couldn't be verified." >&2; exit 1; }

ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" ${SM_NOTARY_KEYCHAIN:+--keychain "$SM_NOTARY_KEYCHAIN"} --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm "$OUT/notarize.zip"
ditto -c -k --keepParent "$APP" "$OUT/StandardMusic.zip"
echo "RELEASE READY: $OUT/StandardMusic.zip"
