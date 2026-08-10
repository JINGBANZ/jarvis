#!/usr/bin/env bash
# Repeatable system-audio transcription benchmark. The standard mode uses only fixed synthetic
# playback. Reconnect mode coordinates a human-controlled network interruption; it never changes a
# network interface itself.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

usage() {
  echo "usage:" >&2
  echo "  $0 standard [--repetitions N]" >&2
  echo "  $0 reconnect --confirm-network-interruption" >&2
}

MODE="${1:-}"
if [[ "$MODE" != "standard" && "$MODE" != "reconnect" ]]; then
  usage
  exit 2
fi
shift

REPETITIONS=3
CONFIRMED=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repetitions)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      REPETITIONS="$2"
      shift 2
      ;;
    --confirm-network-interruption)
      CONFIRMED="yes"
      shift
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

if [[ "$MODE" == "reconnect" ]]; then
  if [[ "$CONFIRMED" != "yes" ]]; then
    echo "Reconnect mode requires --confirm-network-interruption." >&2
    echo "It will ask you to disable and restore networking manually for each OpenAI model." >&2
    exit 2
  fi
  echo "This opt-in run makes real OpenAI requests and asks you to interrupt networking."
  read -r -p "Type INTERRUPT to continue: " RESPONSE
  if [[ "$RESPONSE" != "INTERRUPT" ]]; then
    echo "Cancelled."
    exit 1
  fi
fi

BASE="$PWD/.jarvis/transcription-benchmarks"
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

APP_EXIT_STATUS="$RUN_DIR/app-launcher-exit"

wait_for_file() {
  local expected="$1"
  while [[ ! -f "$expected" ]]; do
    if show_failure_if_present; then
      return 1
    fi
    if [[ -f "$RUN_DIR/summary.json" ]]; then
      echo "Reconnect run ended before requesting $(basename "$expected")." >&2
      echo "Inspect $RUN_DIR/summary.json for the recorded failure." >&2
      return 1
    fi
    if [[ -f "$APP_EXIT_STATUS" ]]; then
      echo "Benchmark app exited before requesting $(basename "$expected") " \
        "(launcher status $(sed -n '1p' "$APP_EXIT_STATUS"))." >&2
      return 1
    fi
    sleep 0.2
  done
}

if [[ "$MODE" == "standard" ]]; then
  echo "▶ running fixed system-audio matrix ($REPETITIONS repetitions per arm)"
  open -W -n ./Jarvis.app --args "${COMMON_ARGS[@]}"
else
  COMMON_ARGS+=(--benchmark-network-interruption-confirmed)
  echo "▶ launching opt-in reconnect validation"
  APP_WAITER_PID=""

  abort_run() {
    trap - INT TERM
    touch "$RUN_DIR/abort"
    echo >&2
    echo "Reconnect benchmark aborted. Restore networking manually if it is still disabled." >&2
    if [[ -n "$APP_WAITER_PID" ]]; then
      wait "$APP_WAITER_PID" || true
    fi
    exit 130
  }
  trap abort_run INT TERM

  # `open -W` keeps a waitable launcher alive until the hidden app exits. Its wrapper publishes the
  # exit status atomically so a failed app cannot strand an operator-marker wait. The signal trap
  # writes the app's abort marker, then reaps this waiter so capture cannot outlive the command.
  (
    set +e
    open -W -n ./Jarvis.app --args "${COMMON_ARGS[@]}"
    LAUNCH_STATUS=$?
    set -e
    printf '%s\n' "$LAUNCH_STATUS" > "$APP_EXIT_STATUS.tmp"
    mv "$APP_EXIT_STATUS.tmp" "$APP_EXIT_STATUS"
    exit "$LAUNCH_STATUS"
  ) &
  APP_WAITER_PID=$!

  MODELS=(gpt-4o-transcribe gpt-transcribe gpt-live-transcribe)
  for MODEL in "${MODELS[@]}"; do
    DISABLE_REQUEST="$RUN_DIR/request-disable-network--$MODEL"
    RESTORE_REQUEST="$RUN_DIR/request-restore-network--$MODEL"
    wait_for_file "$DISABLE_REQUEST"
    echo
    echo "[$MODEL] Disable the active network connection manually."
    read -r -p "Press Return only after networking is down: " _
    touch "$RUN_DIR/ack-disable-network--$MODEL"

    wait_for_file "$RESTORE_REQUEST"
    echo "[$MODEL] Restore the network connection manually."
    read -r -p "Press Return only after networking is restored: " _
    touch "$RUN_DIR/ack-restore-network--$MODEL"
  done
  wait "$APP_WAITER_PID"
  APP_WAITER_PID=""
  trap - INT TERM
fi

if show_failure_if_present; then
  exit 1
fi
if [[ ! -f "$RUN_DIR/summary.json" ]]; then
  echo "Benchmark exited without summary.json; inspect $RUN_DIR/jarvis-debug.log" >&2
  exit 1
fi

echo "✅ benchmark summary: $RUN_DIR/summary.json"
