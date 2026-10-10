#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
# BUILD_OUT (relative to this repo, default build) lets a preview build land beside the frozen release
# product build/KeyScope.app instead of replacing it; only the default output can be installed.
OUT="${BUILD_OUT:-build}"
case "$OUT" in *..*) echo "BUILD_OUT must not contain .." >&2; exit 2 ;; build|build/*) ;; *) echo 'BUILD_OUT must be build or a folder under build/' >&2; exit 2 ;; esac
if [ "${INSTALL_APP:-0}" = 1 ] && [ "$OUT" != build ]; then echo 'INSTALL_APP=1 installs build/KeyScope.app; unset BUILD_OUT' >&2; exit 2; fi
if [ -n "${XCODE_ENV_SH:-}" ]; then
  source "$XCODE_ENV_SH"
  xcode_env_use macosx
fi
xcrun --sdk macosx --show-sdk-path >/dev/null
mkdir -p "$DIR/build" "$DIR/$OUT"
STAGE="$(mktemp -d "$DIR/build/compile.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/KeyScope.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
SOURCES=()
while IFS= read -r line; do SOURCES+=("$line"); done < <(find Sources -type f -name '*.swift' ! -path '*/Tests/*' | LC_ALL=C sort)
[ ${#SOURCES[@]} -gt 0 ] || { echo 'No Swift sources' >&2; exit 1; }
xcrun swiftc -j "${BUILD_JOBS:-$(sysctl -n hw.ncpu)}" -swift-version 5 -O -whole-module-optimization -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" "${SOURCES[@]}" \
  -o "$APP/Contents/MacOS/KeyScope"
# Drop the local symbol table (about half the executable); behaviour is unchanged.
strip -x "$APP/Contents/MacOS/KeyScope"
# Agent CLI: the same executable under the name keyscope (scripts/install.sh links ~/.local/bin/keyscope here).
mkdir -p "$APP/Contents/Resources/bin"
ln -s ../../MacOS/KeyScope "$APP/Contents/Resources/bin/keyscope"
IDENTITY="${CODESIGN_IDENTITY:--}"
if [ "$IDENTITY" = '-' ]; then
  codesign --force --sign - --identifier cyou.tianli.keyscope \
    --requirements '=designated => identifier "cyou.tianli.keyscope"' "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --deep --strict "$APP"
test "$(lipo -archs "$APP/Contents/MacOS/KeyScope")" = arm64
"$APP/Contents/MacOS/KeyScope" --version
"$APP/Contents/Resources/bin/keyscope" --help >/dev/null
test "$("$APP/Contents/Resources/bin/keyscope" --version)" = "$("$APP/Contents/MacOS/KeyScope" --version)"
python3 scripts/build-metadata.py "$APP" "$STAGE/build.json"
if [ -e "$OUT/KeyScope.app" ]; then
  rm -rf "$OUT/KeyScope.previous.app"
  mv "$OUT/KeyScope.app" "$OUT/KeyScope.previous.app"
fi
mv "$APP" "$OUT/KeyScope.app"
mv "$STAGE/build.json" "$OUT/build.json"
echo "Built: $DIR/$OUT/KeyScope.app"
if [ "${INSTALL_APP:-0}" = 1 ]; then bash scripts/install.sh; fi
