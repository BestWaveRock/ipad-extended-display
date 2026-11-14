#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="iPad 扩展屏"
BUNDLE="../build/$APP_NAME.app"
SDK=$(xcrun --sdk macosx --show-sdk-path)

mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos14.0 -sdk "$SDK" \
  App.swift AppModel.swift ContentView.swift Permissions.swift StreamEngine.swift Usbmux.swift VirtualDisplay.swift \
  -o "$BUNDLE/Contents/MacOS/iPadExtendedDisplay" \
  -framework AppKit -framework SwiftUI -framework ScreenCaptureKit \
  -framework VideoToolbox -framework Network -framework ApplicationServices

cp Info.plist "$BUNDLE/Contents/Info.plist"
cp ../assets/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

codesign --force --sign - --timestamp=none "$BUNDLE" >/dev/null 2>&1 || true
echo "built: $(cd "$BUNDLE" && pwd)"
