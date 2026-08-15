#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LOCK_FILE=${HW_GALLERY_DEPENDENCY_LOCK:-"$ROOT/dependencies.lock"}

DEPENDENCIES="hw_odin_ipc_localCommand hw_odin_matchSorter hw_odin_ui_commandPalette hw_odin_ui_flash hw_odin_ui_framework"
ICONOIR_FILES="LICENSE maximize.svg minus.svg settings.svg xmark.svg"

repository_path() {
  printf '%s/../%s\n' "$ROOT" "$1"
}

checksum() {
  shasum -a 256 "$1" | awk '{print $1}'
}

check_iconoir() {
  iconoir_tag=""
  seen_files=""
  file_count=0
  while read -r kind name a b c extra; do
    case "$kind" in
      ""|\#*) continue ;;
      iconoir)
        if [ -n "${extra:-}" ] || [ -z "${name:-}" ] || [ -z "${a:-}" ] || [ -z "${b:-}" ] || [ -z "${c:-}" ]; then
          echo "[hw_gallery] invalid Iconoir lock entry" >&2
          return 1
        fi
        [ -z "$iconoir_tag" ] || {
          echo "[hw_gallery] duplicate Iconoir lock entry" >&2
          return 1
        }
        iconoir_tag=$name
        ;;
      iconoir-file)
        if [ -n "${a:-}" ] && [ -z "${b:-}" ]; then
          :
        else
          echo "[hw_gallery] invalid Iconoir file entry: ${name:-<missing>}" >&2
          return 1
        fi
        case " $seen_files " in
          *" $name "*)
            echo "[hw_gallery] duplicate Iconoir file entry: $name" >&2
            return 1
            ;;
        esac
        case " $ICONOIR_FILES " in
          *" $name "*) ;;
          *)
            echo "[hw_gallery] unknown Iconoir file entry: $name" >&2
            return 1
            ;;
        esac
        file="$ROOT/resources/icons/iconoir/$name"
        if [ ! -f "$file" ]; then
          echo "[hw_gallery] missing bundled Iconoir file: $name" >&2
          return 1
        fi
        actual=$(checksum "$file")
        if [ "$actual" != "$a" ]; then
          echo "[hw_gallery] Iconoir checksum mismatch: $name" >&2
          return 1
        fi
        seen_files="$seen_files $name"
        file_count=$((file_count + 1))
        ;;
    esac
  done < "$LOCK_FILE"
  if [ -z "$iconoir_tag" ]; then
    echo "[hw_gallery] dependency lock does not contain Iconoir" >&2
    return 1
  fi
  if [ "$file_count" -ne 5 ]; then
    echo "[hw_gallery] dependency lock must contain five Iconoir files" >&2
    return 1
  fi
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
      ""|\#*|iconoir|iconoir-file) continue ;;
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
  check_iconoir
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
  awk '
    $1 == "iconoir" || $1 == "iconoir-file" || $0 ~ /^# Bundled Iconoir/ {print}
  ' "$LOCK_FILE" >> "$temporary"
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
