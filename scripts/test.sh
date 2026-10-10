#!/bin/bash
# Offline source tests: synthetic snapshots only; no listening or UI interaction.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
WORK="$(mktemp -d "$PWD/build/tests/offline.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -j "${BUILD_JOBS:-$(sysctl -n hw.ncpu)}" -swift-version 5 -O -D DETECTION_SELF_TEST \
  Sources/Detection/*.swift Sources/Detection/Tests/DetectionSelfTests.swift \
  -o "$WORK/detection-self-tests"
KEYSCOPE_DENY_INPUT_MONITORING=1 "$WORK/detection-self-tests"
