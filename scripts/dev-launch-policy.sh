#!/bin/sh

hw_gallery_dev_launch_policy() {
  has_launched=$1
  was_frontmost=$2
  if [ "$has_launched" -eq 0 ]; then
    printf '%s\n' '0 1'
  elif [ "$was_frontmost" -eq 1 ]; then
    printf '%s\n' '1 1'
  else
    printf '%s\n' '0 0'
  fi
}
