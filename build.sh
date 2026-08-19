#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOCAL_COMMAND_ROOT="$ROOT/../hw_odin_ipc_localCommand"
MATCH_SORTER_ROOT="$ROOT/../hw_odin_matchSorter"
COMMAND_PALETTE_ROOT="$ROOT/../hw_odin_ui_commandPalette"
FLASH_ROOT="$ROOT/../hw_odin_ui_flash"
UI_FRAMEWORK_ROOT="$ROOT/../hw_odin_ui_framework"
IMAGE_SIMILARITY_ROOT="$ROOT/../hw_odin_imageSimilarity"
MODE=${1:-debug}

STRICT_DEPENDENCIES=""
if [ "$MODE" = release ]; then
  STRICT_DEPENDENCIES="--strict"
fi
"$ROOT/scripts/dependencies.sh" check $STRICT_DEPENDENCIES

for dependency in \
  "$LOCAL_COMMAND_ROOT/local_command.odin" \
  "$MATCH_SORTER_ROOT/match_sorter.odin" \
  "$COMMAND_PALETTE_ROOT/command_palette.odin" \
  "$FLASH_ROOT/flash.odin" \
  "$UI_FRAMEWORK_ROOT/metal/metal.odin" \
  "$IMAGE_SIMILARITY_ROOT/image.odin"
do
  if [ ! -f "$dependency" ]; then
    echo "[hw_gallery] missing Odin dependency: $dependency" >&2
    exit 1
  fi
done

case "$MODE" in
  debug)
    APP="$ROOT/build/hw_gallery.app"
    ODIN_FLAGS="-debug -o:none -keep-temp-files"
    ;;
  trace)
    APP="$ROOT/build/trace/hw_gallery.app"
    ODIN_FLAGS="-debug -o:none -keep-temp-files"
    ;;
  asan)
    APP="$ROOT/build/asan/hw_gallery.app"
    ODIN_FLAGS="-debug -o:none -keep-temp-files -sanitize:address"
    ;;
  release)
    APP="$ROOT/build/release/hw_gallery.app"
    ODIN_FLAGS="-o:speed"
    if [ -z "${HW_GALLERY_CODESIGN_IDENTITY:-}" ]; then
      echo "[hw_gallery] release builds require HW_GALLERY_CODESIGN_IDENTITY for iCloud entitlements" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: ./build.sh [debug|trace|asan|release]" >&2
    exit 2
    ;;
esac

mkdir -p "$APP/Contents/MacOS" \
  "$APP/Contents/Resources/extension" \
  "$APP/Contents/Resources/Icons/Iconoir"

if xcrun metal -help >/dev/null 2>&1; then
  "$UI_FRAMEWORK_ROOT/scripts/build-metallib.sh" \
    "$APP/Contents/Resources/ui.metallib"
elif [ "$MODE" = release ]; then
  echo "[hw_gallery] release builds require Apple's optional Metal shader toolchain" >&2
  exit 1
fi

hw-odin build "$ROOT/src" \
  -out:"$APP/Contents/MacOS/hw_gallery" \
  $ODIN_FLAGS \
  -collection:local_command="$LOCAL_COMMAND_ROOT" \
  -collection:match_sorter="$MATCH_SORTER_ROOT" \
  -collection:command_palette="$COMMAND_PALETTE_ROOT" \
  -collection:flash="$FLASH_ROOT" \
  -collection:ui_framework="$UI_FRAMEWORK_ROOT" \
  -collection:image_similarity="$IMAGE_SIMILARITY_ROOT" \
  -extra-linker-flags:"-framework AppKit -framework Foundation -framework CoreText -framework CoreGraphics -framework ImageIO -framework Metal -framework MetalKit -framework QuartzCore"
cp "$APP/Contents/MacOS/hw_gallery" "$APP/Contents/MacOS/hw_gallery-service"
cp "$APP/Contents/MacOS/hw_gallery" "$APP/Contents/MacOS/hw_gallery-native-host"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
ICON_ROOT="$ROOT/resources/icons/iconoir"
cp "$ICON_ROOT/xmark.svg" "$APP/Contents/Resources/Icons/Iconoir/xmark.svg"
cp "$ICON_ROOT/minus.svg" "$APP/Contents/Resources/Icons/Iconoir/minus.svg"
cp "$ICON_ROOT/maximize.svg" "$APP/Contents/Resources/Icons/Iconoir/maximize.svg"
cp "$ICON_ROOT/settings.svg" "$APP/Contents/Resources/Icons/Iconoir/settings.svg"
cp "$ICON_ROOT/LICENSE" "$APP/Contents/Resources/Icons/Iconoir/LICENSE"

npm run build --prefix "$ROOT/extension"
cp "$ROOT/extension/manifest.json" "$APP/Contents/Resources/extension/manifest.json"
cp "$ROOT/extension/preview.html" "$APP/Contents/Resources/extension/preview.html"
cp "$ROOT/extension/preview.css" "$APP/Contents/Resources/extension/preview.css"
mkdir -p "$APP/Contents/Resources/extension/dist"
cp "$ROOT/extension/dist/"*.js "$APP/Contents/Resources/extension/dist/"

if [ "$MODE" != release ]; then
  rm -rf "$APP.dSYM"
  xcrun dsymutil "$APP/Contents/MacOS/hw_gallery" -o "$APP.dSYM"
fi

if [ "$MODE" = release ]; then
  codesign --force --options runtime \
    --entitlements "$ROOT/entitlements.plist" \
    --sign "$HW_GALLERY_CODESIGN_IDENTITY" \
    "$APP"
fi

cp "$APP/Contents/MacOS/hw_gallery" "$ROOT/build/hw_gallery"
printf '[hw_gallery] built %s: %s\n' "$MODE" "${APP#"$ROOT/"}"
