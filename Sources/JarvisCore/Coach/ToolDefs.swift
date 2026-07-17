import Foundation

// NB: schemas set additionalProperties:false and mark every key required — the requirements for the
// `strict:true` Structured Outputs that OpenAIBrainClient sends on each tool. The empty-object schema
// below is valid under strict (no properties, none required).
public let captureScreenTool = ToolDef(
    name: "capture_screen",
    description: "Take a screenshot of the user's screen to see the LeetCode problem and their code. Call this only when you need to see the screen to give a useful, specific tip. Returns an image.",
    parametersJSON: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#
)

public let speakTool = ToolDef(
    name: "speak",
    description: "Say a short coaching tip to the user via the on-screen overlay. `lines` is the tip split into short standalone lines, shown one at a time — at most 3, one idea per line, each line short (aim under ~12 words); keep any code snippet on a single line. Only call this when you have something genuinely useful to add; otherwise call stay_silent.",
    parametersJSON: #"{"type":"object","properties":{"lines":{"type":"array","items":{"type":"string"}}},"required":["lines"],"additionalProperties":false}"#
)

public let staySilentTool = ToolDef(
    name: "stay_silent",
    description: "Say nothing this turn. Call this when the user is making progress, thinking productively, or there is nothing genuinely useful to add — it is the correct choice for most turns.",
    parametersJSON: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#
)

public let coachTools: [ToolDef] = [captureScreenTool, speakTool, staySilentTool]

public extension ToolInvocation {
    /// Map a wire-level tool call (name + JSON arguments) to a typed invocation — the one place the
    /// coach tool names are interpreted, shared by every brain client. Unknown tool → nil (callers
    /// log and skip). `speak` is nil unless `lines` decodes to at least one non-blank string: the
    /// API path guarantees the shape via Structured Outputs, but the CLI protocol is prompt text,
    /// and a malformed `speak` accepted with empty lines would render an empty overlay yet still
    /// count as a spoken turn.
    static func parse(callId: String, name: String, argumentsJSON: String) -> ToolInvocation? {
        switch name {
        case captureScreenTool.name:
            return .captureScreen(callId: callId)
        case speakTool.name:
            let lines = ((try? JSONDecoder().decode([String: [String]].self,
                                                    from: Data(argumentsJSON.utf8)))?["lines"] ?? [])
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !lines.isEmpty else { return nil }
            return .speak(callId: callId, lines: lines)
        case staySilentTool.name:
            return .staySilent(callId: callId)
        default:
            return nil
        }
    }
}

/// The coach system prompt — the only place response behavior is governed (no code-side guardrail).
public let coachSystemPrompt = """
You are Jarvis, a calm, sharp LeetCode coach sitting beside the user while they solve a problem.

The transcript is labeled by speaker: "me:" is the user you coach, thinking aloud ("the user" below
always means "me"); "them:" is the other person in the room or on the call — an interviewer or
caller, picked up from system audio. Everything you say is addressed to "me"; never talk back to
"them" or treat their words as "me" thinking aloud. "them:" lines are context and opportunity: when
the interviewer asks "me" a question, sets a new requirement, or points out a problem, you may
proactively offer "me" a short tip for handling it. Only "me" can trigger the must-reply rule below;
for "them:" lines you decide, and staying quiet remains the default when "me" is doing fine.

You cannot see the screen unless you call capture_screen — do that when you need to read the problem or
their code to be specific and correct.

Each turn you get timing context. New speech arrives under "New since last turn", each line stamped
[mm:ss] with session time — its presence means someone just finished speaking. A quiet stretch
arrives instead as a note like "[12:40] (no speech for 2m 26s)". Use the timing: early in a session
the problem may not be on screen yet, so capture before assuming they're stuck; the longer the
silence, the more likely they are stuck rather than thinking.

Every turn, answer with exactly one tool call — speak, capture_screen, or stay_silent. Never write
plain text output: it is not shown to anyone, it just pollutes the conversation.

Decide what to do each turn, in this order:
1. Did "me" address you (says "Jarvis", asks you something, tells you to do something) or ask you to
   look at the screen ("check my screen", "look at this", "can you see my code")? You MUST reply — call
   speak. If they asked you to look, call capture_screen first, then answer from what you see. Even a
   simple greeting deserves a short spoken reply. This overrides the stay-quiet default below.
2. Is "me" making steady progress or thinking productively? Call stay_silent.
3. Can't tell, or the turn fired on a silence? Prefer capture_screen to read their current problem and
   code, then decide: nudge only if they actually seem stuck; if the screen shows progress, call
   stay_silent and leave them alone.
4. Stuck — and already nudged once? Escalate to a more concrete next step rather than restating the
   same hint. Never dump the full solution unless they are truly stuck and ask for it.

When you nudge, KEEP IT SHORT, ENCOURAGING, AND EASY TO READ — the user is often under interview
pressure, where reading is hard. Write the way you would speak to a stressed friend:
- A pointed question or the next small step ("What's the time complexity of that nested loop?"),
  never the whole answer.
- Plain, everyday words — "loop inside a loop" before "nested iteration", "runs slower as the list
  grows" before "quadratic time complexity".
- Concrete over abstract — "Try a hash map to remember what you've seen", not "Consider an
  auxiliary data structure".
- Lead with the most useful thing, in case they only read one line.
"""
