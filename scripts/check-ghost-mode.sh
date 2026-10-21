#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/guard.sh

# Any AppKit call that can reveal Jarvis needs a reviewed exception marker on the same line.
pattern='NSAlert\(|(NSApp|NSApplication\.shared)\.(activate|setActivationPolicy)|makeKeyAndOrderFront|\.makeKey\(|orderFrontRegardless|\.orderFront\(|beginSheet\(|\.show\(relativeTo:|NSWorkspace\.shared\.open|NSSound|AudioServicesPlaySystemSound|requestUserAttention|UNUserNotification|NSUserNotification|\.runModal\(|\.popUp\('

matches="$(guard_scan -RInE "$pattern" Sources/JarvisApp Sources/JarvisOverlay Sources/JarvisScreenCapture)"
violations="$(printf '%s' "$matches" | guard_scan -v 'ghost-mode-allowed')"
if [ -n "$violations" ]; then
    echo "Ghost-mode presentation APIs require an inline ghost-mode-allowed exception:" >&2
    echo "$violations" >&2
    exit 1
fi

# Native tooltips have separate AppKit windows outside the protected parent window.
guard_forbid "Settings/Activity help must stay inline or use accessibility help, outside native tooltip windows:" \
    -RInE '\.toolTip[[:space:]]*=|^[[:space:]]*toolTip[[:space:]]*=|(^|[^[:alnum:]_])(setToolTip|addToolTip)[[:space:]]*\(' \
    Sources/JarvisApp/Settings Sources/JarvisApp/Viewer

echo "Ghost-mode presentation API guard passed."
