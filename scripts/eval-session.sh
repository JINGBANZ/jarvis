#!/usr/bin/env bash
# Agentic session audit — the exploring auditor that reads the code, not just the wire.
#
# The sole evaluator runs through an agentic CLI (Claude Code / Codex) whose workspace is this repo
# checkout PLUS the complete session directory. The auditor reads the full Activity log and raw
# traffic whenever useful, then verifies each finding against the harness's own code
# (Prompts/, CoachHistory.swift, CoachDriver.swift, ToolDefs.swift, …) instead of guessing
# from a reduced prompt.
#
# The script and Activity's Evaluate button both call the same Foundation-only evaluator. The agent
# authenticates with the user's existing `claude`/`codex` login — Jarvis's owner-only API-key file is
# never touched. Session dirs under .jarvis/ are already owner-only and workspace-local, so the agent
# (running as their owner) has exactly the access it needs.
#
# Usage:
#   ./scripts/eval-session.sh [session-dir]     # defaults to the most recent session under .jarvis/
#
# Requires one of `claude` (Claude Code) or `codex` (Codex CLI) on a stable PATH entry or in a
# standard user/system install directory; override the provider choice with EVAL_AGENT.
set -euo pipefail
cd "$(dirname "$0")/.."

# Resolve the session directory: an explicit argument, else the most recently modified session dir
# under the workspace-local .jarvis/ (where the app writes per-session logs).
SESSION_DIR="${1:-}"
if [[ -z "$SESSION_DIR" ]]; then
  # Newest session by *name*: ids are sortable timestamps (2026-06-16_10-00-00_xxxx), and the
  # glob is lexicographic, so the last match is the latest session. Mtime would lie here — merely
  # re-auditing an old session (or regenerating its HTML) bumps its directory mtime.
  for d in .jarvis/*/; do
    [[ -d "$d" ]] && SESSION_DIR="$d"
  done
  if [[ -z "$SESSION_DIR" ]]; then
    echo "no session directory found under .jarvis/ — pass one explicitly" >&2
    exit 1
  fi
  echo "▶ auditing most recent session: $SESSION_DIR"
fi
[[ -d "$SESSION_DIR" ]] || { echo "not a directory: $SESSION_DIR" >&2; exit 1; }
SESSION_DIR="$(cd "$SESSION_DIR" && pwd)"   # absolute, so the prompt points the agent unambiguously

# EvalPrep calls the same Foundation-only AgenticEvaluator as Activity's Evaluate button, keeping
# CLI discovery, read-only/stateless arguments, report stamping, and failure behavior in one place.
AGENT="${EVAL_AGENT:-}"
case "$AGENT" in
  "")       HTML="$(swift run EvalPrep --evaluate "$PWD" "$SESSION_DIR")" ;;
  claude|codex)
            HTML="$(swift run EvalPrep --evaluate "$PWD" "$SESSION_DIR" "$AGENT")" ;;
  *)        echo "unknown EVAL_AGENT: $AGENT (expected 'claude' or 'codex')" >&2; exit 2 ;;
esac
echo "✓ report written to $SESSION_DIR/eval-report.md"
echo "✓ open in a browser: $HTML"
