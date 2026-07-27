#!/usr/bin/env bash
# Run one bounded evidence-dependent coaching turn through prompt JSON and private MCP.
set -euo pipefail
cd "$(dirname "$0")/.."

provider="${1:-}"
if [[ "$provider" != "claude" && "$provider" != "codex" ]]; then
  echo "usage: $0 claude|codex" >&2
  exit 2
fi

swift build --product ActionTransportComparison
swift build --product JarvisMCPServer
bin_dir="$(swift build --show-bin-path)"
session_dir="$PWD/.jarvis/action-comparison-$(date +%Y%m%d-%H%M%S)-$provider"
mkdir -p "$session_dir"
chmod 700 "$session_dir"

"$bin_dir/ActionTransportComparison" \
  --provider "$provider" \
  --server "$bin_dir/JarvisMCPServer" \
  --session-dir "$session_dir"
