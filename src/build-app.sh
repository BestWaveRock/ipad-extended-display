#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="iPad 扩展屏"
BUNDLE="../build/$APP_NAME.app"
SDK=$(xcrun --sdk macosx --show-sdk-path)
ARCHS=${ARCHS:-arm64}

mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

SLICES=()
for arch in ${=ARCHS}; do
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos14.0" -sdk "$SDK" \
    App.swift AppModel.swift ContentView.swift KeyboardFocus.swift Permissions.swift StreamEngine.swift Usbmux.swift VirtualDisplay.swift WifiDiscovery.swift \
    -o "../build/ipad-display-$arch" \
    -framework AppKit -framework SwiftUI -framework ScreenCaptureKit \
    -framework VideoToolbox -framework Network -framework ApplicationServices
  SLICES+=("../build/ipad-display-$arch")
done

if (( ${#SLICES[@]} > 1 )); then
  lipo -create "${SLICES[@]}" -output "$BUNDLE/Contents/MacOS/iPadExtendedDisplay"
else
  cp "${SLICES[1]}" "$BUNDLE/Contents/MacOS/iPadExtendedDisplay"
fi

cp Info.plist "$BUNDLE/Contents/Info.plist"
cp ../assets/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

codesign --force --sign - --timestamp=none "$BUNDLE" >/dev/null 2>&1 || true
echo "built: $(cd "$BUNDLE" && pwd) [${ARCHS}]"
