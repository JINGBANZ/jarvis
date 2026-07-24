import Foundation

/// The session audit hands a complete session to an agentic CLI (Claude Code / Codex) whose workspace
/// is the repo checkout **plus** the session directory. The auditor can read the harness's code, the
/// compact wire transcript, the complete raw traffic, the complete Activity log, and screenshots,
/// then verifies each finding against the actual implementation instead of guessing from one input.
///
/// This type is the pure, testable half: it renders the traffic to a compact, delta-aware transcript,
/// writes that derived view beside the untouched source logs as an owner-only file, and assembles the
/// task prompt that points the CLI at every input. The OS-bound half — actually spawning
/// `claude -p` / `codex exec` — lives in `scripts/eval-session.sh`.
public enum AgenticEvaluation {
    /// The rendered transcript is written here (owner-only) so the agent reads a file, not a giant
    /// argv. Sits beside `brain-traffic.jsonl` and `eval-report.md` in the session dir.
    public static let transcriptFilename = "eval-transcript.txt"

    /// The audit report the agent writes back. Activity can open it after the dev-side agentic run.
    public static let reportFilename = "eval-report.md"

    public enum EvaluationError: LocalizedError, Equatable {
        case noTraffic
        case missingActivityLog

        public var errorDescription: String? {
            switch self {
            case .noTraffic:
                "No brain traffic was recorded for this session — nothing to evaluate."
            case .missingActivityLog:
                "The session's complete Activity log is missing or unreadable."
            }
        }
    }

    /// The report persisted by an earlier agentic audit, if any.
    public static func savedReport(in sessionDir: URL) -> String? {
        let url = sessionDir.appendingPathComponent(reportFilename)
        guard let report = try? String(contentsOf: url, encoding: .utf8), !report.isEmpty
        else { return nil }
        return report
    }

    /// Prepare the agent's workspace for one session and return the task prompt to feed the CLI.
    ///
    /// Renders the session's recorded traffic to the compact transcript, writes it owner-only into the
    /// session directory, and returns the prompt (which embeds the directory's absolute path so the
    /// agent knows where its inputs live). Throws `EvaluationError.noTraffic` when there is nothing
    /// to audit.
    public static func prepare(sessionDir: URL) throws -> String {
        let trafficURL = sessionDir.appendingPathComponent(BrainTrafficLog.filename)
        let jsonl = (try? String(contentsOf: trafficURL, encoding: .utf8)) ?? ""
        let transcript = EvaluationTranscript.render(jsonl: jsonl)
        guard !transcript.isEmpty else { throw EvaluationError.noTraffic }
        let activityURL = sessionDir.appendingPathComponent(ActivityLog.filename)
        guard FileManager.default.isReadableFile(atPath: activityURL.path) else {
            throw EvaluationError.missingActivityLog
        }

        let transcriptURL = sessionDir.appendingPathComponent(transcriptFilename)
        // A failed write must abort: the prompt tells the agent the transcript is its primary
        // input, so silently proceeding would spend a whole agentic run on a missing/stale file.
        guard FileManager.default.createFile(
            atPath: transcriptURL.path,
            contents: Data(transcript.utf8), attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }

        return prompt(sessionDirPath: sessionDir.path)
    }

    /// The task prompt handed to the agentic CLI. It points at the complete session directory and
    /// repo, preserves call-#N citation discipline, and requires every recommendation to be labelled
    /// `[confirmed]` (checked against the code in this checkout) or `[hypothesis]`.
    static func prompt(sessionDirPath: String) -> String {
        """
        You are auditing one session of Jarvis, a proactive macOS coaching assistant: it transcribes \
        the user's (and their interlocutor's) speech, optionally screenshots the user's screen, and an \
        LLM decides each turn to speak a short overlay tip, look at the screen, or stay silent. The \
        session's memory is client-managed: each request is [instructions] + history + new turn, built \
        append-only so the provider's prompt cache keeps hitting; old history is periodically compacted \
        into a summary by a separate "summarizer" client.

        YOUR WORKSPACE is a checkout of the Jarvis source repository. The audited session lives at:
            \(sessionDirPath)
        with these inputs in that directory:
          - `\(transcriptFilename)` — the session's wire-level LLM traffic. It OPENS with a \
        "=== deterministic metrics ===" table computed from the raw traffic (per-call and \
        aggregate input / cache-read / cache-write / output tokens and cost, plus a per-model \
        breakdown). Trust its known numbers and availability labels: `—` means unavailable, not zero, \
        and a `known (N unavailable)` value is partial, not a session total. Quote only what the table \
        supports; never recompute a total by eye. The rest is \
        one block per API call, in order — your PRIMARY narrative input. To keep it compact, content \
        byte-identical to the previous same-tag call is elided and marked "(unchanged)" — those \
        markers are exactly where the prompt cache SHOULD be hitting.
          - `\(BrainTrafficLog.filename)` — the same traffic un-elided. Because the transcript elides \
        byte-identical repeats, ANY cardinal count (stub occurrences, OCR dumps, marker repetitions) \
        MUST be counted here, not from the elided transcript.
          - `\(ActivityLog.filename)` — the COMPLETE sanitized human-facing coaching record: heard \
        speech, manual hints, every brain action, and every fixed stop/degrade notice, with stable \
        event kinds in `k`. Read the file itself in full; it is deliberately NOT filtered, summarized, \
        or copied into `\(transcriptFilename)`. Use it whenever you need the user-visible sequence or \
        lifecycle consequence. Treat `coaching stopped` / `session failed` as a session-level UX \
        failure and distinguish it from a recoverable `listening continues` notice. A single call \
        timeout that stopped the whole session is catastrophic even if the wire-level failure itself \
        looks ordinary.

        Provider records can appear together — read the right fields for each:
          - OpenAI Responses: `response.usage` with `input_tokens`, \
        `input_tokens_details.cached_tokens` (automatic prefix-cache hit), optional \
        `cache_write_tokens`, and `output_tokens`; a truncated run shows `status:"incomplete"`. No \
        per-call dollar cost. OpenAI `input_tokens` includes cached input, so mixed-provider token \
        totals are kept separate.
          - Local CLI (`claude -p`): `response.cli` with `total_cost_usd`, a call-level `usage` \
        carrying Anthropic's `cache_creation_input_tokens` / `cache_read_input_tokens` split, and a \
        `modelUsage` map (per-model usage + cost, including internal sidecar models like a haiku \
        pass). Anthropic caching is BLOCK-level: a fresh, non-persisted `claude -p` turn sends the \
        whole conversation as one block, so it can only cache-hit the reused `--system-prompt` — a \
        small, flat cross-turn cache-read is that serialization (verify against \
        `Sources/JarvisCore/Brain/CLIBrainClient+Invocation.swift`), NOT history rewriting.
          - Codex CLI: the recorded response currently has the reply and exit status but no token, \
        cache, or cost usage. Those cells must stay unavailable; never interpret them as zero.
          - `shot-N.jpg` — the screenshots the model actually saw (base64 was redacted from the traffic).
          - a prior `\(reportFilename)`, if this session was audited before.

        Because you have the repo, DO NOT GUESS how the harness works — read it and verify. Load-bearing \
        files: `Sources/JarvisCore/Coach/CoachHistory.swift` (client-managed memory: append-only \
        prefix, screenshot stubbing, compaction), `Sources/JarvisCore/Coach/CoachDriver.swift` (the \
        event loop, the filler substance gate, compaction trigger), `Sources/JarvisCore/Coach/ToolDefs.swift` \
        (tool schemas + the coach prompt), `Sources/JarvisCore/Brain/ReasoningEffort.swift` \
        (`max_output_tokens` is a COMBINED reasoning+output budget — a tight cap recreates the \
        documented `status:"incomplete"` truncation), and `Sources/JarvisCore/Config/Config.swift`. \
        Before recommending a mechanism, grep for it: several (screenshot stubbing, bulky-tool-result \
        compaction, filler gating, prompt_cache_key pinning) already exist.

        Write a markdown report with exactly these sections:

        ## Context engineering
        Inefficiencies in what the harness sends: cache-busting prefix changes (input marked changed \
        that should have been stable), redundant or stale content re-billed every call, oversized \
        instructions or tool schemas relative to their value, history-compaction timing/quality, \
        screenshots kept or stubbed at the wrong time. Be quantitative with the usage numbers, and \
        name the code that produces each behavior.

        ## Issues and errors
        Transport errors, non-2xx responses, truncated runs (status=incomplete), tool-loop anomalies \
        (repeated capture_screen, exhausted loops), and any contradiction between the code/instructions \
        and the model's behavior.

        ## Coaching quality
        Given the transcript deltas the model saw: tips that were wrong, late, redundant, or noisy; \
        silences that should have been tips and vice versa.

        ## Recommendations
        Concrete changes, ordered by expected impact, each tied to evidence above. Prefix EACH with a \
        label:
          - `[confirmed]` — you verified it against the code in this checkout (cite the file/symbol). \
        Use this ONLY when you actually read the relevant code; "confirmed" means confirmed against the \
        implementation, not merely consistent with the traffic.
          - `[hypothesis]` — plausible from the traffic but not (or not yet) checked against the code.

        Cite call numbers (call #N) as evidence throughout. If the data doesn't support a finding, say \
        so rather than speculating. Before finalizing, re-check every number in your draft against the \
        metrics table and against `\(BrainTrafficLog.filename)`, and correct or delete any that \
        disagree. Output ONLY the markdown report — it is saved as `\(reportFilename)` in the session \
        directory (the harness prepends a one-line provenance stamp, so don't add your own).
        """
    }
}
