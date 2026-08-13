#!/usr/bin/env bash
# Repeatable system-audio transcription benchmark. Both modes use only fixed synthetic playback.
# Reconnect mode interrupts only Jarvis's transcription WebSocket; host networking stays online.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

usage() {
  echo "usage:" >&2
  echo "  $0 standard [--repetitions N]" >&2
  echo "  $0 reconnect" >&2
}

MODE="${1:-}"
if [[ "$MODE" != "standard" && "$MODE" != "reconnect" ]]; then
  usage
  exit 2
fi
shift

REPETITIONS=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repetitions)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      REPETITIONS="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if ! [[ "$REPETITIONS" =~ ^[0-9]+$ ]] || (( REPETITIONS < 3 )); then
  echo "--repetitions must be an integer of at least 3" >&2
  exit 2
fi

BASE="$PWD/.jarvis/transcription-benchmarks"
APP="Jarvis Dev.app"
RUN_ID="$(date '+%Y-%m-%d_%H-%M-%S')-$$"
RUN_DIR="$BASE/$RUN_ID"
if [[ -L "$PWD/.jarvis" || -L "$BASE" ]]; then
  echo "Refusing a symlinked benchmark log directory; use the workspace-local .jarvis tree." >&2
  exit 1
fi
mkdir -p "$BASE"
chmod 700 "$PWD/.jarvis" "$BASE"
if [[ -e "$RUN_DIR" || -L "$RUN_DIR" ]]; then
  echo "Refusing to reuse an existing benchmark run directory: $RUN_DIR" >&2
  exit 1
fi
mkdir "$RUN_DIR"
chmod 700 "$RUN_DIR"

echo "▶ building the signed benchmark app"
./scripts/build-app.sh debug

COMMON_ARGS=(
  --transcription-benchmark
  --benchmark-mode "$MODE"
  --benchmark-output-dir "$RUN_DIR"
  --benchmark-repo-dir "$PWD"
  --benchmark-repetitions "$REPETITIONS"
)

show_failure_if_present() {
  if [[ -f "$RUN_DIR/benchmark-error.json" ]]; then
    echo "Benchmark failed:" >&2
    sed -n '1,120p' "$RUN_DIR/benchmark-error.json" >&2
    return 0
  fi
  return 1
}

if [[ "$MODE" == "standard" ]]; then
  echo "▶ running fixed system-audio matrix ($REPETITIONS repetitions per arm)"
else
  echo "▶ running scoped reconnect validation (host networking remains online)"
fi

APP_WAITER_PID=""

abort_run() {
  trap - INT TERM
  touch "$RUN_DIR/abort"
  echo >&2
  echo "Transcription benchmark aborted." >&2
  if [[ -n "$APP_WAITER_PID" ]]; then
    wait "$APP_WAITER_PID" || true
  fi
  exit 130
}
trap abort_run INT TERM

# `open -W` keeps a waitable launcher alive until the hidden app exits. Both modes observe the abort
# marker; the signal trap then reaps this waiter so capture cannot outlive the command.
open -W -n "./$APP" --args "${COMMON_ARGS[@]}" &
APP_WAITER_PID=$!
wait "$APP_WAITER_PID"
APP_WAITER_PID=""
trap - INT TERM

if show_failure_if_present; then
  exit 1
fi
if [[ ! -f "$RUN_DIR/benchmark-finished" ]]; then
  echo "Benchmark exited without its successful-completion marker; inspect " \
    "$RUN_DIR/jarvis-debug.log" >&2
  exit 1
fi
if [[ ! -f "$RUN_DIR/summary.json" ]]; then
  echo "Benchmark exited without summary.json; inspect $RUN_DIR/jarvis-debug.log" >&2
  exit 1
fi

echo "✅ benchmark summary: $RUN_DIR/summary.json"
