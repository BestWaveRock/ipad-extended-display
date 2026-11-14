#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OUT=build
APP="$OUT/Payload/iPadDisplay.app"
TRASH="${TMPDIR:-/tmp}/ipad-display-ios-trash"
mkdir -p "$TRASH"
if [[ -d "$OUT" ]]; then mv "$OUT" "$TRASH/build-$(date +%H%M%S)"; fi
mkdir -p "$APP"

clang -c -target arm64-apple-ios12.5 -isysroot "$SDK" -fobjc-arc ExceptionGuard.m -o "$OUT/ExceptionGuard.o"

swiftc -target arm64-apple-ios12.5 -sdk "$SDK" -O -parse-as-library main.swift "$OUT/ExceptionGuard.o" -o "$APP/iPadDisplay" \
  -import-objc-header Bridging.h \
  -framework UIKit -framework Network -framework AVFoundation -framework CoreMedia -framework VideoToolbox

cp ../assets/ios/*.png "$APP/"

cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleExecutable</key><string>iPadDisplay</string>
    <key>CFBundleIdentifier</key><string>com.loop.ipaddisplay</string>
    <key>CFBundleName</key><string>iPadDisplay</string>
    <key>CFBundleDisplayName</key><string>iPad 扩展屏</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.3</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>NSLocalNetworkUsageDescription</key><string>用于在局域网内被 Mac 发现，把 iPad 作为扩展屏。</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_ipaddisplay._tcp</string>
    </array>
    <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleIcons</key>
    <dict>
        <key>CFBundlePrimaryIcon</key>
        <dict>
            <key>CFBundleIconFiles</key>
            <array>
                <string>Icon-20</string>
                <string>Icon-29</string>
                <string>Icon-40</string>
                <string>Icon-60</string>
            </array>
        </dict>
    </dict>
    <key>CFBundleIcons~ipad</key>
    <dict>
        <key>CFBundlePrimaryIcon</key>
        <dict>
            <key>CFBundleIconFiles</key>
            <array>
                <string>Icon-20</string>
                <string>Icon-29</string>
                <string>Icon-40</string>
                <string>Icon-76</string>
                <string>Icon-83.5</string>
            </array>
        </dict>
    </dict>
    <key>MinimumOSVersion</key><string>12.5</string>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>DTPlatformName</key><string>iphoneos</string>
    <key>DTSDKName</key><string>iphoneos27.0</string>
    <key>DTPlatformVersion</key><string>27.0</string>
    <key>DTXcode</key><string>2700</string>
    <key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
    <key>UIStatusBarHidden</key><true/>
    <key>UIViewControllerBasedStatusBarAppearance</key><false/>
    <key>UIRequiresFullScreen</key><true/>
    <key>UIWhitePointAdaptivityStyle</key><string>UIWhitePointAdaptivityStyleFull</string>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UISupportedInterfaceOrientations~ipad</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationPortraitUpsideDown</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
</dict>
</plist>
PLIST

if [[ -f iPadDisplay.ipa ]]; then mv iPadDisplay.ipa "${TMPDIR:-/tmp}/iPadDisplay-old-$(date +%H%M%S).ipa"; fi
(cd "$OUT" && zip -qry ../iPadDisplay.ipa Payload)
cp iPadDisplay.ipa "$HOME/Downloads/iPadDisplay.ipa"
echo "built: $(pwd)/iPadDisplay.ipa"
echo "copied: $HOME/Downloads/iPadDisplay.ipa"
