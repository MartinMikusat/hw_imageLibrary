#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOCAL_COMMAND_ROOT="$ROOT/../hw_odin_ipc_localCommand"
MATCH_SORTER_ROOT="$ROOT/../hw_odin_matchSorter"
COMMAND_PALETTE_ROOT="$ROOT/../hw_odin_ui_commandPalette"
FLASH_ROOT="$ROOT/../hw_odin_ui_flash"
UI_FRAMEWORK_ROOT="$ROOT/../hw_odin_ui_framework"
MODE=${1:-debug}

for dependency in \
  "$LOCAL_COMMAND_ROOT/local_command.odin" \
  "$MATCH_SORTER_ROOT/match_sorter.odin" \
  "$COMMAND_PALETTE_ROOT/command_palette.odin" \
  "$FLASH_ROOT/flash.odin" \
  "$UI_FRAMEWORK_ROOT/metal/metal.odin"
do
  if [ ! -f "$dependency" ]; then
    echo "missing Odin dependency: $dependency" >&2
    exit 1
  fi
done

case "$MODE" in
  debug)
    APP="$ROOT/build/hw_gallery.app"
    ODIN_FLAGS="-debug -o:none"
    ;;
  release)
    APP="$ROOT/build/release/hw_gallery.app"
    ODIN_FLAGS="-o:speed"
    if [ -z "${HW_GALLERY_CODESIGN_IDENTITY:-}" ]; then
      echo "release builds require HW_GALLERY_CODESIGN_IDENTITY for iCloud entitlements" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: ./build.sh [debug|release]" >&2
    exit 2
    ;;
esac

STAGING="$APP.staging.$$"
cleanup() {
  rm -rf "$STAGING"
}
trap cleanup INT TERM EXIT
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources/extension"

if xcrun metal -help >/dev/null 2>&1; then
  "$UI_FRAMEWORK_ROOT/scripts/build-metallib.sh" \
    "$STAGING/Contents/Resources/ui.metallib"
elif [ "$MODE" = release ]; then
  echo "release builds require Apple's optional Metal shader toolchain" >&2
  exit 1
fi

hw-odin build "$ROOT/src" \
  -out:"$STAGING/Contents/MacOS/hw_gallery" \
  $ODIN_FLAGS \
  -collection:local_command="$LOCAL_COMMAND_ROOT" \
  -collection:match_sorter="$MATCH_SORTER_ROOT" \
  -collection:command_palette="$COMMAND_PALETTE_ROOT" \
  -collection:flash="$FLASH_ROOT" \
  -collection:ui_framework="$UI_FRAMEWORK_ROOT" \
  -extra-linker-flags:"-framework AppKit -framework Foundation -framework CoreText -framework CoreGraphics -framework ImageIO -framework Metal -framework MetalKit -framework QuartzCore"
cp "$STAGING/Contents/MacOS/hw_gallery" "$STAGING/Contents/MacOS/hw_gallery-service"
cp "$STAGING/Contents/MacOS/hw_gallery" "$STAGING/Contents/MacOS/hw_gallery-native-host"
cp "$ROOT/Info.plist" "$STAGING/Contents/Info.plist"

npm run build --prefix "$ROOT/extension"
cp "$ROOT/extension/manifest.json" "$STAGING/Contents/Resources/extension/manifest.json"
cp "$ROOT/extension/preview.html" "$STAGING/Contents/Resources/extension/preview.html"
cp "$ROOT/extension/preview.css" "$STAGING/Contents/Resources/extension/preview.css"
mkdir -p "$STAGING/Contents/Resources/extension/dist"
cp "$ROOT/extension/dist/"*.js "$STAGING/Contents/Resources/extension/dist/"

rm -rf "$APP"
mkdir -p "$(dirname -- "$APP")"
mv "$STAGING" "$APP"
trap - INT TERM EXIT

if [ "$MODE" = release ]; then
  codesign --force --options runtime \
    --entitlements "$ROOT/entitlements.plist" \
    --sign "$HW_GALLERY_CODESIGN_IDENTITY" \
    "$APP"
fi

cp "$APP/Contents/MacOS/hw_gallery" "$ROOT/build/hw_gallery"
printf 'built %s\n' "$APP"
