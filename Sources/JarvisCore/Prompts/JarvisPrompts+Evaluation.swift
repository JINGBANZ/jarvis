import Foundation

extension JarvisPrompts {
    enum Evaluation {
        static func sessionAudit(
            sessionDirectoryPath: String,
            transcriptFilename: String,
            trafficFilename: String,
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
              - `\(transcriptFilename)` — the session's wire-level LLM traffic. It OPENS with a \
            "=== deterministic metrics ===" table computed from the raw traffic (per-call and \
            aggregate input / cache-read / cache-write / output tokens and cost, plus a per-model \
            breakdown). Trust its known numbers and availability labels: `—` means unavailable, not zero, \
            and a `known (N unavailable)` value is partial, not a session total. Quote only what the table \
            supports; never recompute a total by eye. The rest is \
            one block per API call, in order — your PRIMARY narrative input. To keep it compact, content \
            byte-identical to the previous same-tag call is elided and marked "(unchanged)" — those \
            markers are exactly where the prompt cache SHOULD be hitting.
              - `\(trafficFilename)` — the same traffic un-elided. Because the transcript elides \
            byte-identical repeats, ANY cardinal count (stub occurrences, OCR dumps, marker repetitions) \
            MUST be counted here, not from the elided transcript.
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
            the filler substance gate, compaction trigger), \
            `Sources/JarvisCore/Brain/ReasoningEffort.swift` (`max_output_tokens` is a COMBINED \
            reasoning+output budget — a tight cap recreates the documented `status:"incomplete"` \
            truncation), and `Sources/JarvisCore/Config/Config.swift`. Before recommending a mechanism, \
            grep for it: several (screenshot stubbing, bulky-tool-result compaction, filler gating, \
            prompt_cache_key pinning) already exist.

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
            metrics table and against `\(trafficFilename)`, and correct or delete any that disagree. Output \
            ONLY the markdown report — it is saved as `\(reportFilename)` in the session directory (the \
            harness prepends a one-line provenance stamp, so don't add your own).
            """
        }
    }
}
