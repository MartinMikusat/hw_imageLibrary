#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/dev-launch-policy.sh"

assert_policy() {
  expected=$1
  has_launched=$2
  was_frontmost=$3
  actual=$(hw_gallery_dev_launch_policy "$has_launched" "$was_frontmost")
  [ "$actual" = "$expected" ] || {
    printf 'expected launch policy %s, got %s\n' "$expected" "$actual" >&2
    exit 1
  }
}

assert_policy '0 1' 0 0
assert_policy '0 1' 0 1
assert_policy '1 1' 1 1
assert_policy '0 0' 1 0
