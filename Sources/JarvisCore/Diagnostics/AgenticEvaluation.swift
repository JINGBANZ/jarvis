import Foundation

/// The *agentic* session audit: instead of one Responses API call over the wire transcript
/// (`SessionEvaluator`), this hands the audit to an agentic CLI (Claude Code / Codex) whose workspace
/// is the repo checkout **plus** the session directory. The auditor then reads the harness's own code
/// — `CoachHistory.swift`, `CoachDriver.swift`, `ToolDefs.swift`, `ReasoningEffort.swift` — and
/// verifies each finding against the actual implementation instead of guessing from traffic alone.
///
/// This type is the pure, testable half: it renders the session's traffic to the same compact,
/// delta-aware transcript `SessionEvaluator` produces (kept deliberately — it's the right input
/// format regardless of who consumes it), writes it beside the traffic as an owner-only file, and
/// assembles the task prompt that points the CLI at the workspace. The OS-bound half — actually
/// spawning `claude -p` / `codex exec` — lives in `scripts/eval-session.sh` (a dev-side workflow, so
/// the sandboxed app never has to launch a headless agent or hand it a key).
///
/// The single-call `SessionEvaluator` stays as the in-app "Evaluate" button: cheap, one round trip,
/// and the fallback when no agentic CLI is installed.
public enum AgenticEvaluation {
    /// The rendered transcript is written here (owner-only) so the agent reads a file, not a giant
    /// argv. Sits beside `brain-traffic.jsonl` and `eval-report.md` in the session dir.
    public static let transcriptFilename = "eval-transcript.txt"

    /// The audit report the agent writes back — same name as the single-call path so the in-app
    /// "Show report" reuse and the viewer both find it regardless of which evaluator produced it.
    public static let reportFilename = SessionEvaluator.reportFilename

    /// Prepare the agent's workspace for one session and return the task prompt to feed the CLI.
    ///
    /// Renders the session's recorded traffic to the compact transcript, writes it owner-only into the
    /// session directory, and returns the prompt (which embeds the directory's absolute path so the
    /// agent knows where its inputs live). Throws `EvaluationError.noTraffic` when there is nothing to
    /// audit, matching `SessionEvaluator`.
    public static func prepare(sessionDir: URL) throws -> String {
        let trafficURL = sessionDir.appendingPathComponent(BrainTrafficLog.filename)
        let jsonl = (try? String(contentsOf: trafficURL, encoding: .utf8)) ?? ""
        let transcript = SessionEvaluator.renderTranscript(jsonl: jsonl)
        guard !transcript.isEmpty else { throw SessionEvaluator.EvaluationError.noTraffic }

        let transcriptURL = sessionDir.appendingPathComponent(transcriptFilename)
        _ = FileManager.default.createFile(
            atPath: transcriptURL.path,
            contents: Data(transcript.utf8), attributes: [.posixPermissions: 0o600])

        return prompt(sessionDirPath: sessionDir.path)
    }

    /// The task prompt handed to the agentic CLI. Reuses `SessionEvaluator`'s report skeleton and its
    /// call-#N citation discipline, but adds the two things the wire-only auditor could never do:
    /// point at the session directory + repo as a workspace, and require every recommendation to be
    /// labelled `[confirmed]` (checked against the code in this checkout) or `[hypothesis]`.
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
          - `\(transcriptFilename)` — the session's wire-level LLM traffic rendered one block per API \
        call, in order. This is your PRIMARY input. To keep it compact, content byte-identical to the \
        previous same-tag call is elided and marked "(unchanged)" — those markers are exactly where \
        the prompt cache SHOULD be hitting. Each response block includes the raw usage object \
        (`input_tokens_details.cached_tokens` vs `input_tokens` is the per-call cache hit rate).
          - `\(BrainTrafficLog.filename)` — the same traffic un-elided, if you need to inspect a full body.
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
        so rather than speculating. Output ONLY the markdown report — it is saved verbatim as \
        `\(reportFilename)` in the session directory.
        """
    }
}
