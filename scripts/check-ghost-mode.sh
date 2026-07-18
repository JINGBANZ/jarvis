#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Any AppKit call that can reveal Jarvis must be an explicit, reviewed exception. Keeping the marker
# on the exact call site makes a newly introduced alert/window/browser/sound fail the normal gate
# instead of relying on a future manual audit to notice it.
pattern='NSAlert\(|(NSApp|NSApplication\.shared)\.(activate|setActivationPolicy)|makeKeyAndOrderFront|\.makeKey\(|orderFrontRegardless|\.orderFront\(|beginSheet\(|NSWorkspace\.shared\.open|NSSound|AudioServicesPlaySystemSound|requestUserAttention|UNUserNotification|NSUserNotification|\.runModal\('

if violations="$(rg -n "$pattern" Sources/JarvisApp Sources/JarvisOverlay \
    | rg -v 'ghost-mode-allowed')"; then
    echo "Ghost-mode presentation APIs require an inline ghost-mode-allowed exception:" >&2
    echo "$violations" >&2
    exit 1
fi

echo "Ghost-mode presentation API guard passed."
