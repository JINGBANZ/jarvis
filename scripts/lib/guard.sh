#!/usr/bin/env bash

guard_scan() {
  local status=0
  /usr/bin/grep "$@" || status=$?
  if (( status > 1 )); then
    echo "Source guard scan failed; refusing to pass without a complete scan." >&2
    return "$status"
  fi
}

guard_forbid() {
  local message="$1" matches
  shift
  matches="$(guard_scan "$@")" || exit "$?"
  if [[ -n "$matches" ]]; then
    echo "$message" >&2
    echo "$matches" >&2
    exit 1
  fi
}
