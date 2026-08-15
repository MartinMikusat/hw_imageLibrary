#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LOCK_FILE=${HW_GALLERY_DEPENDENCY_LOCK:-"$ROOT/dependencies.lock"}

DEPENDENCIES="hw_odin_ipc_localCommand hw_odin_matchSorter hw_odin_ui_commandPalette hw_odin_ui_flash hw_odin_ui_framework"

repository_path() {
  printf '%s/../%s\n' "$ROOT" "$1"
}

check_dependencies() {
  strict=${1:-}
  if [ ! -f "$LOCK_FILE" ]; then
    echo "[hw_gallery] missing dependency lock: $LOCK_FILE" >&2
    return 1
  fi

  seen=""
  while read -r name expected_url expected_revision extra; do
    case "$name" in
      ""|\#*) continue ;;
    esac
    if [ -n "${extra:-}" ] || [ -z "${expected_url:-}" ] || [ -z "${expected_revision:-}" ]; then
      echo "[hw_gallery] invalid dependency lock entry: $name" >&2
      return 1
    fi
    case " $DEPENDENCIES " in
      *" $name "*)
        case " $seen " in
          *" $name "*) 
            echo "[hw_gallery] duplicate dependency lock entry: $name" >&2
            return 1
            ;;
        esac
        seen="$seen $name"
        ;;
      *)
        echo "[hw_gallery] unknown dependency lock entry: $name" >&2
        return 1
        ;;
    esac

    repository=$(repository_path "$name")
    if ! git -C "$repository" rev-parse --git-dir >/dev/null 2>&1; then
      echo "[hw_gallery] missing dependency checkout: $repository" >&2
      return 1
    fi

    actual_url=$(git -C "$repository" remote get-url origin 2>/dev/null || true)
    if [ "$actual_url" != "$expected_url" ]; then
      echo "[hw_gallery] dependency origin mismatch: $name" >&2
      echo "  expected: $expected_url" >&2
      echo "  actual:   ${actual_url:-<missing>}" >&2
      return 1
    fi

    actual_revision=$(git -C "$repository" rev-parse HEAD)
    if [ "$actual_revision" != "$expected_revision" ]; then
      echo "[hw_gallery] dependency revision mismatch: $name" >&2
      echo "  expected: $expected_revision" >&2
      echo "  actual:   $actual_revision" >&2
      echo "  update the checkout or run './scripts/dependencies.sh update' after validation" >&2
      return 1
    fi

    if [ "$strict" = "--strict" ] && [ -n "$(git -C "$repository" status --porcelain)" ]; then
      echo "[hw_gallery] dependency checkout has uncommitted changes: $name" >&2
      return 1
    fi
  done < "$LOCK_FILE"

  for name in $DEPENDENCIES; do
    case " $seen " in
      *" $name "*) ;;
      *)
        echo "[hw_gallery] dependency lock does not contain all required repositories" >&2
        return 1
        ;;
    esac
  done
}

update_dependencies() {
  temporary=$(mktemp "${TMPDIR:-/tmp}/hw_gallery-dependencies.XXXXXX")
  trap 'rm -f "$temporary"' EXIT HUP INT TERM
  printf '# Sibling repository, origin URL, and tested commit.\n' > "$temporary"
  for name in $DEPENDENCIES; do
    repository=$(repository_path "$name")
    if ! git -C "$repository" rev-parse --git-dir >/dev/null 2>&1; then
      echo "[hw_gallery] missing dependency checkout: $repository" >&2
      return 1
    fi
    url=$(git -C "$repository" remote get-url origin)
    revision=$(git -C "$repository" rev-parse HEAD)
    printf '%s %s %s\n' "$name" "$url" "$revision" >> "$temporary"
  done
  mv "$temporary" "$LOCK_FILE"
  trap - EXIT HUP INT TERM
  echo "[hw_gallery] updated dependencies.lock"
}

case "${1:-check}" in
  check) check_dependencies "${2:-}" ;;
  update) update_dependencies ;;
  *)
    echo "usage: ./scripts/dependencies.sh [check [--strict]|update]" >&2
    exit 2
    ;;
esac
