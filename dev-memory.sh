#!/bin/sh
set -eu

PROFILE=${1:-}
case "$PROFILE" in
  scribble|guard-edges|zombies|guard-malloc) ;;
  *)
    echo "usage: ./dev-memory.sh [scribble|guard-edges|zombies|guard-malloc]" >&2
    exit 2
    ;;
esac

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HW_GALLERY_MEMORY_PROFILE="$PROFILE" exec "$ROOT/dev.sh" debug
