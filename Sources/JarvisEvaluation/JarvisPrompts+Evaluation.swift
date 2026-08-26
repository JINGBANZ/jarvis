import Foundation
import JarvisCore

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
            You are evaluating one completed session of Jarvis, a proactive macOS coaching assistant. \
            Your workspace is a checkout of the Jarvis source repository, and the session directory is:
                \(sessionDirectoryPath)

            Use the repository and session only as read-only evidence. You have file, search, and shell \
            tools: inspect the original artifacts, follow relevant evidence into the implementation, and \
            search for the symbols or behavior you need. Do not assume the prompt already knows which \
            problem, if any, occurred.

            The session directory can contain:
              - `\(transcriptFilename)` — a generated navigation aid. It begins with a neutral evidence \
            index showing artifact health, categorical distributions, and correlation-field coverage, then \
            normalized provider-call telemetry, then a compact ordered view of traffic records. \
            Repeated request prefixes may be explicitly elided; the original traffic remains untouched.
              - `\(trafficFilename)` — the complete, un-elided provider traffic JSONL. Its one-based \
            nonblank record number is also the `call #N` anchor for provider calls.
              - `\(attemptsFilename)` — coaching-attempt JSONL with attempt ids, transcript entries, request \
            provenance, and outcomes when that evidence was recorded.
              - `\(healthFilename)` — the audit completion and loss marker.
              - `\(activityFilename)` — the complete sanitized user-visible event history. Read it directly \
            when a finding depends on what the user experienced.
              - `shot-*.jpg` — screenshots retained for this session, if any.
              - an older `\(reportFilename)`, if the session was evaluated before. Treat it only as prior \
            analysis, never as evidence or as a required set of findings.

            The generated tables are measurements, not conclusions. A category count does not say whether \
            the category was correct, and missing field coverage does not by itself prove a defect. `—` \
            means unavailable, not zero. A known subtotal with unavailable records is not a session total. \
            Never fill an evidence gap with an assumption. Use the raw JSONL for exact values and the source \
            for mechanism claims; do not recompute normalized telemetry by eye.

            Independently identify material findings supported by this session. Follow discrepancies, \
            failures, outliers, and useful patterns wherever the evidence leads, across correctness, \
            reliability, efficiency, privacy, and user experience. Do not run a predefined incident \
            checklist. For every finding, separate what the session directly shows, what the source confirms, \
            and what remains a hypothesis. Cite precise file, record/call, attempt, event, screenshot, or source \
            anchors. Explain the user impact and confidence. If the available evidence supports no material \
            finding, say that plainly.

            Write a markdown report with exactly these sections:

            ## Summary
            State the overall result and the completeness of the evidence.

            ## Findings
            Order material findings by impact. Give each a concise title, evidence anchors, user impact, and \
            confidence. Do not invent findings to fill the section.

            ## Evidence gaps
            State what is missing or unavailable and which conclusions therefore cannot be verified. Write \
            `None material.` when there is no meaningful gap.

            ## Recommendations
            Give at most three concrete actions tied to findings, ordered by expected impact. Do not recommend \
            a code change for an unsupported hypothesis, and name behavior that a change must preserve when \
            that constraint matters. Write `None.` when no action is justified.

            Output only the markdown report. The harness saves it as `\(reportFilename)` and adds its own \
            provenance stamp.
            """
        }
    }
}
