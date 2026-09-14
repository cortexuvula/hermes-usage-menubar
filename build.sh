#!/bin/bash
# Build Hermes Usage menu bar app for macOS
# R4: resolves the project root from this script's own location so any
# checkout builds correctly; the upstream collector location is configurable
# via COLLECTOR_SRC (env var) and validated BEFORE any output is removed.
set -euo pipefail

# Project root = directory containing this script, wherever the clone lives.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERMES_USAGE_SRC:-$SCRIPT_DIR}"
# Upstream collector checkout — override with COLLECTOR_SRC env var.
COLLECTOR_SRC="${COLLECTOR_SRC:-$HOME/Development/omarchy-hermes-usage}"
# Install destination — override to build without touching ~/Applications.
INSTALL_DIR="${HERMES_USAGE_INSTALL_DIR:-$HOME/Applications}"

APP="$SRC/build/HermesUsage.app"
CONTENTS="$APP/Contents"
BIN="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

fail() { echo "build.sh: $1" >&2; exit 1; }

# ---- Validate all inputs BEFORE removing any output (R4) ----
[ -f "$SRC/HermesUsage.swift" ] || fail "Swift source not found at $SRC/HermesUsage.swift (set HERMES_USAGE_SRC?)"
[ -f "$SRC/HermesUsageApp.swift" ] || fail "Swift source not found at $SRC/HermesUsageApp.swift"
[ -f "$SRC/make_icon.py" ] || fail "Icon generator not found at $SRC/make_icon.py"
[ -f "$COLLECTOR_SRC/collector/hermes-usage.py" ] || fail "Collector not found at $COLLECTOR_SRC/collector/hermes-usage.py (set COLLECTOR_SRC to your omarchy-hermes-usage checkout)"
[ -f "$COLLECTOR_SRC/hermes-usage-export/quota_io.py" ] || fail "quota_io.py not found at $COLLECTOR_SRC/hermes-usage-export/quota_io.py"
command -v xcrun >/dev/null 2>&1 || fail "xcrun not found — install Xcode command-line tools"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ -d "$INSTALL_DIR" ] || mkdir -p "$INSTALL_DIR" || fail "cannot create install dir $INSTALL_DIR"

# Only remove the build output after every input checked out.
rm -rf "$SRC/build"
mkdir -p "$BIN" "$RES/collector" "$RES/hermes-usage-export"

echo "==> Compiling Swift (release)..."
cd "$SRC"
xcrun swiftc -O -parse-as-library \
  -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit \
  HermesUsage.swift HermesUsageApp.swift -o "$BIN/HermesUsage"

echo "==> Packaging collector from $COLLECTOR_SRC..."
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
    <key>CFBundlePackageType</key><string>APPL</key>
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

echo "==> Installing to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR/HermesUsage.app"
cp -R "$APP" "$INSTALL_DIR/"
echo "Installed: $INSTALL_DIR/HermesUsage.app"
echo "NOTE: current target is arm64 (Apple Silicon) only."
