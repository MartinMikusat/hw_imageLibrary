#!/bin/sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$ROOT/scripts/dev-launch-policy.sh"

APP="$ROOT/build/hw_imageLibrary.app"
EXECUTABLE="$APP/Contents/MacOS/hw_imageLibrary"
APP_PID=""
APP_HAS_LAUNCHED=0
LAUNCH_ACTIVATE=0
LAUNCH_VISIBLE=1
HW_IMAGE_LIBRARY_APP_SUPPORT_DIR=${HW_IMAGE_LIBRARY_APP_SUPPORT_DIR:-"$ROOT/build/dev-support"}
export HW_IMAGE_LIBRARY_APP_SUPPORT_DIR

fingerprint() {
  stat -f '%m:%z:%N' \
    "$ROOT"/src/*.odin \
    "$ROOT"/extension/src/*.ts \
    "$ROOT"/extension/*.html \
    "$ROOT"/extension/*.css \
    "$ROOT"/*.sh \
    "$ROOT"/scripts/*.sh \
    "$ROOT"/Info.plist \
    2>/dev/null | shasum | cut -d' ' -f1
}

app_is_frontmost() {
  [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null || return 1
  front_app=$(lsappinfo front 2>/dev/null) || return 1
  front_pid=$(lsappinfo info -only pid "$front_app" 2>/dev/null |
    sed -n 's/.*"pid"=\([0-9][0-9]*\).*/\1/p')
  [ "$front_pid" = "$APP_PID" ]
}

stop_app() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  APP_PID=""
}

cleanup() {
  exit_status=$?
  trap - INT TERM EXIT
  stop_app
  exit "$exit_status"
}

launch_app() {
  HW_IMAGE_LIBRARY_ACTIVATE_ON_LAUNCH=$LAUNCH_ACTIVATE
  HW_IMAGE_LIBRARY_VISIBLE_ON_LAUNCH=$LAUNCH_VISIBLE
  export HW_IMAGE_LIBRARY_ACTIVATE_ON_LAUNCH HW_IMAGE_LIBRARY_VISIBLE_ON_LAUNCH
  "$EXECUTABLE" &
  APP_PID=$!
}

rebuild_and_launch() {
  if ! "$ROOT/build.sh" debug; then
    printf 'build failed; leaving the current process unchanged\n' >&2
    return
  fi
  was_frontmost=0
  if [ "$APP_HAS_LAUNCHED" -eq 1 ] && app_is_frontmost; then was_frontmost=1; fi
  launch_policy=$(hw_image_library_dev_launch_policy "$APP_HAS_LAUNCHED" "$was_frontmost")
  LAUNCH_ACTIVATE=${launch_policy% *}
  LAUNCH_VISIBLE=${launch_policy#* }
  stop_app
  launch_app
  APP_HAS_LAUNCHED=1
  printf 'relaunched pid %s (activate=%s visible=%s)\n' "$APP_PID" "$LAUNCH_ACTIVATE" "$LAUNCH_VISIBLE"
}

trap cleanup INT TERM EXIT
rebuild_and_launch
LAST_FINGERPRINT=$(fingerprint)
while :; do
  sleep 0.5
  CURRENT_FINGERPRINT=$(fingerprint)
  if [ "$CURRENT_FINGERPRINT" != "$LAST_FINGERPRINT" ]; then
    LAST_FINGERPRINT=$CURRENT_FINGERPRINT
    rebuild_and_launch
  fi
done
