#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOCAL_COMMAND_ROOT="$ROOT/../hw_odin_ipc_localCommand"
MATCH_SORTER_ROOT="$ROOT/../hw_odin_matchSorter"
COMMAND_PALETTE_ROOT="$ROOT/../hw_odin_ui_commandPalette"
FLASH_ROOT="$ROOT/../hw_odin_ui_flash"
UI_FRAMEWORK_ROOT="$ROOT/../hw_odin_ui_framework"
IMAGE_SIMILARITY_ROOT="$ROOT/../hw_odin_imageSimilarity"

hw-odin test "$ROOT/src" \
  -collection:local_command="$LOCAL_COMMAND_ROOT" \
  -collection:match_sorter="$MATCH_SORTER_ROOT" \
  -collection:command_palette="$COMMAND_PALETTE_ROOT" \
  -collection:flash="$FLASH_ROOT" \
  -collection:ui_framework="$UI_FRAMEWORK_ROOT" \
  -collection:image_similarity="$IMAGE_SIMILARITY_ROOT"
npm test --prefix "$ROOT/extension"
"$ROOT/scripts/dev-launch-policy-test.sh"
mkdir -p "$ROOT/build/test"
hw-odin build "$ROOT/src" \
  -out:"$ROOT/build/test/hw_gallery" \
  -collection:local_command="$LOCAL_COMMAND_ROOT" \
  -collection:match_sorter="$MATCH_SORTER_ROOT" \
  -collection:command_palette="$COMMAND_PALETTE_ROOT" \
  -collection:flash="$FLASH_ROOT" \
  -collection:ui_framework="$UI_FRAMEWORK_ROOT" \
  -collection:image_similarity="$IMAGE_SIMILARITY_ROOT"
node "$ROOT/scripts/native-host-integration-test.mjs" \
  "$ROOT/build/test/hw_gallery"
git -C "$ROOT" diff --check
