#!/bin/bash
# I2: test runner. Compiles the library portion of the app plus the test
# files into a temp-dir binary and runs them. Never touches ~/Applications,
# never needs a real Hermes home (tests use scripted executors and fixtures).
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

echo
echo "ALL TEST SUITES PASSED"
