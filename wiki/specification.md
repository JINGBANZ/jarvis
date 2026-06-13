# Specification

> The buildable spec. Another agent should be able to implement Jarvis's MVP from this page plus
> [architecture.md](./architecture.md). Normative: where this says "must," it's a requirement.

## 1. Summary

A native Swift/SwiftUI macOS menu-bar app. It transcribes the user's voice continuously, and on
each conversational turn (or after a silence) it calls GPT-5.5 with two tools — `capture_screen`
and `speak`. The model decides whether to look at the screen and whether to offer a short LeetCode
coaching tip, which is rendered in an overlay.

## 2. The Harness Loop (pseudocode)

```swift
// Always-on: stream audio to the Realtime API, maintain a rolling transcript.
transcriber.onTurnEnd  = { handleTrigger(reason: .turnEnd) }
transcriber.onSilence  = { handleTrigger(reason: .silence) }   // e.g. 8s of no speech

func handleTrigger(reason: TriggerReason) {
    guard !muted else { return }
    guard coachDriver.guardrailsAllow() else { return }   // cooldown + rate cap

    let messages = coachPrompt(transcriptWindow: transcriber.recentWindow(seconds: 90),
                               reason: reason)
    // Tool-use loop against GPT-5.5
    var convo = messages
    while true {
        let resp = openAI.chat(model: GPT_5_5,
                               messages: convo,
                               tools: [captureScreenTool, speakTool])
        switch resp.toolCall {
        case .captureScreen:
            let image = screenTool.capture()             // silent screenshot
            convo.append(toolResult(.captureScreen, image))
            continue                                     // let the model reason over the image
        case .speak(let text):
            overlay.render(text)                         // <=3 sentences, 5s each
            coachDriver.noteSpoke()                      // start cooldown
            return
        case .none:
            return                                       // model chose to stay silent
        }
    }
}
```

The loop is deliberately small. All judgment ("do I need to see the screen?", "do I have a useful
tip?", "should I stay quiet?") lives in the model, not the harness.

## 3. Tools Exposed to the Model

### `capture_screen`

```json
{
  "name": "capture_screen",
  "description": "Take a screenshot of the user's active display to see the LeetCode problem and their code. Call this only when you need to see the screen to give a useful, specific tip. Returns an image.",
  "parameters": { "type": "object", "properties": {}, "required": [] }
}
```

- **Implementation:** invoke the built-in macOS tool `screencapture -x -t jpg <tmpfile>` (`-x` =
  silent, no shutter sound), or ScreenCaptureKit for an in-memory frame. **Must exclude Jarvis's
  own overlay window** so the model never sees its own output.
- **Return:** the image is appended to the conversation as a tool result (image content block).
- **Cost control:** this is the only path that spends vision tokens. It fires only when the model calls it.

### `speak`

```json
{
  "name": "speak",
  "description": "Say a short coaching tip to the user via the on-screen overlay. Use at most 3 short sentences. Only call this when you have something genuinely useful to add; otherwise do not call any tool (stay silent).",
  "parameters": {
    "type": "object",
    "properties": { "text": { "type": "string" } },
    "required": ["text"]
  }
}
```

- **Implementation:** render `text` in the Overlay. The harness splits on sentence boundaries and
  shows **at most 3** sentences, **~5 seconds each**; any text beyond 3 sentences is dropped.
- **Silence:** if the model calls no tool, Jarvis says nothing. This is expected and common.

## 4. Coach System Prompt (MVP)

> Stored as a constant; tune freely. Encodes the *only* behavior in the MVP.

```
You are Jarvis, a calm, sharp LeetCode coach sitting beside the user while they solve a problem.
You hear them think aloud. You cannot see their screen unless you call capture_screen — do that
when you need to read the problem or their code to be specific and correct.

Your job: nudge them toward the solution with short, encouraging, *specific* hints. Never dump the
full solution unless they are truly stuck and ask for it. Prefer asking a pointed question or
pointing at the next small step (e.g. "What's the time complexity of that nested loop?").

Speak only when it helps. If they are making good progress, stay silent — call no tool. When you
do speak, call the speak tool with at most 3 short sentences.
```

## 5. Configuration

| Key | Default | Notes |
|---|---|---|
| `silenceTimeoutSeconds` | 8 | How long of no speech before a "maybe stuck" trigger fires. |
| `cooldownSeconds` | 12 | Minimum gap between spoken responses. |
| `maxInterjectionsPerMinute` | 4 | Hard rate cap. |
| `transcriptWindowSeconds` | 90 | How much recent transcript the model sees per turn. |
| `sentenceDisplaySeconds` | 5 | How long each overlay sentence stays up. |
| `maxSentences` | 3 | Hard cap on response length. |
| `model.brain` | GPT-5.5 | Confirm exact model ID against current OpenAI docs at build time. |
| `model.transcription` | OpenAI Realtime | Confirm exact model ID at build time. |

API key is read from the **Keychain**, entered once via the menu bar. Never stored in plaintext or
committed.

## 6. Audio Sources

- **Mic (critical path):** the user thinking aloud. AVFoundation → Realtime. Must work in MVP.
- **System audio (in MVP, budget-permitting):** the "other side" of a call (e.g. a mock
  interviewer on Zoom). ScreenCaptureKit audio capture, labeled as a distinct speaker. It is part
  of the MVP and rides along with the screen-capture entitlement; it is the **first feature cut if
  it threatens the 2-day budget**, but the intent is to ship it. The design must not preclude it.

## 7. Latency Budget

Target: **turn-end → first overlay sentence < 2 seconds.** Levers:
- Transcription is continuous, so there is no STT latency at trigger time.
- Most turns are text-only (no `capture_screen`) and therefore fast.
- Stream the model's response and render sentence-by-sentence so the first sentence appears before
  the third is generated.

## 8. Self-Verification Plan

The build agent must produce and run these. (See the development goal: the agent verifies its own work.)

**Unit tests (pure logic, run anywhere):**
- CoachDriver guardrails: cooldown suppresses a second response inside the window; rate cap blocks
  the (N+1)th interjection in a minute; mute suppresses all output.
- Overlay formatting: a 5-sentence input renders exactly 3 sentences; sentence splitting is correct.

**Offline pipeline test (mock OpenAI client, run anywhere):**
- Feed a fixture transcript ("I think I'll brute-force two-sum with a double loop") + a fixture
  screenshot. Assert the mock model's `capture_screen` request is fulfilled with the image, and a
  `speak` call with the expected shape (≤3 sentences) is produced and routed to a fake overlay.

**Live smoke checklist (run on the Mac, manual or scripted):**
1. App launches; menu-bar icon present; permissions (Screen Recording, Microphone) granted.
2. Speaking produces transcript text within ~1s.
3. A planted prompt — say "Jarvis, I'm stuck on two-sum" aloud with the problem on screen —
   produces a coaching overlay within the latency budget, and the model is observed to call
   `capture_screen`.
4. `capture_screen` returns a valid image and the overlay window is absent from it.
5. Guardrails hold: rapid triggers do not produce more than `maxInterjectionsPerMinute` responses;
   mute silences output.

**Guardrail / cost guard:** a session token-and-call counter surfaced in the menu bar, so runaway
behavior is visible.

## 9. Build & Run Constraints

- Built and verified **on the MacBook** (the macOS-native capture, permissions, and overlay cannot
  be tested on Linux). See [decision 0004](./decisions/0004-build-on-mac-not-vps.md).
- Built inside a **restricted macOS user account** (security). See [sandbox.md](./sandbox.md).
- Target: a working MVP in **< 2 days of autonomous Claude Code build**.
