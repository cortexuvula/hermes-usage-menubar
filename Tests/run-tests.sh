#!/bin/bash
# I2: test runner. Compiles the library portion of the app plus the test
# files into a temp-dir binary and runs them. Never touches ~/Applications,
# never needs a real Hermes home (tests use scripted executors and fixtures).
#
# Also packages a throwaway bundle via build.sh with BOTH the install dir
# and the build output dir redirected into a temp directory, then validates
# it with plutil -lint + codesign --deep --strict, and finally ASSERTS the
# repository working tree is still clean — the committed build/ artifact
# must never be mutated by running the tests (Codie blocking item 2).
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="${TEST_BUILD_DIR:-$(mktemp -d /tmp/hu-tests.XXXXXX)}"
mkdir -p "$BUILD_DIR"

echo "==> Typecheck (library + app)"
xcrun swiftc -typecheck -parse-as-library -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit \
  HermesUsage.swift HermesUsageApp.swift

echo "==> Building R1 lifecycle tests (real subprocess executor)"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit \
  HermesUsage.swift Tests/R1LifecycleTests.swift -o "$BUILD_DIR/r1tests"
"$BUILD_DIR/r1tests"

echo "==> Building I2 contract/lifecycle tests (scripted executor)"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit \
  HermesUsage.swift Tests/I2ContractTests.swift -o "$BUILD_DIR/i2tests"
"$BUILD_DIR/i2tests"

echo "==> Bundle validation (build + install both redirected; repo untouched)"
# Seed a throwaway COLLECTOR_SRC from the tracked copies so no upstream
# checkout is needed.
SEED="$BUILD_DIR/collector-seed"
mkdir -p "$SEED/collector" "$SEED/hermes-usage-export"
cp build/HermesUsage.app/Contents/Resources/collector/hermes-usage.py "$SEED/collector/"
cp build/HermesUsage.app/Contents/Resources/hermes-usage-export/quota_io.py "$SEED/hermes-usage-export/"
COLLECTOR_SRC="$SEED" \
HERMES_USAGE_BUILD_DIR="$BUILD_DIR/pkg" \
HERMES_USAGE_INSTALL_DIR="$BUILD_DIR/install" \
  ./build.sh > "$BUILD_DIR/bundle-build.log" 2>&1 || {
    echo "build.sh failed during test packaging:"; tail -20 "$BUILD_DIR/bundle-build.log"; exit 1;
  }
APP="$BUILD_DIR/pkg/HermesUsage.app"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -1
test -d "$BUILD_DIR/install/HermesUsage.app" || { echo "FAIL: redirected install produced no bundle"; exit 1; }
plutil -lint "$BUILD_DIR/install/HermesUsage.app/Contents/Info.plist"

echo "==> Repository-cleanliness assertion (blocking item 2)"
if [ -n "$(git status --porcelain)" ]; then
  echo "FAIL: test run mutated the repository working tree:"
  git status --porcelain
  exit 1
fi
echo "git status --porcelain empty ✓ — committed artifact untouched"

echo
echo "ALL TEST SUITES PASSED"
