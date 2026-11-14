#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -swift-version 5 main.swift \
  ../src/StreamEngine.swift ../src/Usbmux.swift ../src/VirtualDisplay.swift \
  -o ipad-usb-display \
  -framework AppKit -framework Network -framework ScreenCaptureKit -framework VideoToolbox
echo "built: $(pwd)/ipad-usb-display"
