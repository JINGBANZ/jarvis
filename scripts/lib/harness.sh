#!/usr/bin/env bash

create_run_directory() (
  umask 077
  local base="$PWD/.jarvis/$1" directory
  if [[ -L "$PWD/.jarvis" || -L "$base" ]]; then
    echo "Refusing a symlinked harness directory: $base" >&2
    exit 1
  fi
  mkdir -p "$base" || exit "$?"
  chmod 700 "$PWD/.jarvis" "$base" || exit "$?"
  directory="$base/$(date '+%Y-%m-%d_%H-%M-%S')-$$"
  mkdir -m 700 "$directory" || exit "$?"
  printf '%s\n' "$directory"
)

wait_for_file() {
  local file="$1" timeout="$2" label="$3" interval="${4:-0.2}"
  local deadline=$((SECONDS + timeout))
  while [[ ! -f "$file" ]]; do
    if (( SECONDS >= deadline )); then
      echo "$label timed out: $(dirname "$file")" >&2
      return 1
    fi
    sleep "$interval"
  done
}
