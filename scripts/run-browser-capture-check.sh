#!/usr/bin/env bash
# Explicit local Chrome capture check. No audio, providers, or automated browser interaction.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
if (( $# > 1 )); then
  echo "usage: $0 [expectation.json]" >&2
  exit 2
fi
EXPECTATION="${1:-Tests/JarvisLiveTests/Fixtures/browser-capture.json}"
if [[ ! -f "$EXPECTATION" ]]; then
  echo "Missing expectation JSON: $EXPECTATION" >&2
  exit 2
fi
EXPECTATION="$(cd "$(dirname "$EXPECTATION")" && pwd -P)/$(basename "$EXPECTATION")"
APP="$PWD/Jarvis Dev.app"
if [[ ! -d "$APP" ]]; then
  echo "Build first with ./scripts/build-app.sh debug." >&2
  exit 2
fi
if /usr/bin/pgrep -f '/Jarvis (Dev|Code with AI)[.]app/Contents/MacOS/JarvisApp' >/dev/null; then
  echo "Quit Jarvis Dev and the Code with AI preview before this check." >&2
  exit 2
fi
# A linked worktree may be temporary. Always keep captured data in the durable workspace's .jarvis.
COMMON="$(git rev-parse --git-common-dir)"
WORKSPACE="$(cd "$COMMON/.." && pwd -P)"
case "$WORKSPACE" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*)
    echo "Capture checks require a durable workspace outside /tmp." >&2; exit 2 ;;
esac
BASE="$WORKSPACE/.jarvis/live-e2e"
if [[ -L "$WORKSPACE/.jarvis" || -L "$BASE" ]]; then
  echo "Refusing a symlinked capture directory." >&2
  exit 2
fi
mkdir -p "$BASE"
chmod 700 "$WORKSPACE/.jarvis" "$BASE"
RUN="$(mktemp -d "$BASE/chrome-$(date '+%Y-%m-%d_%H-%M-%S')-XXXXXX")"
OUTPUT="$RUN/Chrome"
mkdir "$OUTPUT"
cp "$EXPECTATION" "$OUTPUT/scenario.json"
echo "Bring the authorized fixture forward in Chrome now. Capture begins in 5 seconds."
echo "Default fixture: $PWD/Tests/JarvisLiveTests/Fixtures/browser-capture.html"
sleep 5
/usr/bin/open -g -n -W "$APP" --args --live-e2e --browser-capture-check \
  --live-e2e-scenario "$OUTPUT/scenario.json" \
  --live-e2e-output-dir "$OUTPUT" \
  --live-e2e-repo-dir "$WORKSPACE" \
  --live-e2e-fixtures-dir "$PWD/Tests/JarvisLiveTests/Fixtures" &
OPENER=$!
# Limit the explicit check, including a LaunchServices or capture hang. The app is a separate
# process; stopping open alone would leave it alive. No dev process existed at the preflight.
cleanup() {
  if kill -0 "$OPENER" 2>/dev/null; then
    touch "$OUTPUT/abort"
    # Let the app cancel its owned screenshot helper and prove JPEG cleanup before terminating.
    for _ in {1..25}; do
      kill -0 "$OPENER" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$OPENER" 2>/dev/null; then
      echo "Capture app did not acknowledge cancellation; inspect $OUTPUT before another run." >&2
      kill "$OPENER" 2>/dev/null || true
      # Do not kill the app before its helper cleanup completes. Its independent deadline still
      # cancels capture; a failed cleanup must remain visible rather than claiming a clean stop.
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
for _ in {1..150}; do
  kill -0 "$OPENER" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$OPENER" 2>/dev/null; then
  echo "CHROME fail: capture did not finish within 30 seconds ($OUTPUT)." >&2
  exit 1
fi
wait "$OPENER"
if [[ ! -f "$OUTPUT/capture-check-finished" || ! -s "$OUTPUT/capture-check.txt" ]]; then
  echo "CHROME fail: capture completion evidence is missing ($OUTPUT)." >&2
  exit 1
fi
cat "$OUTPUT/capture-check.txt"
echo "Result: $OUTPUT/capture-check.txt"
if grep -qx 'CHROME pass' "$OUTPUT/capture-check.txt"; then exit 0; fi
if grep -qx 'CHROME blocked' "$OUTPUT/capture-check.txt"; then exit 2; fi
exit 1
