#!/usr/bin/env bash
# Agentic session audit — the exploring auditor that reads the code, not just the wire.
#
# Where the in-app "Evaluate" button sends one Responses API call over the session's wire transcript
# (SessionEvaluator), this runs the audit through an agentic CLI (Claude Code / Codex) whose workspace
# is this repo checkout PLUS the session directory. The auditor then verifies each finding against the
# harness's own code (CoachHistory.swift, CoachDriver.swift, ToolDefs.swift, …) instead of guessing
# from traffic alone — the whole point of issue #71.
#
# It stays a DEV-SIDE workflow on purpose: the sandboxed app never launches a headless agent or hands
# it a key, and the agent authenticates with the developer's own `claude`/`codex` login — Jarvis's
# owner-only API-key file is never touched. Session dirs under .jarvis/ are already owner-only and
# workspace-local, so the agent (running as their owner) has exactly the access it needs.
#
# Usage:
#   ./scripts/eval-session.sh [session-dir]     # defaults to the most recent session under .jarvis/
#
# Requires one of `claude` (Claude Code) or `codex` (Codex CLI) on PATH; override with EVAL_AGENT.
set -euo pipefail
cd "$(dirname "$0")/.."

# Resolve the session directory: an explicit argument, else the most recently modified session dir
# under the workspace-local .jarvis/ (where the app writes per-session logs).
SESSION_DIR="${1:-}"
if [[ -z "$SESSION_DIR" ]]; then
  SESSION_DIR="$(find .jarvis -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
    | xargs -I{} stat -f '%m %N' {} 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  if [[ -z "$SESSION_DIR" ]]; then
    echo "no session directory found under .jarvis/ — pass one explicitly" >&2
    exit 1
  fi
  echo "▶ auditing most recent session: $SESSION_DIR"
fi
[[ -d "$SESSION_DIR" ]] || { echo "not a directory: $SESSION_DIR" >&2; exit 1; }
SESSION_DIR="$(cd "$SESSION_DIR" && pwd)"   # absolute, so the prompt points the agent unambiguously

# Render the compact transcript into the session dir and get the task prompt (reuses Core's rendering
# via the EvalPrep executable — no bash reimplementation of the delta-aware format).
PROMPT="$(swift run EvalPrep "$SESSION_DIR")"

REPORT="$SESSION_DIR/eval-report.md"

# Pick the agentic CLI. Both print their final answer to stdout in headless mode, which is the report.
AGENT="${EVAL_AGENT:-}"
if [[ -z "$AGENT" ]]; then
  if command -v claude >/dev/null 2>&1;   then AGENT="claude"
  elif command -v codex >/dev/null 2>&1;  then AGENT="codex"
  else
    echo "no agentic CLI found — install Claude Code (\`claude\`) or Codex (\`codex\`), or set EVAL_AGENT" >&2
    exit 1
  fi
fi

echo "▶ running $AGENT over the repo + session (this explores the code; give it a minute)…"
# Write to a temp file and mv into place only on success, so a failed run (auth, network,
# interrupt) never truncates a previous report; chmod before the move so the final file is
# never observable at default umask. `--ephemeral` keeps Codex from persisting a rollout copy
# of the session transcript outside the owner-only .jarvis/ dir.
REPORT_TMP="$REPORT.tmp"
trap 'rm -f "$REPORT_TMP"' EXIT
case "$AGENT" in
  claude) claude -p "$PROMPT" > "$REPORT_TMP" ;;
  codex)  codex exec --ephemeral "$PROMPT" > "$REPORT_TMP" ;;
  *)      echo "unknown EVAL_AGENT: $AGENT (expected 'claude' or 'codex')" >&2; exit 2 ;;
esac
chmod 600 "$REPORT_TMP"
mv "$REPORT_TMP" "$REPORT"

# Render the browsable page (with its Copy-as-Markdown button) from what the agent wrote.
HTML="$(swift run EvalPrep --html "$SESSION_DIR")"
echo "✓ report written to $REPORT"
echo "✓ open in a browser: $HTML"
