#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

MODE=$1
APP=$2
STATUS=$3
EXECUTABLE="$APP/Contents/MacOS/hw_gallery"
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
CRASH_TIME=$(date '+%s')
DEST="build/crashes/$TIMESTAMP-$MODE"

mkdir -p "$DEST"
cp "$EXECUTABLE" "$DEST/hw_gallery"
if [ -d "$APP.dSYM" ]; then
  cp -R "$APP.dSYM" "$DEST/hw_gallery.app.dSYM"
fi
printf '[hw_gallery] executable and dSYM captured; waiting for macOS crash report...\n'
attempt=0
while [ "$attempt" -lt 30 ]; do
  REPORT=$(ls -t "$HOME"/Library/Logs/DiagnosticReports/hw_gallery-*.ips 2>/dev/null | sed -n '1p' || true)
  if [ -n "$REPORT" ]; then
    report_time=$(stat -f '%m' "$REPORT")
    if [ "$report_time" -ge "$CRASH_TIME" ]; then
      cp "$REPORT" "$DEST/"
      break
    fi
  fi
  attempt=$((attempt+1))
  if [ "$attempt" -lt 30 ]; then
    sleep 1
  fi
done

{
  printf 'mode=%s\n' "$MODE"
  printf 'exit_status=%s\n' "$STATUS"
  printf 'git_revision=%s\n' "$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  printf 'built_binary=%s\n' "$EXECUTABLE"
  xcrun dwarfdump --uuid "$EXECUTABLE" 2>/dev/null || true
} > "$DEST/metadata.txt"

printf '[hw_gallery] crash artifacts: %s\n' "$DEST"
