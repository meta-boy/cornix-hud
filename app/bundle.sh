#!/usr/bin/env bash
# Build CornixHUD.app (menu-bar only, ad-hoc signed) into ./build.
#   ./bundle.sh && open build/CornixHUD.app
set -euo pipefail
cd "$(dirname "$0")"

# Universal binary so the release runs on Apple silicon and Intel.
build=(swift build -c release --arch arm64 --arch x86_64)
"${build[@]}"
app=build/CornixHUD.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$("${build[@]}" --show-bin-path)/CornixHUD" "$app/Contents/MacOS/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.metaboy.cornix-hud</string>
    <key>CFBundleName</key><string>Cornix HUD</string>
    <key>CFBundleExecutable</key><string>CornixHUD</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Cornix HUD reads your keyboard's battery levels over Bluetooth.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "built $app"
