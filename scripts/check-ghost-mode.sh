#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Any AppKit call that can reveal Jarvis needs a reviewed exception marker on the same line.
pattern='NSAlert\(|(NSApp|NSApplication\.shared)\.(activate|setActivationPolicy)|makeKeyAndOrderFront|\.makeKey\(|orderFrontRegardless|\.orderFront\(|beginSheet\(|\.show\(relativeTo:|NSWorkspace\.shared\.open|NSSound|AudioServicesPlaySystemSound|requestUserAttention|UNUserNotification|NSUserNotification|\.runModal\(|\.popUp\('

scan_status=0
matches="$(/usr/bin/grep -RInE "$pattern" Sources/JarvisApp Sources/JarvisOverlay Sources/JarvisScreenCapture)" || scan_status=$?
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

# Native tooltips have separate AppKit windows outside the protected parent window.
tooltip_status=0
tooltips="$(/usr/bin/grep -RInE '\.toolTip[[:space:]]*=|^[[:space:]]*toolTip[[:space:]]*=' \
    Sources/JarvisApp/Settings Sources/JarvisApp/Viewer)" || tooltip_status=$?
if [ "$tooltip_status" -gt 1 ]; then exit "$tooltip_status"; fi
if [ -n "$tooltips" ]; then
    echo "Settings/Activity help must stay inline or use accessibility help, outside native tooltip windows:" >&2
    echo "$tooltips" >&2
    exit 1
fi

echo "Ghost-mode presentation API guard passed."
