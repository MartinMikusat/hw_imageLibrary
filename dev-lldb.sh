#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

HW_GALLERY_APP_SUPPORT_DIR=${HW_GALLERY_APP_SUPPORT_DIR:-"$ROOT/build/dev-support"}
export HW_GALLERY_APP_SUPPORT_DIR

./build.sh debug
APP="$ROOT/build/hw_gallery.app"
EXECUTABLE="$APP/Contents/MacOS/hw_gallery"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
SESSION="$ROOT/build/lldb-sessions/$TIMESTAMP"
mkdir -p "$SESSION"
cp "$EXECUTABLE" "$SESSION/hw_gallery"
cp -R "$APP.dSYM" "$SESSION/hw_gallery.app.dSYM"
{
  printf 'git_revision=%s\n' "$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  xcrun dwarfdump --uuid "$EXECUTABLE"
} > "$SESSION/metadata.txt"

script -q -F "$SESSION/lldb.log" env MTL_DEBUG_LAYER=1 lldb --batch \
  -o run \
  -k 'thread backtrace all' \
  -k 'register read' \
  -k 'frame select 1' \
  -k 'disassemble --frame --bytes' \
  -- "$EXECUTABLE" "$@"

printf '[hw_gallery] LLDB session artifacts: %s\n' "$SESSION"
