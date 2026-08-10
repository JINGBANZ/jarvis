import Foundation

extension JarvisPrompts {
    enum Evaluation {
        static func sessionAudit(
            sessionDirectoryPath: String,
            transcriptFilename: String,
            trafficFilename: String,
            attemptsFilename: String,
            healthFilename: String,
            activityFilename: String,
            reportFilename: String
        ) -> String {
            """
            You are auditing one session of Jarvis, a proactive macOS coaching assistant: it transcribes \
            the user's (and their interlocutor's) speech, optionally screenshots the user's screen, and an \
            LLM decides each turn to speak a short overlay tip, look at the screen, or stay silent. The \
            session's memory is client-managed: each request is [instructions] + history + new turn, built \
            append-only so the provider's prompt cache keeps hitting; old history is periodically compacted \
            into a summary by a separate "summarizer" client.

            YOUR WORKSPACE is a checkout of the Jarvis source repository. The audited session lives at:
                \(sessionDirectoryPath)
            with these inputs in that directory:
              - `\(transcriptFilename)` — the compact evaluation view. It OPENS with the \
            `=== deterministic metrics ===` usage/cost table followed by deterministic \
            transcription/trigger-quality counts. Trust their \
            known numbers and availability labels: `—` means unavailable, not zero, and a \
            `known (N unavailable)` value is partial, not a session total. A malformed-record warning \
            likewise makes the affected totals partial. CLI `pre_request_failure` records describe setup \
            failures before inference and are NOT provider calls or telemetry samples. Quote only what these sections \
            support; never recompute a total by eye. The rest is \
            one block per traffic record, in order — provider calls are labeled `call`, while malformed \
            and pre-request evidence is labeled `record`. This is your PRIMARY narrative input. To keep it compact, content \
            byte-identical to the previous same-tag call is elided and marked "(unchanged)"; a growing \
            single CLI text item also elides its exact common prefix with an explicit marker. Those markers \
            are exactly where the prompt cache SHOULD be hitting. Coach call headers name the trigger and \
            initial-vs-screenshot-continuation phase when provenance was recorded.
              - `\(trafficFilename)` — the same traffic un-elided. Because the transcript elides \
            byte-identical repeats, ANY cardinal count (stub occurrences, OCR dumps, marker repetitions) \
            MUST be counted here, not from the elided transcript.
              - `\(attemptsFilename)` — coaching-attempt provenance: trigger vs pending-work wake, \
            source trigger, indexed finalized transcript lines and their runtime filler classification, and \
            actual `brain_facing` request inclusion, plus terminal action. Classification and inclusion are \
            separate evidence: do not recompute one from the other. It may be absent for sessions recorded before provenance shipped; then the \
            corresponding values are unavailable and MUST NOT be inferred from prose logs. Use the matching \
            attempt id on each coach traffic call to attribute causality. A line's presence in accumulated \
            history does not prove that it triggered the call.
              - `\(healthFilename)` — versioned session-audit completion and loss evidence. If the \
            deterministic tables label the audit partial, every audit-derived count is only a known \
            lower bound; never report it as an exact session total. Historical sessions without this file \
            remain subject to the availability labels in the compact transcript.
              - `\(activityFilename)` — the COMPLETE sanitized human-facing coaching record: heard \
            speech, manual hints, every brain action, and every fixed stop/degrade notice, with stable \
            event kinds in `k`. Read the file itself in full; it is deliberately NOT filtered, summarized, \
            or copied into `\(transcriptFilename)`. Use it whenever you need the user-visible sequence or \
            lifecycle consequence. Treat `session ended by error` as a session-level UX failure, but not \
            an end caused by the user, app quit, or a new session; distinguish all of them from a \
            recoverable `listening continues` notice. A single call \
            timeout that stopped the whole session is catastrophic even if the wire-level failure itself \
            looks ordinary.

            Provider records can appear together — read the right fields for each:
              - OpenAI Responses: `response.usage` with `input_tokens`, \
            `input_tokens_details.cached_tokens` (automatic prefix-cache hit), optional \
            `cache_write_tokens`, and `output_tokens`; a truncated run shows `status:"incomplete"`. No \
            per-call dollar cost. OpenAI `input_tokens` includes cached input, so mixed-provider token \
            totals are kept separate.
              - Claude Code warm query: `response.cli` with `total_cost_usd`, a call-level `usage` \
            carrying Anthropic's `cache_creation_input_tokens` / `cache_read_input_tokens` split, and a \
            `modelUsage` map (per-model usage + cost, including internal sidecar models like a haiku \
            pass). One coaching attempt leases one preinitialized query; a capture follow-up sends only \
            incremental input over that same query. Verify the turn boundary in \
            `Sources/JarvisCore/Brain/Adapters/LocalAgent/ClaudeCode/ClaudeCodeRuntime.swift`.
              - Codex app-server: `response.runtime` carries completed-turn metadata but currently no \
            token, cache, or cost usage. Those cells must stay unavailable; never interpret them as zero. \
            One coaching attempt owns one fresh ephemeral thread and sends capture follow-ups \
            incrementally; verify `CodexAppServerRuntime.swift`.
              - `shot-N.jpg` — the screenshots the model actually saw (base64 was redacted from the traffic).
              - a prior `\(reportFilename)`, if this session was audited before.

            Because you have the repo, DO NOT GUESS how the harness works — read it and verify. Load-bearing \
            sources: `Sources/JarvisCore/Prompts/` (all predefined model-facing prompt copy, split by \
            domain), `Sources/JarvisCore/Coach/ToolDefs.swift` (tool schemas), \
            `Sources/JarvisCore/Coach/CoachHistory.swift` (client-managed memory: append-only prefix, \
            screenshot stubbing, compaction), `Sources/JarvisCore/Coach/CoachDriver.swift` (the event loop, \
            the filler substance gate, trigger provenance, compaction trigger), \
            `Sources/JarvisCore/Diagnostics/CoachingAttemptAuditEvent.swift` and \
            `TriggerQualityMetrics.swift` (the persisted provenance schema and deterministic counts), \
            `Sources/JarvisCore/Brain/ReasoningEffort.swift` (`max_output_tokens` is a COMBINED \
            reasoning+output budget — a tight cap recreates the documented `status:"incomplete"` \
            truncation), and `Sources/JarvisCore/Config/Config.swift`. Before recommending a mechanism, \
            grep for it: several (screenshot stubbing, bulky-tool-result compaction, filler gating, \
            prompt_cache_key pinning) already exist.

            Write a markdown report with exactly these sections:

            ## Transcription and trigger quality
            Report the deterministic heard/filler/skip/call/continuation/terminal counts first. Distinguish \
            filler present in accumulated history from filler that formed the brain-facing delta for a call. \
            `stay_silent` is a model decision after a call, NEVER a proxy for an avoidable call. Raw audio is \
            intentionally not retained, so suspicious wording may be labelled only as a hypothesis; never \
            claim a word was mistranscribed, inserted, or omitted without audio ground truth.

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
            silences that should have been tips and vice versa. For EVERY cited incident, write the \
            attribution explicitly: "The `me`/`them` transcript input said X; trigger Y caused call #N; \
            Jarvis brain output generated Z; Activity recorded W." Never write the ambiguous "Call #N said \
            X" when X came from request input.

            ## Recommendations
            At most THREE concrete, non-duplicative actions ordered by expected impact. Tie each to evidence \
            above and prefix it with exactly one evidence label:
              - `[session-proven]` — directly demonstrated by this session's persisted evidence.
              - `[source-confirmed]` — a mechanism verified against code in this checkout; cite file/symbol.
              - `[hypothesis]` — plausible but requiring validation (including any ASR claim without audio).
              - `[preserve]` — positive behavior that must survive a change; do not phrase it as a defect.
            Keep hypotheses and preservation notes distinct from proven defects, and merge recommendations \
            that address the same cause.

            Cite call numbers (call #N) as evidence throughout. If the data doesn't support a finding, say \
            so rather than speculating. Before finalizing, re-check every number in your draft against the \
            metrics table and against `\(trafficFilename)`, and correct or delete any that disagree. Output \
            ONLY the markdown report — it is saved as `\(reportFilename)` in the session directory (the \
            harness prepends a one-line provenance stamp, so don't add your own).
            """
        }
    }
}
