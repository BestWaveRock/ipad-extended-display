#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="iPad 扩展屏"
VERSION="1.0.3"
DIST="dist"
TRASH="${TMPDIR:-/tmp}/ipad-display-trash"
export ARCHS=${ARCHS:-"arm64 x86_64"}

mkdir -p "$DIST" "$TRASH"
./src/build-app.sh

STAGE=$(mktemp -d "$TRASH/stage.XXXXXX")
cp -R "build/$APP_NAME.app" "$STAGE/"
ln -sfn /Applications "$STAGE/Applications"

DMG="$DIST/iPad-Extended-Display-$VERSION.dmg"
if [[ -f "$DMG" ]]; then
  mv "$DMG" "$TRASH/iPad-Extended-Display-$VERSION-$(date +%H%M%S).dmg"
fi
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "dmg: $(cd "$DIST" && pwd)/$(basename "$DMG")"
