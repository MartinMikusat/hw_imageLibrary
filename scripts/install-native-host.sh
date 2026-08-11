#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOST_NAME=com.halwayland.hw_imagelibrary
HOST_TEMPLATE="$ROOT/native-host/$HOST_NAME.json"
HOST_EXECUTABLE=${1:-"$ROOT/build/hw_imageLibrary.app/Contents/MacOS/hw_imageLibrary-native-host"}

case "$HOST_EXECUTABLE" in
  /*) ;;
  *)
    echo "native host executable must be an absolute path" >&2
    exit 2
    ;;
esac
case "$HOST_EXECUTABLE" in
  *'"'*|*'\'*)
    echo "native host executable path contains unsupported JSON characters" >&2
    exit 2
    ;;
esac
if [ ! -x "$HOST_EXECUTABLE" ]; then
  echo "native host executable is missing: $HOST_EXECUTABLE" >&2
  exit 1
fi

install_manifest() {
  directory=$1
  mkdir -p "$directory"
  temporary="$directory/.$HOST_NAME.$$.tmp"
  sed "s|__NATIVE_HOST_PATH__|$HOST_EXECUTABLE|g" "$HOST_TEMPLATE" > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$directory/$HOST_NAME.json"
}

install_manifest "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
install_manifest "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
printf 'installed %s for Chrome and Brave\n' "$HOST_NAME"
