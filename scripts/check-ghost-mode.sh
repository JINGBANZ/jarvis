#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Any AppKit call that can reveal Jarvis must be an explicit, reviewed exception. Keeping the marker
# on the exact call site makes a newly introduced alert/window/browser/sound fail the normal gate
# instead of relying on a future manual audit to notice it.
pattern='NSAlert\(|(NSApp|NSApplication\.shared)\.(activate|setActivationPolicy)|makeKeyAndOrderFront|\.makeKey\(|orderFrontRegardless|\.orderFront\(|beginSheet\(|NSWorkspace\.shared\.open|NSSound|AudioServicesPlaySystemSound|requestUserAttention|UNUserNotification|NSUserNotification|\.runModal\('

scan_status=0
matches="$(/usr/bin/grep -RInE "$pattern" Sources/JarvisApp Sources/JarvisOverlay)" || scan_status=$?
if [ "$scan_status" -gt 1 ]; then
    echo "Ghost-mode presentation API scan failed; refusing to pass without a complete scan." >&2
    exit "$scan_status"
fi

filter_status=0
violations="$(printf '%s' "$matches" | /usr/bin/grep -v 'ghost-mode-allowed')" || filter_status=$?
if [ "$filter_status" -gt 1 ]; then
    echo "Ghost-mode presentation API exception filtering failed; refusing to pass." >&2
    exit "$filter_status"
fi
if [ -n "$violations" ]; then
    echo "Ghost-mode presentation APIs require an inline ghost-mode-allowed exception:" >&2
    echo "$violations" >&2
    exit 1
fi

echo "Ghost-mode presentation API guard passed."
