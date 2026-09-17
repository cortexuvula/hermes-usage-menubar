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
# Build output directory — override to package somewhere other than the
# repo's tracked build/ (test runner and CI redirect this into a temp dir
# so the committed artifact is never mutated).
BUILD_DIR_OUT="${HERMES_USAGE_BUILD_DIR:-$SRC/build}"

APP="$BUILD_DIR_OUT/HermesUsage.app"
CONTENTS="$APP/Contents"
BIN="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

fail() { echo "build.sh: $1" >&2; exit 1; }

# ---- Version stamping (t_b2280a32) -------------------------------------
# CFBundleShortVersionString / CFBundleVersion come from the RELEASE
# CONTEXT, never from a hardcoded literal: the caller (release.yml) passes
# the tag being built; arguments win, then env vars.
#   $1 / HERMES_USAGE_SHORT_VERSION  -> CFBundleShortVersionString (X.Y.Z)
#   $2 / HERMES_USAGE_BUILD_VERSION  -> CFBundleVersion (1-3 integers,
#                                       a monotonic build iteration)
# Untagged/local builds must NOT invent a release claim: the default short
# version is 0.0.0 and the default build number is derived from the source
# tree itself (commit count of HEAD), so a dev build is honest and can never
# be mistaken for a published release.
BUNDLE_SHORT_VERSION="${HERMES_USAGE_SHORT_VERSION:-${1:-}}"
BUNDLE_BUILD_VERSION="${HERMES_USAGE_BUILD_VERSION:-${2:-}}"
if [ -z "$BUNDLE_SHORT_VERSION" ]; then
  BUNDLE_SHORT_VERSION="0.0.0"
fi
if [ -z "$BUNDLE_BUILD_VERSION" ]; then
  COMMIT_COUNT="$(git rev-list --count HEAD 2>/dev/null || true)"
  if [ -z "$COMMIT_COUNT" ]; then
    # Xcode-license wall: the Xcode-shim git can refuse to run (exit 69).
    COMMIT_COUNT="$(/Library/Developer/CommandLineTools/usr/bin/git rev-list --count HEAD 2>/dev/null || true)"
  fi
  BUNDLE_BUILD_VERSION="${COMMIT_COUNT:-0}"
fi

# Apple's documented formats, asserted BEFORE any output is removed or
# compiled: short version is exactly three period-separated integers, build
# version is one to three; digits and periods only. A tag-derived value that
# fails (e.g. "1.1.0-beta") is REJECTED here, never stamped. Keeping this
# check ahead of every codesign also means an invalid value can never reach
# a signed artifact (Info.plist is sealed into the code directory, so a
# post-sign stamp would invalidate the signature instead).
[[ "$BUNDLE_SHORT_VERSION" =~ ^[0-9]+(\.[0-9]+){2}$ ]] \
  || fail "invalid CFBundleShortVersionString '$BUNDLE_SHORT_VERSION' — required format is three period-separated integers (digits and periods only)"
[[ "$BUNDLE_BUILD_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
  || fail "invalid CFBundleVersion '$BUNDLE_BUILD_VERSION' — required format is one to three period-separated integers (digits and periods only)"

# Hard rule (audit rework): never overwrite the live install from a
# non-default checkout. If the install target is the default ~/Applications
# AND this script is not running from the canonical checkout location,
# require an explicit HERMES_USAGE_INSTALL_DIR redirect. This prevents a
# test harness or foreign clone from clobbering the user's app.
CANONICAL="$HOME/Development/hermes-usage-menubar"
if [ "$INSTALL_DIR" = "$HOME/Applications" ] && [ "$SCRIPT_DIR" != "$CANONICAL" ]; then
  fail "refusing to install to ~/Applications from non-canonical checkout $SCRIPT_DIR — set HERMES_USAGE_INSTALL_DIR"
fi

# ---- Validate all inputs BEFORE removing any output (R4) ----
[ -f "$SRC/HermesUsage.swift" ] || fail "Swift source not found at $SRC/HermesUsage.swift (set HERMES_USAGE_SRC?)"
[ -f "$SRC/HermesUsageApp.swift" ] || fail "Swift source not found at $SRC/HermesUsageApp.swift"
[ -f "$SRC/make_icon.py" ] || fail "Icon generator not found at $SRC/make_icon.py"
[ -f "$COLLECTOR_SRC/collector/hermes-usage.py" ] || fail "Collector not found at $COLLECTOR_SRC/collector/hermes-usage.py (set COLLECTOR_SRC to your omarchy-hermes-usage checkout)"
[ -f "$COLLECTOR_SRC/hermes-usage-export/quota_io.py" ] || fail "quota_io.py not found at $COLLECTOR_SRC/hermes-usage-export/quota_io.py"
command -v xcrun >/dev/null 2>&1 || fail "xcrun not found — install Xcode command-line tools"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ -d "$INSTALL_DIR" ] || mkdir -p "$INSTALL_DIR" || fail "cannot create install dir $INSTALL_DIR"

# Only remove the build output after every input checked out. With
# HERMES_USAGE_BUILD_DIR set this never touches the repository at all.
mkdir -p "$BUILD_DIR_OUT"
rm -rf "$APP"
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

echo "==> Writing Info.plist (version ${BUNDLE_SHORT_VERSION}, build ${BUNDLE_BUILD_VERSION})..."
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Hermes Usage</string>
    <key>CFBundleDisplayName</key><string>Hermes Usage</string>
    <key>CFBundleIdentifier</key><string>ca.andrehugo.hermes-usage</string>
    <key>CFBundleVersion</key><string>${BUNDLE_BUILD_VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${BUNDLE_SHORT_VERSION}</string>
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
# Icon intermediates live inside the build output dir so the repository is
# never mutated — not even transiently or on a mid-build failure.
ICON_WORK="$BUILD_DIR_OUT/icon-work"
mkdir -p "$ICON_WORK"
cp "$SRC/make_icon.py" "$ICON_WORK/"
cd "$ICON_WORK"
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
rm -rf "$ICON_WORK"

echo "==> Ad-hoc codesigning..."
codesign --force --sign - "$APP"

echo "==> Verifying..."
# Fail the build if the generated plist is malformed or the signature does
# not verify — a broken bundle must never be installed (R4 rework).
plutil -lint "$CONTENTS/Info.plist" || fail "generated Info.plist failed plutil -lint"
# Version readback, asserted BEFORE codesign seals Info.plist into the code
# directory (t_b2280a32): what we stamped is what the bundle self-declares.
STAMPED_SHORT="$(plutil -extract CFBundleShortVersionString raw "$CONTENTS/Info.plist")"
STAMPED_BUILD="$(plutil -extract CFBundleVersion raw "$CONTENTS/Info.plist")"
[ "$STAMPED_SHORT" = "$BUNDLE_SHORT_VERSION" ] \
  || fail "CFBundleShortVersionString readback mismatch: requested '$BUNDLE_SHORT_VERSION', bundle says '$STAMPED_SHORT'"
[ "$STAMPED_BUILD" = "$BUNDLE_BUILD_VERSION" ] \
  || fail "CFBundleVersion readback mismatch: requested '$BUNDLE_BUILD_VERSION', bundle says '$STAMPED_BUILD'"
codesign --verify --deep --strict "$APP" || fail "codesign --verify --deep --strict failed"
codesign --verify --deep "$APP" && echo "signature OK"
file "$BIN/HermesUsage"

echo "==> Installing to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR/HermesUsage.app"
cp -R "$APP" "$INSTALL_DIR/"
echo "Installed: $INSTALL_DIR/HermesUsage.app"
echo "NOTE: current target is arm64 (Apple Silicon) only."
