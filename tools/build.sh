#!/bin/zsh
# Builds Standard Music into build/dev. Serialised with a lock so concurrent callers don't collide.
#   tools/build.sh [Debug|Release]      → prints errors and the .app path
set -u
ROOT="${0:A:h:h}"
CONFIG="${1:-Debug}"
LOCK="$ROOT/build/.build.lock"
mkdir -p "$ROOT/build"
until mkdir "$LOCK" 2>/dev/null; do
  # Break stale locks (older than 20 minutes).
  if [[ -n $(find "$LOCK" -maxdepth 0 -mmin +20 2>/dev/null) ]]; then rmdir "$LOCK"; fi
  sleep 2
done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
cd "$ROOT"
if [[ ! -f StandardMusic.xcodeproj/project.pbxproj ]] || [[ project.yml -nt StandardMusic.xcodeproj/project.pbxproj ]] || [[ -n $(find StandardMusic Engine -newer StandardMusic.xcodeproj/project.pbxproj -type f -name '*.swift' 2>/dev/null | head -1) ]]; then
  xcodegen generate --quiet
fi
LOG="$ROOT/build/last-build-$CONFIG.log"
xcodebuild -project StandardMusic.xcodeproj -scheme StandardMusic -configuration "$CONFIG" \
  -derivedDataPath "$ROOT/build/dev" -destination 'platform=macOS' build > "$LOG" 2>&1
STATUS=$?
grep -E "^/.*(error|warning: unre):" "$LOG" | sort -u | head -60
if [[ $STATUS -eq 0 ]]; then
  echo "BUILD SUCCEEDED: $ROOT/build/dev/Build/Products/$CONFIG/Standard Music.app"
else
  echo "BUILD FAILED (full log: $LOG)"
fi
exit $STATUS
