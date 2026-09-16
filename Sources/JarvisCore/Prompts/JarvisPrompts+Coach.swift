import Foundation

extension JarvisPrompts {
    /// The coaching system prompt, all of it, in the order the model reads it:
    ///
    /// 1. Identity, context, loading, and the action policy.
    /// 2. The guidance of each tool offered from the first request. It lives on the tool, in
    ///    `Coach/Tools/`, so the prompt can never describe a tool this session does not have. `speak`
    ///    is always offered, so its tip style is always here, and its detail rules when the box is on.
    /// 3. The tools, then the skills, this session can load.
    ///
    /// Domain rules are not here: a coding question's code-block rules are in the `coding` skill and
    /// a design question's diagram rules in `system-design`, so the model reads them only after it
    /// loads that skill, instead of every session paying for them in its cached prefix.
    ///
    /// What the harness sends later in the conversation lives elsewhere: each tool's result text in
    /// its file under `Coach/Tools/`, and the per-turn messages in `JarvisPrompts+CoachTurn.swift`.
    public enum Coach {
        /// The complete coaching system prompt. `CoachAttemptRunner` assembles it here for every
        /// request from the session's one capability set, so a session's instructions stay identical
        /// from its first request to its last, whichever target serves them.
        ///
        /// - `capabilities`: the session's switched-on tools and skills, resolved once at Start.
        ///   Each hot tool contributes its own guidance, each deferred tool and each skill one
        ///   catalog line, so the prompt describes exactly what this session has — no more, no
        ///   fewer. A skill's body is never here: it arrives as a `load_skill` result.
        public static func system(capabilities: CoachCapabilities) -> String {
            let deferred = capabilities.deferredTools
            let skills = capabilities.skills
            let sections = [base(loadableSkills: !skills.isEmpty, loadableTools: !deferred.isEmpty)]
                + capabilities.hotTools.map(\.guidance).filter { !$0.isEmpty }
            return sections.joined(separator: "\n\n")
                + (deferred.isEmpty ? "" : "\n\n" + toolCatalog(deferred))
                + (skills.isEmpty ? "" : "\n\n" + skillCatalog(skills))
        }

        /// Section 1 alone, as a session with nothing to load sends it: the only place response
        /// behavior is governed (no code-side guardrail).
        public static var system: String { base(loadableSkills: false, loadableTools: false) }

        // MARK: - 1. Identity, context, loading, and action policy

        /// With something to load, a `# Loading` section precedes the action policy. It is its own
        /// section rather than a numbered item so the policy's numbering is fixed at 1 to 6, whatever
        /// the session offers, and the loaders are described once instead of in three places. A
        /// prompt must never name a loader the session does not offer, which is why that text is
        /// assembled per catalog.
        private static func base(loadableSkills: Bool, loadableTools: Bool) -> String {
            let loading = loadableSkills || loadableTools
                ? "\n" + loadingSection(skills: loadableSkills, tools: loadableTools) + "\n"
                : ""
            return """
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
            - You can see the screen only through capture_screen. A fresh screenshot or screen text in the current input
              counts as current screen context.
            \(loading)
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
            4. "me" is making steady progress: call stay_silent.
            5. Progress is unclear, especially after silence: call capture_screen unless a fresh result is already
               available. Then speak only if the user seems stuck; otherwise call stay_silent.
            6. "me" is stuck: call speak, following the Tip style guidance below. Build on earlier tips
               instead of repeating them.

            A fresh capture result satisfies the screen gate for that request. Use it; do not capture again for
            the same request.
            """
        }

        /// The loading section, naming only the loaders present.
        private static func loadingSection(skills: Bool, tools: Bool) -> String {
            let loaders = [
                skills ? "a skill listed under \"Skills you can load\" with load_skill" : nil,
                tools ? "a tool listed under \"Tools you can load\" with load_tool" : nil,
            ].compactMap { $0 }.joined(separator: ", or ")
            return """
            # Loading
            Before choosing an action, load what this question needs and has not loaded: \(loaders).
            Load one per response; the result comes straight back, so act on it in the same turn.
            When the turn says you must call speak, skip loading and speak with what you have.
            """
        }

        // MARK: - 2. Tool guidance
        // Not written here: each hot tool's `guidance`, from its file in `Coach/Tools/`.

        // MARK: - 3. What this session can load

        /// One line per entry, its own description verbatim, so the model chooses from the same
        /// sentence it would read after loading.
        private static func toolCatalog(_ tools: [ToolDef]) -> String {
            ("""
            # Tools you can load
            Call load_tool with the name before first use; the result carries the schema and guidance.
            """ + "\n")
                + tools.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        }

        private static func skillCatalog(_ skills: [Skill]) -> String {
            ("""
            # Skills you can load
            Call load_skill with the name the first time a question of that kind comes up; the result is \
            the skill's full guidance.
            """ + "\n")
                + skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        }
    }
}
