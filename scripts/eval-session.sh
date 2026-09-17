#!/usr/bin/env bash
# Audit a recorded session with an agentic CLI (Claude Code or Codex) that reads this repo.
# Usage: [EVAL_AGENT=claude|codex] ./scripts/eval-session.sh [session-dir]
# The session defaults to the most recent one under .jarvis/.
set -euo pipefail
cd "$(dirname "$0")/.."

SESSION_DIR="${1:-}"
if [[ -z "$SESSION_DIR" ]]; then
  # Name prefixes identify the build and mtimes change on evaluation, so use Activity's timestamp parser.
  SESSION_DIR="$(swift run EvalPrep --latest "$PWD/.jarvis")"
  echo "▶ auditing most recent session: $SESSION_DIR"
fi
[[ -d "$SESSION_DIR" ]] || { echo "not a directory: $SESSION_DIR" >&2; exit 1; }
SESSION_DIR="$(cd "$SESSION_DIR" && pwd)"   # absolute, so the prompt points the agent unambiguously

AGENT="${EVAL_AGENT:-}"
case "$AGENT" in
  "")       HTML="$(swift run EvalPrep --evaluate "$PWD" "$SESSION_DIR")" ;;
  claude|codex)
            HTML="$(swift run EvalPrep --evaluate "$PWD" "$SESSION_DIR" "$AGENT")" ;;
  *)        echo "unknown EVAL_AGENT: $AGENT (expected 'claude' or 'codex')" >&2; exit 2 ;;
esac
echo "✓ report written to $SESSION_DIR/eval-report.md"
echo "✓ open in a browser: $HTML"
