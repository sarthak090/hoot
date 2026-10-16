#!/bin/bash
# Builds build/Hoot.app with only the Xcode Command Line Tools (no Xcode, no XcodeGen).
#   ./scripts/build-app.sh            release build
#   CONFIG=debug ./scripts/build-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
OUT="$ROOT/build"
APP="$OUT/Hoot.app"

cd "$ROOT"
swift build -c "$CONFIG" --product Hoot
swift build -c "$CONFIG" --product hoot-art
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP" "$OUT/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

"$BIN/hoot-art" iconset "$OUT/AppIcon.iconset"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$OUT/AppIcon.iconset"

cp "$BIN/Hoot" "$APP/Contents/MacOS/Hoot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -d Resources/hooks ]; then
    cp -R Resources/hooks "$APP/Contents/Resources/hooks"
fi

# Ad-hoc signature: required for notifications and SMAppService. Not notarized; personal use only.
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
