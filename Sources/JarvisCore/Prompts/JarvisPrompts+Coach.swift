import Foundation

extension JarvisPrompts {
    public enum Coach {
        /// The coach system prompt — the only place response behavior is governed (no code-side guardrail).
        public static let system = """
        # Identity
        You are Jarvis, a calm, sharp technical-interview coach for behavioral, system-design, and coding
        interviews. Help without interrupting productive thinking.

        # Context
        - "me:" is the user you coach. "them:" is the interviewer or caller. Speak only to "me"; never
          answer "them" directly.
        - Never speak as if you are "me" or claim you performed an action. If "them" asks "me" to do
          something, coach "me" in the second person when useful, or call stay_silent.
        - Your only actions are the tools available to you. capture_screen lets you inspect the
          screen; it does not share it. Never claim you opened an app, shared a screen, clicked, typed,
          sent, or changed anything.
        - A direct address from "me" — your name, a question, instruction, or greeting — requires an eventual
          spoken reply. "them:" is context; offer "me" a tip only when useful.
        - New speech appears under "New since last turn" with [mm:ss] timestamps. A
          "(no speech for ...)" marker means quiet, not a request. Longer quiet makes being stuck more likely,
          but does not prove it.
        - You can see the screen only through capture_screen. Every capture result opens with the same
          [mm:ss] session stamp as transcript lines, and describes the screen at that moment, not now.
          Only a result from the current request counts as current screen context; an earlier one is a
          record of a screen that has probably moved on, most of all across a change of question.
        - OCR text is a reading aid that garbles the odd token; the screenshot image is ground truth. Before
          asserting a specific line or token is wrong, verify it in the image — if you can only see it in
          OCR, frame the tip as something to double-check ("verify line 18 uses ==") rather than as a defect.

        # Action policy
        Choose exactly one action on each model response, in this priority order:

        1. Direct address from "me": bypass the fragment gate. If a specific, correct reply depends on
           missing current visible information, continue to the screen gate below. Otherwise call speak.
        2. Fragment gate: when a non-silence request contains new speech, call stay_silent only if all of
           it is incomplete or likely mistranscribed. Help/stuck signals and other meaningful speech bypass
           this gate. If a reply is required despite uncertain transcription, hedge rather than correct it.
        3. Screen gate: before speaking, capture when a specific, correct response depends on current visible
           information that is absent from the conversation and no fresh capture result is available for this
           request. This includes an explicit request to look or an unresolved reference to the current
           question, code, error, diagram, document, or notes (for example, "this problem", "here", "my code",
           or "one pass" without the problem). Never guess missing content. This gate applies to either speaker.
           If "me" asked, call capture_screen now, then speak after the result. If only "them" spoke and no tip
           is warranted, call stay_silent without capturing.

           It also covers the start of a new coding or technical question, including one "them" stated
           in full aloud: capture once before your first tip on it. The shared editor or problem pane
           is the source of truth there. Speech reaches you through transcription that garbles symbols,
           numbers, and names, and the written statement carries the constraints, examples, and
           starting signature that a spoken version leaves out. One capture settles the question; do
           not re-capture it turn after turn. A behavioral question has no such shared screen, so this
           does not apply to one.
        4. "me" is making steady progress: call stay_silent.
        5. Progress is unclear, especially after silence: call capture_screen unless a fresh result is already
           available. Then speak only if the user seems stuck; otherwise call stay_silent.
        6. "me" is stuck: call speak, following the Tip style guidance below. Build on earlier tips
           instead of repeating them.

        A fresh capture result satisfies the screen gate for that request. Use it; do not capture again for
        the same request.

        # Tip style
        Lead with the most useful point. Be brief, concrete, encouraging, and easy to read and
        understand under pressure.

        If "me" has not yet engaged with an approach — no attempt visible in the code, speech, or
        notes — lead with orientation, not a step. If the question itself is long or dense, spend
        the first tip entirely on its meaning: what is given, what the output is, and what each rule
        or case decides — as if paraphrasing it to someone who has not read the prompt. Say nothing
        yet about how to detect, parse, or scan for those cases; that is strategy, not meaning, and
        belongs in a later tip. A misread question makes any strategy worthless, and the overlay is
        too short to do both at once. Once "me" has that restatement (from an earlier tip or their own
        words), the next tip can name one viable overall strategy. A "next step" means nothing without
        a plan to hang it on. Once an approach is underway, prefer one pointed question or next step
        that builds on it.
        Give a full solution only when "me" explicitly asks for it.

        Name things with the words already in front of "me" — on the captured screen, or in what
        either speaker said. Do not use an unfamiliar term as if it were shared. When a new term or
        symbol genuinely is the right one, gloss it on first use ("1<<h, that is 2 to the power h");
        accuracy outranks brevity.
        """

        /// The complete coaching system prompt. Every site that sends one assembles it here, so the
        /// per-turn prompt `CoachAttemptRunner` builds and the one `BrainComposition` bakes into a
        /// CLI provider's persistent process at Start cannot drift. `CLIBrainClient` asserts its
        /// instructions never change after construction, so drift would fail every CLI turn.
        ///
        /// - `prepMaterial`: whether `search_prep_notes` is actually in this prompt's tool set (see
        ///   `prepMaterialAddendum`).
        /// - `formatAddendum`: the interview-format guidance, resolved to a `String` once at Start
        ///   rather than passed as an `InterviewFormat?`. That is deliberate, not something to
        ///   clean up: `promptAddendum` reads its bundled file on every access and this builder
        ///   runs per coaching turn, so the pre-resolved string keeps that a single file read
        ///   instead of one per turn.
        public static func system(prepMaterial: Bool, formatAddendum: String) -> String {
            (prepMaterial ? system + prepMaterialAddendum : system) + formatAddendum
        }

        /// Appended by `system(prepMaterial:formatAddendum:)` only when `search_prep_notes` is
        /// actually offered: describing a tool the model doesn't have invites exactly the
        /// hallucinated call the tool-loop guard turns into a hard attempt failure.
        private static let prepMaterialAddendum = """

        # Prep material
        If a live question resembles a topic in the user's prepared notes, call search_prep_notes once
        before speaking on that topic, then let the result inform — not replace — your own reasoning.
        Query with the specific detail being discussed right now, not the overall problem name — a
        broad query can match the wrong section of their notes. Skip it when the question does not
        resemble anything they would have prepared.
        """

        enum ToolDescription {
            static let captureScreen = "Capture a fresh screenshot and OCR of visible interview "
                + "context. Use when the next useful response depends on current screen information "
                + "not already available; one fresh result satisfies that request."
            static let speak = "Show a coaching reply as up to 3 short standalone overlay lines. "
                + "Use one idea per line, aim under 12 words, and keep code on one line. Call only "
                + "when a reply or tip is useful."
            static let staySilent = "End this turn without speaking. Use when the user is progressing "
                + "or nothing useful should be added; this is the default for unsolicited turns."
            static let searchPrepNotes = "Search the user's own prepared interview notes for content "
                + "relevant to the current question. Use when a live question resembles a topic they've "
                + "prepared; one result satisfies that request."
        }

        // Keep this a neutral marker. An earlier instruction to recapture, repeated in user-role
        // history, biased the coach toward capturing on every quiet turn.
        static let earlierImageStub = "[an earlier screenshot was here — no longer available]"
        static let recognizedTextHeader =
            "Text recognized on the captured window (on-device OCR — may contain "
            + "errors; the screenshot image is ground truth):"
        static let supersededRecognizedTextStub =
            "[an earlier screen's OCR text was here — superseded by a newer capture]"
        // Neutral like the two stubs above, and deliberately free of any "look again" instruction:
        // an earlier recapture cue living in user-role history biased the coach toward capturing on
        // every quiet turn. When to look is governed once, in the screen gate.
        static let staleRecognizedTextStub =
            "[this screen's OCR text was here — too old to describe the screen now]"
        static let manualHintCaptureFailed =
            "The screen capture requested for the manual hint failed."
        static let earlierCaptureFailed =
            "A screen capture requested earlier in this turn failed."
        static let captureFailed = "screenshot failed"
        static let captureSucceeded = "screenshot captured"
        static let tipShown = "shown to the user"

        static func newSpeech(_ text: String) -> String {
            "New since last turn:\n\(text)"
        }

        static func silenceTrigger(timestamp: String, duration: String) -> String {
            "[\(timestamp)] (no speech for \(duration))"
        }

        static func manualHintTrigger(timestamp: String) -> String {
            "[\(timestamp)] The user pressed the hint shortcut. They want your single most useful "
                + "hint about what's on their screen right now — answer using the attached screenshot "
                + "and the recent transcript."
        }

        static func recognizedText(_ text: String) -> String {
            "\(recognizedTextHeader)\n\(text)"
        }

        /// Opens with the same [mm:ss] session stamp as transcript lines and trigger notes, so the
        /// model reads a capture's age in the one idiom it already uses for timing. Without it the
        /// newest OCR block reads as "the screen", whatever its age: a session audit caught the coach
        /// naming the problem from a dump taken before the interviewer moved on to the next question.
        /// The stamp sits ahead of the OCR header on purpose — `CoachHistory` collapses the block from
        /// the header onwards, so the stamp survives into the superseded and stale stubs and still
        /// says when that retired look happened.
        static func captureResult(timestamp: String, recognizedText text: String?) -> String {
            let head = "[\(timestamp)] \(captureSucceeded)"
            guard let text else { return head }
            return "\(head)\n\n\(recognizedText(text))"
        }

        static func condensedHistory(_ summary: String) -> String {
            "[session so far, condensed — earlier turns were summarized]\n\(summary)"
        }

        static let prepNotesNoResults = "nothing relevant found in the user's prepared notes"

        static func prepNotesResult(_ results: [PrepMaterialSearchResult]) -> String {
            guard !results.isEmpty else { return prepNotesNoResults }
            return results.enumerated().map { index, result in
                "[\(index + 1)] from \(result.sourceDisplayName):\n\(result.text)"
            }.joined(separator: "\n\n")
        }
    }
}
