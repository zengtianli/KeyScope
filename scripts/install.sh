#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -gt 1 ]; then echo 'Usage: bash scripts/install.sh [path/to/KeyScope.app]' >&2; exit 2; fi
APP="${1:-$DIR/build/KeyScope.app}"
DEST="${INSTALL_DEST:-/Applications/KeyScope.app}"
# Overrides exist for sandbox checks; defaults are the real locations.
BIN_DIR="${CLI_BIN_DIR:-$HOME/.local/bin}"
KEYS_DIR="${MACKIT_KEYS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mackit/keys.d}"
BACKUP_ROOT="${INSTALL_BACKUP_DIR:-$DIR/build/installed-backup}"
CLI_TARGET="$DEST/Contents/Resources/bin/keyscope"
test -d "$APP"
codesign --verify --deep --strict "$APP"
if [ ! -L "$APP/Contents/Resources/bin/keyscope" ]; then
  echo "$APP has no agent CLI (Contents/Resources/bin/keyscope). Rebuild with bash build.sh." >&2
  exit 1
fi
if pgrep -x KeyScope >/dev/null; then
  echo 'KeyScope is running. Quit it before replacing the installed app.' >&2
  exit 1
fi
# Never replace a keyscope command that belongs to something else.
if { [ -e "$BIN_DIR/keyscope" ] || [ -L "$BIN_DIR/keyscope" ]; } && [ "$(readlink "$BIN_DIR/keyscope" || true)" != "$CLI_TARGET" ]; then
  echo "$BIN_DIR/keyscope exists and is not KeyScope's link; inspect it before installing." >&2
  exit 1
fi
if [ -e "$DEST" ]; then
  test "$(plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist")" = cyou.tianli.keyscope
  BACKUP="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP"
  mv "$DEST" "$BACKUP/KeyScope.app"
fi
ditto "$APP" "$DEST"
codesign --verify --deep --strict "$DEST"
cmp "$APP/Contents/MacOS/KeyScope" "$DEST/Contents/MacOS/KeyScope"
mkdir -p "$BIN_DIR"
ln -sfn "$CLI_TARGET" "$BIN_DIR/keyscope"
"$BIN_DIR/keyscope" --help >/dev/null
test "$("$BIN_DIR/keyscope" --version)" = "$("$DEST/Contents/MacOS/KeyScope" --version)"
# Optional MacKit key catalog: mackit keys / doctor read keys.d, so the window's shortcuts are
# registered by linking this repo's keys.json there. Not an app dependency; an existing entry is kept.
if [ -d "$KEYS_DIR" ] && [ -f "$DIR/keys.json" ] && [ ! -e "$KEYS_DIR/keyscope.json" ] && [ ! -L "$KEYS_DIR/keyscope.json" ]; then
  ln -s "$DIR/keys.json" "$KEYS_DIR/keyscope.json"
fi
echo "Installed: $DEST"
echo "CLI: $BIN_DIR/keyscope -> $CLI_TARGET (add $BIN_DIR to PATH if needed)"
