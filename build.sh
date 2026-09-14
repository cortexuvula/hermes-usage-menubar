#!/bin/bash
# Build Hermes Usage menu bar app for macOS
set -euo pipefail

SRC="/Users/cortexuvula/Development/hermes-usage-menubar"
COLLECTOR_SRC="/Users/cortexuvula/Development/omarchy-hermes-usage"
APP="$SRC/build/HermesUsage.app"
CONTENTS="$APP/Contents"
BIN="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

rm -rf "$SRC/build"
mkdir -p "$BIN" "$RES/collector" "$RES/hermes-usage-export"

echo "==> Compiling Swift (release)..."
cd "$SRC"
xcrun swiftc -O -parse-as-library \
  -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit \
  HermesUsage.swift -o "$BIN/HermesUsage"

echo "==> Packaging collector..."
cp "$COLLECTOR_SRC/collector/hermes-usage.py" "$RES/collector/"
cp "$COLLECTOR_SRC/hermes-usage-export/quota_io.py" "$RES/hermes-usage-export/"

echo "==> Writing Info.plist..."
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Hermes Usage</string>
    <key>CFBundleDisplayName</key><string>Hermes Usage</string>
    <key>CFBundleIdentifier</key><string>ca.andrehugo.hermes-usage</string>
    <key>CFBundleVersion</key><string>1.0.0</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleExecutable</key><string>HermesUsage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT — port of r0b0tlab/omarchy-hermes-usage</string>
</dict>
</plist>
PLIST

echo "==> Building app icon..."
cd "$SRC"
python3 make_icon.py
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
cp icon_1024.png AppIcon.iconset/icon_512x512@2x.png
sips -z 16 16 icon_1024.png --out AppIcon.iconset/icon_16x16.png >/dev/null 2>&1
sips -z 32 32 icon_1024.png --out AppIcon.iconset/icon_16x16@2x.png >/dev/null 2>&1
sips -z 32 32 icon_1024.png --out AppIcon.iconset/icon_32x32.png >/dev/null 2>&1
sips -z 64 64 icon_1024.png --out AppIcon.iconset/icon_32x32@2x.png >/dev/null 2>&1
sips -z 128 128 icon_1024.png --out AppIcon.iconset/icon_128x128.png >/dev/null 2>&1
sips -z 256 256 icon_1024.png --out AppIcon.iconset/icon_128x128@2x.png >/dev/null 2>&1
sips -z 256 256 icon_1024.png --out AppIcon.iconset/icon_256x256.png >/dev/null 2>&1
sips -z 512 512 icon_1024.png --out AppIcon.iconset/icon_256x256@2x.png >/dev/null 2>&1
sips -z 512 512 icon_1024.png --out AppIcon.iconset/icon_512x512.png >/dev/null 2>&1
iconutil -c icns AppIcon.iconset -o AppIcon.icns
cp AppIcon.icns "$RES/AppIcon.icns"
rm -rf AppIcon.iconset icon_1024.png AppIcon.icns

echo "==> Ad-hoc codesigning..."
codesign --force --sign - "$APP"

echo "==> Verifying..."
codesign --verify --deep "$APP" && echo "signature OK"
file "$BIN/HermesUsage"

echo "==> Installing to ~/Applications..."
mkdir -p ~/Applications
rm -rf ~/Applications/HermesUsage.app
cp -R "$APP" ~/Applications/
echo "Installed: ~/Applications/HermesUsage.app"
