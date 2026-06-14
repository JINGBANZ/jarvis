# Jarvis Phase-2 Native Build — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the native macOS Jarvis LeetCode-coach app — an always-on menu-bar app that transcribes the user thinking aloud, and on each turn calls `gpt-5.5` with `capture_screen` + `speak` tools to proactively render short coaching tips in an overlay.

**Architecture:** A two-target SwiftPM package. `JarvisCore` holds all pure, deterministic logic behind protocols (config, rolling timestamped transcript, guardrails, the coach-driver tool-loop, overlay sentence-splitting, the OpenAI brain client, the screen-capture CLI wrapper) and is fully unit-tested with mocks via `swift test`. `JarvisApp` is the executable that wires `JarvisCore` to the side-effectful macOS frameworks (NSPanel overlay, AVFoundation mic, ScreenCaptureKit system audio, the realtime-transcription websocket, the menu bar) and is packaged into an ad-hoc-signed `.app` bundle. The model is the only place judgment lives; the harness is thin glue + safety.

**Tech Stack:** Swift 6.3 / SwiftPM, Command Line Tools SDK (no full Xcode), AppKit (NSPanel, NSStatusItem), SwiftUI not required, AVFoundation, ScreenCaptureKit, Security (Keychain), URLSession (Chat Completions + Realtime websocket), XCTest. Built and ad-hoc signed via a shell script; Screen-Recording + Microphone granted via macOS TCC prompts.

**Source of truth:** [specification.md](./specification.md), [architecture.md](./architecture.md), [sandbox.md](./sandbox.md). This plan implements them.

**Scope of autonomous verification:** Tasks 0–9 and 14 are fully verifiable headless (build + tests + bundle/sign/launch). Tasks 10–13 (overlay, audio, realtime transcriber, screen capture) **compile and launch** but their *live behavior* needs a human (mic input, TCC grants, a real `OPENAI_API_KEY`, models that actually exist). Those are validated by the **Live Smoke Checklist** in [specification.md §8](./specification.md#8-self-verification-plan), deferred to the user.

---

## Review Amendments (B1–B3) — apply throughout

A fresh-agent review (2026-06-14) compile-tested the plan on this exact machine and found three blockers. These corrections override the task bodies below wherever they conflict.

### B1 — Tests use **swift-testing**, not XCTest (no XCTest in CLT-only)

`import XCTest` fails with "no such module" under Command Line Tools. Use the bundled **swift-testing** framework, run via a wrapper script that adds its search paths.

- **Create `scripts/run-tests.sh`** (Task 0) and use `./scripts/run-tests.sh` **everywhere** the tasks say `swift test`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
IOP=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
exec swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$IOP" \
  "$@"
```

- **Convert every test file** from XCTest to swift-testing using this mapping:
  - `import XCTest` → `import Testing`
  - `final class FooTests: XCTestCase { func testBar() {...} }` → `@Suite struct FooTests { @Test func bar() {...} }`
  - `XCTAssertEqual(a, b)` → `#expect(a == b)`; `XCTAssertTrue(x)` → `#expect(x)`; `XCTAssertFalse(x)` → `#expect(!x)`; `XCTAssertNil(x)` → `#expect(x == nil)`
  - accuracy form `XCTAssertEqual(a, b, accuracy: 0.001)` → `#expect(abs(a - b) < 0.001)`
  - async stays `@Test func bar() async {...}`; throwing → `@Test func bar() async throws {...}`
  - error expectation `do { _ = try await …; XCTFail() } catch {}` → `await #expect(throws: (any Error).self) { _ = try await … }`
  - Mocks/fakes stay plain classes (no XCTestCase). Filtering: `./scripts/run-tests.sh --filter FooTests` still works.

### B2 — Swift 6 strict concurrency: annotate AppKit classes `@MainActor` (Tasks 10, 12, 13)

`swift-tools-version:6.0` enables full data-race checking; AppKit types are `@MainActor`. Apply:

- `@MainActor final class OverlayPanel`, `@MainActor final class MenuBarController`, `@MainActor final class AppDelegate`, `@MainActor final class AudioInput`.
- In `OverlayPanel`, make the protocol witness **nonisolated** and hop to the main actor:

```swift
nonisolated func render(_ text: String, maxSentences: Int, perSentenceSeconds: TimeInterval) {
    let sentences = splitIntoSentences(text, maxSentences: maxSentences)
    guard !sentences.isEmpty else { return }
    Task { @MainActor in self.show(sentences, each: perSentenceSeconds) }
}
```

- Replace every `DispatchQueue.main.async { … }` in the App target with `Task { @MainActor in … }`.
- In `MenuBarController.noteSpoke()` (now `@MainActor`), update the counter directly (no dispatch).
- In `AppDelegate.startTranscription()`, **capture the driver locally** (it's `@unchecked Sendable`) so the transcriber callbacks don't capture `@MainActor self`:

```swift
let driver = self.driver!
transcriber.onTurnEnd = { Task { await driver.handleTrigger(.turnEnd) } }
transcriber.onSilence = { secs in Task { await driver.handleTrigger(.silence(secondsQuiet: secs)) } }
driver.onSpoke = { [weak self] in Task { @MainActor in self?.menuBar.noteSpoke() } }
```

- Make `RealtimeTranscriber.onTurnEnd`/`onSilence` `@Sendable`: `var onTurnEnd: (@Sendable () -> Void)?`, `var onSilence: (@Sendable (TimeInterval) -> Void)?`. Make `AudioInput.onPCM` `@Sendable (Data) -> Void`. Resolve any residual tap-closure `Sendable` warnings at compile time (mark the transcriber `@unchecked Sendable` if needed for the audio callback).

### B3 — Tool-loop must replay the assistant `tool_calls` turn (Tasks 6, 8, 9)

The Chat Completions API rejects a `role:tool` message unless the preceding `assistant` message carried the matching `tool_calls`. Thread it through:

- **Brain.swift** — add a raw tool-call type, a field on `ChatMessage`, a factory, and a field on `BrainResponse`:

```swift
public struct RawToolCall: Sendable {
    public let id: String, name: String, argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id; self.name = name; self.argumentsJSON = argumentsJSON
    }
}
// add to ChatMessage:
//   public let toolCalls: [RawToolCall]?   (init param, default nil; include in the memberwise init)
//   static func assistantToolCalls(_ calls: [RawToolCall]) -> ChatMessage {
//       .init(role: .assistant, toolCalls: calls) }
// add to BrainResponse:
//   public let rawToolCalls: [RawToolCall]    (init param)
```

- **CoachDriver.swift** — on `.captureScreen`, append the assistant turn before the tool result:

```swift
case .captureScreen(let callId):
    convo.append(.assistantToolCalls(response.rawToolCalls))
    if let img = screen.capture() {
        convo.append(.init(role: .tool, text: "screenshot captured", toolCallId: callId))
        convo.append(.userImage(img))
    } else {
        convo.append(.init(role: .tool, text: "screenshot failed", toolCallId: callId))
    }
    continue
```

- **OpenAIBrainClient.swift** — `decode` populates `rawToolCalls` (id, name, arguments) alongside the parsed `toolCalls`; `encodeBody` emits assistant messages with `tool_calls`:

```swift
// in encodeBody, for an assistant ChatMessage with toolCalls:
if m.role == .assistant, let calls = m.toolCalls {
    msgs.append([
        "role": "assistant",
        "content": NSNull(),
        "tool_calls": calls.map { ["id": $0.id, "type": "function",
            "function": ["name": $0.name, "arguments": $0.argumentsJSON]] },
    ])
    continue
}
```

- **CoachDriverPipelineTests** — `ScriptedBrain`'s capture response must include `rawToolCalls`, and add an assertion that the second brain call's conversation contains an assistant message with non-nil `toolCalls`:

```swift
// script[0]: .init(toolCalls: [.captureScreen(callId: "c1")],
//                   rawToolCalls: [RawToolCall(id: "c1", name: "capture_screen", argumentsJSON: "{}")])
// assert: #expect(brain.calls[1].contains { $0.toolCalls != nil })
```

### Minor (apply opportunistically)

- `screencapture` add `-D 1` is optional; default already targets the main display.
- Don't claim response *streaming* (overlay shows pre-split sentences sequentially; the brain call is not streamed). Spec §7's latency lever about streaming is not implemented in this MVP.

### B4 — verified against live OpenAI docs (2026-06, post-build)

After the build, the OpenAI integration was checked against current docs and corrected (the Task 9 / Task 13 bodies above describe the *original* Chat-Completions/`gpt-realtime-2` design; the shipped code uses the following instead):

- **Brain = Responses API** (`POST /v1/responses`). `OpenAIBrainClient` sends flat function tools, the system prompt via `instructions`, the conversation as typed `input` items (`input_text`/`input_image`), the tool loop via `function_call` + `function_call_output`, and `reasoning.effort = low`. Decoding reads the `output` array for `function_call` items. `gpt-5.5` confirmed (snapshot `gpt-5.5-2026-04-23`).
- **Transcription = `gpt-4o-transcribe`** over the **GA Realtime API** (`gpt-realtime-2` was not a real ID). `RealtimeTranscriber` drops the `OpenAI-Beta` header, configures a `session.type:"transcription"` session with config under `session.audio.input` (`format` audio/pcm 24000, `transcription.model`, `turn_detection` server_vad), and `AudioInput` targets 24 kHz. Turn end = `input_audio_buffer.speech_stopped`; transcript = `conversation.item.input_audio_transcription.completed`.
- **Key entry** is seamless: the menu "Set OpenAI API Key…" saves to the Keychain and restarts the pipeline immediately (no relaunch).

Sources: OpenAI docs for [gpt-5.5](https://developers.openai.com/api/docs/models/gpt-5.5), [function-calling](https://developers.openai.com/api/docs/guides/function-calling), [realtime-transcription](https://developers.openai.com/api/docs/guides/realtime-transcription).

---

## File Structure

```
Package.swift
Sources/
  JarvisCore/                       # library — pure, testable; Foundation only (no AppKit)
    Clock.swift                     # Clock protocol + SystemClock + ManualClock (tests)
    Config.swift                    # constants, model IDs, Keychain/env key loading
    Secrets.swift                   # SecretStore protocol + KeychainSecretStore + EnvSecretStore
    Transcript.swift                # TranscriptLine, Speaker, RollingTranscript (timestamped window)
    Trigger.swift                   # TriggerReason, TriggerContext
    Guardrails.swift                # Guardrails: cooldown + rate cap + mute (Clock-injected)
    OverlayText.swift               # splitIntoSentences(...) pure function + OverlayRendering protocol
    Brain.swift                     # ChatMessage, ToolDef, ToolInvocation, BrainResponse, BrainClient protocol
    ToolDefs.swift                  # captureScreenTool / speakTool JSON definitions + coachSystemPrompt
    OpenAIBrainClient.swift         # real BrainClient over Chat Completions (URLSession); request/response codecs
    ScreenCapture.swift             # ScreenCapturing protocol + ScreenCaptureCLI (screencapture -x)
    CoachDriver.swift               # the event loop: trigger → guardrails → brain tool-loop → speak/capture
  JarvisApp/                        # executable — AppKit + capture glue; needs GUI + TCC
    main.swift                      # entry point; NSApplication bootstrap
    AppDelegate.swift               # wires everything; owns the components
    OverlayPanel.swift              # NSPanel overlay (non-activating, top, excluded from capture) + OverlayRendering impl
    MenuBarController.swift         # NSStatusItem: on/off, mute, API-key entry, session counter
    AudioInput.swift                # AVFoundation mic + ScreenCaptureKit system audio → PCM frames
    RealtimeTranscriber.swift       # gpt-realtime-2 websocket → RollingTranscript + turn/silence events
Tests/
  JarvisCoreTests/
    ClockTests.swift
    ConfigTests.swift
    TranscriptTests.swift
    GuardrailsTests.swift
    OverlayTextTests.swift
    ToolDefsTests.swift
    OpenAIBrainClientTests.swift
    CoachDriverPipelineTests.swift  # the offline pipeline test (spec §8)
scripts/
  build-app.sh                      # swift build -c release → assemble Jarvis.app → ad-hoc codesign
  run-tests.sh                      # swift test
.gitignore                          # .build/, *.app, secrets
```

**Boundary rule for this build:** every file written lives under the worktree. `JarvisCore` imports only `Foundation` (+ `Security` in `Secrets.swift`) so it stays portable and test-fast. AppKit/ScreenCaptureKit/AVFoundation are confined to `JarvisApp`.

---

## Task 0: SwiftPM scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/JarvisCore/Clock.swift`
- Create: `Sources/JarvisApp/main.swift`
- Create: `Tests/JarvisCoreTests/ClockTests.swift`
- Create: `.gitignore`

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "JarvisCore"),
        .executableTarget(
            name: "JarvisApp",
            dependencies: ["JarvisCore"]
        ),
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore"]
        ),
    ]
)
```

- [ ] **Step 2: Write the first failing test** — `Tests/JarvisCoreTests/ClockTests.swift`

```swift
import XCTest
@testable import JarvisCore

final class ClockTests: XCTestCase {
    func testManualClockAdvances() {
        let clock = ManualClock(now: 100)
        XCTAssertEqual(clock.now(), 100)
        clock.advance(by: 5)
        XCTAssertEqual(clock.now(), 105)
    }
}
```

- [ ] **Step 3: Run to verify it fails to build** — Run: `swift test` — Expected: FAIL (no `ManualClock`).

- [ ] **Step 4: Implement `Sources/JarvisCore/Clock.swift`**

```swift
import Foundation

/// Monotonic-ish seconds source, injectable so logic is testable without real time.
public protocol Clock: AnyObject {
    func now() -> TimeInterval
}

public final class SystemClock: Clock {
    public init() {}
    public func now() -> TimeInterval { Date().timeIntervalSince1970 }
}

/// Test clock with manual control.
public final class ManualClock: Clock {
    private var current: TimeInterval
    public init(now: TimeInterval = 0) { self.current = now }
    public func now() -> TimeInterval { current }
    public func advance(by delta: TimeInterval) { current += delta }
    public func set(_ value: TimeInterval) { current = value }
}
```

- [ ] **Step 5: Write `Sources/JarvisApp/main.swift`** (placeholder so the executable target builds)

```swift
import Foundation

// Real bootstrap arrives in Task 10. For now, prove the target links.
print("Jarvis starting…")
```

- [ ] **Step 6: Write `.gitignore`**

```
.build/
*.app
*.xcodeproj
.DS_Store
secrets.env
```

- [ ] **Step 7: Run tests to verify pass** — Run: `swift test` — Expected: PASS (1 test). Also run `swift build` — Expected: builds both targets.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources Tests .gitignore
git commit -m "scaffold: SwiftPM package with JarvisCore + JarvisApp + Clock"
```

---

## Task 1: Config + Secrets

**Files:**
- Create: `Sources/JarvisCore/Config.swift`
- Create: `Sources/JarvisCore/Secrets.swift`
- Create: `Tests/JarvisCoreTests/ConfigTests.swift`

- [ ] **Step 1: Write failing test** — `Tests/JarvisCoreTests/ConfigTests.swift`

```swift
import XCTest
@testable import JarvisCore

final class ConfigTests: XCTestCase {
    func testDefaults() {
        let c = Config.default
        XCTAssertEqual(c.silenceTimeoutSeconds, 8)
        XCTAssertEqual(c.cooldownSeconds, 12)
        XCTAssertEqual(c.maxInterjectionsPerMinute, 4)
        XCTAssertEqual(c.transcriptWindowSeconds, 90)
        XCTAssertEqual(c.sentenceDisplaySeconds, 5)
        XCTAssertEqual(c.maxSentences, 3)
        XCTAssertEqual(c.brainModel, "gpt-5.5")
        XCTAssertEqual(c.transcriptionModel, "gpt-realtime-2")
    }

    func testEnvSecretStoreReadsKey() {
        let store = EnvSecretStore(environment: ["OPENAI_API_KEY": "sk-test"])
        XCTAssertEqual(store.apiKey(), "sk-test")
    }

    func testEnvSecretStoreMissingKey() {
        let store = EnvSecretStore(environment: [:])
        XCTAssertNil(store.apiKey())
    }
}
```

- [ ] **Step 2: Run to verify fail** — Run: `swift test --filter ConfigTests` — Expected: FAIL (no `Config`).

- [ ] **Step 3: Implement `Sources/JarvisCore/Config.swift`**

```swift
import Foundation

/// All tunables from specification.md §5. Plain values; tune freely.
public struct Config: Sendable {
    public var silenceTimeoutSeconds: TimeInterval
    public var cooldownSeconds: TimeInterval
    public var maxInterjectionsPerMinute: Int
    public var transcriptWindowSeconds: TimeInterval
    public var sentenceDisplaySeconds: TimeInterval
    public var maxSentences: Int
    public var brainModel: String
    public var transcriptionModel: String

    public init(
        silenceTimeoutSeconds: TimeInterval = 8,
        cooldownSeconds: TimeInterval = 12,
        maxInterjectionsPerMinute: Int = 4,
        transcriptWindowSeconds: TimeInterval = 90,
        sentenceDisplaySeconds: TimeInterval = 5,
        maxSentences: Int = 3,
        brainModel: String = "gpt-5.5",
        transcriptionModel: String = "gpt-realtime-2"
    ) {
        self.silenceTimeoutSeconds = silenceTimeoutSeconds
        self.cooldownSeconds = cooldownSeconds
        self.maxInterjectionsPerMinute = maxInterjectionsPerMinute
        self.transcriptWindowSeconds = transcriptWindowSeconds
        self.sentenceDisplaySeconds = sentenceDisplaySeconds
        self.maxSentences = maxSentences
        self.brainModel = brainModel
        self.transcriptionModel = transcriptionModel
    }

    public static let `default` = Config()
}
```

> **Model IDs note:** `gpt-5.5` and `gpt-realtime-2` are the project's assumed IDs (specification.md §5). They are configurable constants here precisely because they must be confirmed against live OpenAI docs at run time; if an ID is wrong the user edits `Config` — no code change needed.

- [ ] **Step 4: Implement `Sources/JarvisCore/Secrets.swift`**

```swift
import Foundation
import Security

/// Source of the OpenAI API key. Keychain is primary (spec §5); env is a headless fallback.
public protocol SecretStore {
    func apiKey() -> String?
}

/// Reads OPENAI_API_KEY from a provided environment dictionary (defaults to the process env).
public struct EnvSecretStore: SecretStore {
    private let environment: [String: String]
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }
    public func apiKey() -> String? {
        guard let v = environment["OPENAI_API_KEY"], !v.isEmpty else { return nil }
        return v
    }
}

/// Reads/writes the key in the macOS login Keychain as a generic password.
public struct KeychainSecretStore: SecretStore {
    private let service: String
    private let account: String
    public init(service: String = "com.jarvis.coach", account: String = "openai-api-key") {
        self.service = service
        self.account = account
    }

    public func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    public func setApiKey(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Tries each store in order; first non-nil wins. App uses [Keychain, Env].
public struct ChainedSecretStore: SecretStore {
    private let stores: [SecretStore]
    public init(_ stores: [SecretStore]) { self.stores = stores }
    public func apiKey() -> String? {
        for s in stores { if let k = s.apiKey() { return k } }
        return nil
    }
}
```

- [ ] **Step 5: Run tests to verify pass** — Run: `swift test --filter ConfigTests` — Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/JarvisCore/Config.swift Sources/JarvisCore/Secrets.swift Tests/JarvisCoreTests/ConfigTests.swift
git commit -m "feat(core): Config tunables + SecretStore (Keychain + env fallback)"
```

---

## Task 2: Rolling timestamped transcript

**Files:**
- Create: `Sources/JarvisCore/Transcript.swift`
- Create: `Tests/JarvisCoreTests/TranscriptTests.swift`

- [ ] **Step 1: Write failing test** — `Tests/JarvisCoreTests/TranscriptTests.swift`

```swift
import XCTest
@testable import JarvisCore

final class TranscriptTests: XCTestCase {
    func testWindowFiltersByAgeAndFormatsTimestamps() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "let me read the problem", at: 0))
        t.append(.init(speaker: .me, text: "maybe a hash map", at: 102))   // 01:42
        // window of 90s relative to now=120 keeps only the second line
        let rendered = t.renderWindow(seconds: 90, now: 120)
        XCTAssertFalse(rendered.contains("read the problem"))
        XCTAssertTrue(rendered.contains("[01:42] me: maybe a hash map"))
    }

    func testSilenceDurationFromLastLine() {
        let t = RollingTranscript()
        t.append(.init(speaker: .me, text: "hmm", at: 50))
        XCTAssertEqual(t.silenceDuration(now: 70), 20, accuracy: 0.001)
    }

    func testSilenceDurationWhenEmptyIsZero() {
        let t = RollingTranscript()
        XCTAssertEqual(t.silenceDuration(now: 70), 0, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run to verify fail** — Run: `swift test --filter TranscriptTests` — Expected: FAIL.

- [ ] **Step 3: Implement `Sources/JarvisCore/Transcript.swift`**

```swift
import Foundation

public enum Speaker: String, Sendable {
    case me        // the user thinking aloud (mic)
    case them      // the other side of a call (system audio)
}

public struct TranscriptLine: Sendable {
    public let speaker: Speaker
    public let text: String
    /// Seconds since session start.
    public let at: TimeInterval
    public init(speaker: Speaker, text: String, at: TimeInterval) {
        self.speaker = speaker
        self.text = text
        self.at = at
    }
}

/// Holds the session transcript and renders a recent, timestamped window for the model.
public final class RollingTranscript: @unchecked Sendable {
    private var lines: [TranscriptLine] = []
    private let lock = NSLock()

    public init() {}

    public func append(_ line: TranscriptLine) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
    }

    public var lastSpeechTime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return lines.last?.at
    }

    /// Seconds since the last spoken line (0 if none).
    public func silenceDuration(now: TimeInterval) -> TimeInterval {
        guard let last = lastSpeechTime else { return 0 }
        return max(0, now - last)
    }

    /// A timestamped window: lines within `seconds` of `now`, each `[mm:ss] speaker: text`.
    public func renderWindow(seconds: TimeInterval, now: TimeInterval) -> String {
        lock.lock(); let snapshot = lines; lock.unlock()
        let cutoff = now - seconds
        return snapshot
            .filter { $0.at >= cutoff }
            .map { "[\(Self.stamp($0.at))] \($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
    }

    static func stamp(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
```

- [ ] **Step 4: Run tests to verify pass** — Run: `swift test --filter TranscriptTests` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/JarvisCore/Transcript.swift Tests/JarvisCoreTests/TranscriptTests.swift
git commit -m "feat(core): RollingTranscript with timestamped window + silence duration"
```

---

## Task 3: Trigger types

**Files:**
- Create: `Sources/JarvisCore/Trigger.swift`
- (Tested indirectly via CoachDriver in Task 8.)

- [ ] **Step 1: Implement `Sources/JarvisCore/Trigger.swift`**

```swift
import Foundation

/// Why the coach loop woke up.
public enum TriggerReason: Sendable, Equatable {
    case turnEnd                       // semantic VAD: the speaker finished a thought
    case silence(secondsQuiet: TimeInterval)  // no speech for silenceTimeoutSeconds
}

/// Timing context handed to the model so it can tell "thinking" from "stuck".
public struct TriggerContext: Sendable {
    public let reason: TriggerReason
    public let secondsSinceLastSpeech: TimeInterval
    public let sessionElapsedSeconds: TimeInterval
    public init(reason: TriggerReason, secondsSinceLastSpeech: TimeInterval, sessionElapsedSeconds: TimeInterval) {
        self.reason = reason
        self.secondsSinceLastSpeech = secondsSinceLastSpeech
        self.sessionElapsedSeconds = sessionElapsedSeconds
    }

    /// A one-line natural-language summary appended to the user message.
    public var promptLine: String {
        let elapsed = Int(sessionElapsedSeconds)
        switch reason {
        case .turnEnd:
            return "Trigger: the user just finished speaking. They have been on this problem for \(elapsed)s."
        case .silence(let secs):
            return "Trigger: the user has been silent for \(Int(secs))s. They have been on this problem for \(elapsed)s."
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles** — Run: `swift build` — Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/JarvisCore/Trigger.swift
git commit -m "feat(core): TriggerReason + TriggerContext with prompt summary"
```

---

## Task 4: Guardrails (cooldown + rate cap + mute)

**Files:**
- Create: `Sources/JarvisCore/Guardrails.swift`
- Create: `Tests/JarvisCoreTests/GuardrailsTests.swift`

- [ ] **Step 1: Write failing test** — `Tests/JarvisCoreTests/GuardrailsTests.swift`

```swift
import XCTest
@testable import JarvisCore

final class GuardrailsTests: XCTestCase {
    private func makeGuardrails(_ clock: ManualClock) -> Guardrails {
        Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
    }

    func testCooldownSuppressesSecondResponse() {
        let clock = ManualClock(now: 0)
        let g = makeGuardrails(clock)
        XCTAssertTrue(g.allow())
        g.noteSpoke()
        clock.advance(by: 5)            // still inside 12s cooldown
        XCTAssertFalse(g.allow())
        clock.advance(by: 8)            // now 13s > cooldown
        XCTAssertTrue(g.allow())
    }

    func testRateCapBlocksFifthInOneMinute() {
        let clock = ManualClock(now: 0)
        let g = makeGuardrails(clock)
        for _ in 0..<4 {
            XCTAssertTrue(g.allow())
            g.noteSpoke()
            clock.advance(by: 13)       // clear cooldown each time; 4 spokes over ~52s
        }
        // 5th within the same rolling minute is blocked by the rate cap
        XCTAssertFalse(g.allow())
    }

    func testRateCapWindowSlides() {
        let clock = ManualClock(now: 0)
        let g = makeGuardrails(clock)
        for _ in 0..<4 { XCTAssertTrue(g.allow()); g.noteSpoke(); clock.advance(by: 13) }
        clock.advance(by: 60)           // old interjections fall out of the 60s window
        XCTAssertTrue(g.allow())
    }

    func testMuteSuppressesEverything() {
        let clock = ManualClock(now: 0)
        let g = makeGuardrails(clock)
        g.setMuted(true)
        XCTAssertFalse(g.allow())
        g.setMuted(false)
        XCTAssertTrue(g.allow())
    }
}
```

- [ ] **Step 2: Run to verify fail** — Run: `swift test --filter GuardrailsTests` — Expected: FAIL.

- [ ] **Step 3: Implement `Sources/JarvisCore/Guardrails.swift`**

```swift
import Foundation

/// Behavioral safety: cooldown between utterances, a rolling per-minute rate cap, and mute.
/// All time comes from an injected Clock so this is fully testable.
public final class Guardrails: @unchecked Sendable {
    private let cooldownSeconds: TimeInterval
    private let maxInterjectionsPerMinute: Int
    private let clock: Clock
    private let lock = NSLock()

    private var lastSpokeAt: TimeInterval?
    private var spokeTimestamps: [TimeInterval] = []
    private var muted = false

    public init(cooldownSeconds: TimeInterval, maxInterjectionsPerMinute: Int, clock: Clock) {
        self.cooldownSeconds = cooldownSeconds
        self.maxInterjectionsPerMinute = maxInterjectionsPerMinute
        self.clock = clock
    }

    public func setMuted(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        muted = value
    }

    public var isMuted: Bool {
        lock.lock(); defer { lock.unlock() }
        return muted
    }

    /// True if a spoken response is permitted right now.
    public func allow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if muted { return false }
        let now = clock.now()
        if let last = lastSpokeAt, now - last < cooldownSeconds { return false }
        let recent = spokeTimestamps.filter { now - $0 < 60 }
        if recent.count >= maxInterjectionsPerMinute { return false }
        return true
    }

    /// Record that a response was spoken; starts the cooldown and counts toward the rate cap.
    public func noteSpoke() {
        lock.lock(); defer { lock.unlock() }
        let now = clock.now()
        lastSpokeAt = now
        spokeTimestamps.append(now)
        spokeTimestamps = spokeTimestamps.filter { now - $0 < 60 }
    }
}
```

- [ ] **Step 4: Run tests to verify pass** — Run: `swift test --filter GuardrailsTests` — Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/JarvisCore/Guardrails.swift Tests/JarvisCoreTests/GuardrailsTests.swift
git commit -m "feat(core): Guardrails — cooldown, rolling rate cap, mute"
```

---

## Task 5: Overlay sentence-splitting

**Files:**
- Create: `Sources/JarvisCore/OverlayText.swift`
- Create: `Tests/JarvisCoreTests/OverlayTextTests.swift`

- [ ] **Step 1: Write failing test** — `Tests/JarvisCoreTests/OverlayTextTests.swift`

```swift
import XCTest
@testable import JarvisCore

final class OverlayTextTests: XCTestCase {
    func testSplitsAndCapsAtThree() {
        let input = "First idea. Second thought! Third point? Fourth dropped."
        let out = splitIntoSentences(input, maxSentences: 3)
        XCTAssertEqual(out, ["First idea.", "Second thought!", "Third point?"])
    }

    func testFewerThanMaxReturnsAll() {
        let out = splitIntoSentences("Only one here.", maxSentences: 3)
        XCTAssertEqual(out, ["Only one here."])
    }

    func testTrimsWhitespaceAndIgnoresEmpty() {
        let out = splitIntoSentences("  Hi.   There.  ", maxSentences: 3)
        XCTAssertEqual(out, ["Hi.", "There."])
    }

    func testNoTerminatorTreatedAsOneSentence() {
        let out = splitIntoSentences("no terminator here", maxSentences: 3)
        XCTAssertEqual(out, ["no terminator here"])
    }
}
```

- [ ] **Step 2: Run to verify fail** — Run: `swift test --filter OverlayTextTests` — Expected: FAIL.

- [ ] **Step 3: Implement `Sources/JarvisCore/OverlayText.swift`**

```swift
import Foundation

/// What the overlay needs to do; the real NSPanel impl lives in JarvisApp.
public protocol OverlayRendering: AnyObject {
    /// Render up to `maxSentences`, each shown for `perSentenceSeconds`.
    func render(_ text: String, maxSentences: Int, perSentenceSeconds: TimeInterval)
}

/// Split text into sentences on . ! ? boundaries, trim, drop empties, cap at maxSentences.
public func splitIntoSentences(_ text: String, maxSentences: Int) -> [String] {
    var sentences: [String] = []
    var current = ""
    for ch in text {
        current.append(ch)
        if ch == "." || ch == "!" || ch == "?" {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            current = ""
        }
    }
    let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty { sentences.append(tail) }
    return Array(sentences.prefix(maxSentences))
}
```

- [ ] **Step 4: Run tests to verify pass** — Run: `swift test --filter OverlayTextTests` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/JarvisCore/OverlayText.swift Tests/JarvisCoreTests/OverlayTextTests.swift
git commit -m "feat(core): overlay sentence splitting + OverlayRendering protocol"
```

---

## Task 6: Brain types + tool definitions

**Files:**
- Create: `Sources/JarvisCore/Brain.swift`
- Create: `Sources/JarvisCore/ToolDefs.swift`
- Create: `Tests/JarvisCoreTests/ToolDefsTests.swift`

- [ ] **Step 1: Write failing test** — `Tests/JarvisCoreTests/ToolDefsTests.swift`

```swift
import XCTest
@testable import JarvisCore

final class ToolDefsTests: XCTestCase {
    func testToolNames() {
        XCTAssertEqual(captureScreenTool.name, "capture_screen")
        XCTAssertEqual(speakTool.name, "speak")
    }

    func testSpeakToolRequiresText() {
        XCTAssertTrue(speakTool.parametersJSON.contains("\"text\""))
        XCTAssertTrue(speakTool.parametersJSON.contains("\"required\""))
    }

    func testCoachPromptMentionsCaptureAndBrevity() {
        XCTAssertTrue(coachSystemPrompt.contains("capture_screen"))
        XCTAssertTrue(coachSystemPrompt.lowercased().contains("3"))
    }
}
```

- [ ] **Step 2: Run to verify fail** — Run: `swift test --filter ToolDefsTests` — Expected: FAIL.

- [ ] **Step 3: Implement `Sources/JarvisCore/Brain.swift`**

```swift
import Foundation

/// A message in the brain conversation. Minimal, provider-agnostic; the real client maps it.
public struct ChatMessage: Sendable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public let role: Role
    public let text: String?
    /// Base64-encoded JPEG, for feeding a screenshot back to a vision model (user role).
    public let imageBase64JPEG: String?
    /// For tool-result messages: which tool call this answers.
    public let toolCallId: String?

    public init(role: Role, text: String? = nil, imageBase64JPEG: String? = nil, toolCallId: String? = nil) {
        self.role = role
        self.text = text
        self.imageBase64JPEG = imageBase64JPEG
        self.toolCallId = toolCallId
    }

    public static func system(_ t: String) -> ChatMessage { .init(role: .system, text: t) }
    public static func user(_ t: String) -> ChatMessage { .init(role: .user, text: t) }
    public static func userImage(_ base64JPEG: String) -> ChatMessage { .init(role: .user, imageBase64JPEG: base64JPEG) }
}

/// A tool definition exposed to the model.
public struct ToolDef: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema for parameters, as a JSON string.
    public let parametersJSON: String
    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// A tool call the model wants the harness to perform.
public enum ToolInvocation: Sendable, Equatable {
    case captureScreen(callId: String)
    case speak(callId: String, text: String)
}

/// One brain response: any tool calls it made (possibly empty = stay silent).
public struct BrainResponse: Sendable {
    public let toolCalls: [ToolInvocation]
    public init(toolCalls: [ToolInvocation]) { self.toolCalls = toolCalls }
}

/// Abstraction over the brain model so CoachDriver is testable with a mock.
public protocol BrainClient: Sendable {
    func respond(messages: [ChatMessage], tools: [ToolDef]) async throws -> BrainResponse
}
```

- [ ] **Step 4: Implement `Sources/JarvisCore/ToolDefs.swift`**

```swift
import Foundation

public let captureScreenTool = ToolDef(
    name: "capture_screen",
    description: "Take a screenshot of the user's active display to see the LeetCode problem and their code. Call this only when you need to see the screen to give a useful, specific tip. Returns an image.",
    parametersJSON: #"{"type":"object","properties":{},"required":[]}"#
)

public let speakTool = ToolDef(
    name: "speak",
    description: "Say a short coaching tip to the user via the on-screen overlay. Use at most 3 short sentences. Only call this when you have something genuinely useful to add; otherwise do not call any tool (stay silent).",
    parametersJSON: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#
)

public let coachTools: [ToolDef] = [captureScreenTool, speakTool]

/// The only behavior in the MVP (specification.md §4).
public let coachSystemPrompt = """
You are Jarvis, a calm, sharp LeetCode coach sitting beside the user while they solve a problem.
You hear them think aloud. You cannot see their screen unless you call capture_screen — do that
when you need to read the problem or their code to be specific and correct.

You are given timing context: a timestamped transcript, how many seconds the user has been silent,
and how long they have been on the problem. Use it. A long silence often means they are stuck and
a gentle nudge would help — but not always; sometimes they are thinking productively and should be
left alone. Judge from what they last said and how long they have been quiet.

Your job: nudge them toward the solution with short, encouraging, specific hints. Never dump the
full solution unless they are truly stuck and ask for it. Prefer asking a pointed question or
pointing at the next small step (e.g. "What's the time complexity of that nested loop?").

Speak only when it helps. If they are making good progress, stay silent — call no tool. When you
do speak, call the speak tool with at most 3 short sentences.
"""
```

- [ ] **Step 5: Run tests to verify pass** — Run: `swift test --filter ToolDefsTests` — Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/JarvisCore/Brain.swift Sources/JarvisCore/ToolDefs.swift Tests/JarvisCoreTests/ToolDefsTests.swift
git commit -m "feat(core): brain message/tool types + tool defs + coach prompt"
```

---

## Task 7: Screen-capture wrapper

**Files:**
- Create: `Sources/JarvisCore/ScreenCapture.swift`
- (Real execution needs Screen-Recording TCC; tested via a fake in Task 8.)

- [ ] **Step 1: Implement `Sources/JarvisCore/ScreenCapture.swift`**

```swift
import Foundation

/// Returns a screenshot of the active display as base64-encoded JPEG, or nil on failure.
public protocol ScreenCapturing: Sendable {
    func capture() -> String?
}

/// Uses the built-in `screencapture -x -t jpg` (silent). The active display only.
/// NOTE: excluding Jarvis's own overlay window is handled by the overlay being a
/// non-capturable panel (sharingType .none) in JarvisApp; see OverlayPanel.
public struct ScreenCaptureCLI: ScreenCapturing {
    public init() {}

    public func capture() -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-t", "jpg", tmp.path]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }
        guard proc.terminationStatus == 0,
              let data = try? Data(contentsOf: tmp) else { return nil }
        return data.base64EncodedString()
    }
}
```

- [ ] **Step 2: Build to verify it compiles** — Run: `swift build` — Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/JarvisCore/ScreenCapture.swift
git commit -m "feat(core): ScreenCapturing protocol + screencapture CLI impl"
```

---

## Task 8: CoachDriver + offline pipeline test

This is the heart of the harness and the spec's offline pipeline test (§8).

**Files:**
- Create: `Sources/JarvisCore/CoachDriver.swift`
- Create: `Tests/JarvisCoreTests/CoachDriverPipelineTests.swift`

- [ ] **Step 1: Write failing test** — `Tests/JarvisCoreTests/CoachDriverPipelineTests.swift`

```swift
import XCTest
@testable import JarvisCore

/// Mock brain: first response asks for the screen, second speaks. Records the messages it saw.
final class ScriptedBrain: BrainClient, @unchecked Sendable {
    private(set) var calls: [[ChatMessage]] = []
    let script: [BrainResponse]
    init(script: [BrainResponse]) { self.script = script }
    func respond(messages: [ChatMessage], tools: [ToolDef]) async throws -> BrainResponse {
        calls.append(messages)
        return script[min(calls.count - 1, script.count - 1)]
    }
}

final class FakeScreen: ScreenCapturing, @unchecked Sendable {
    var captureCount = 0
    let payload: String
    init(payload: String = "ZmFrZS1qcGVn") { self.payload = payload } // "fake-jpeg"
    func capture() -> String? { captureCount += 1; return payload }
}

final class FakeOverlay: OverlayRendering, @unchecked Sendable {
    var rendered: [String] = []
    func render(_ text: String, maxSentences: Int, perSentenceSeconds: TimeInterval) {
        rendered.append(text)
    }
}

final class CoachDriverPipelineTests: XCTestCase {
    func makeDriver(brain: BrainClient, screen: ScreenCapturing, overlay: OverlayRendering, clock: Clock)
        -> (CoachDriver, RollingTranscript) {
        let transcript = RollingTranscript()
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        let driver = CoachDriver(
            config: .default, transcript: transcript, guardrails: guardrails,
            brain: brain, screen: screen, overlay: overlay, clock: clock
        )
        return (driver, transcript)
    }

    func testCaptureThenSpeakPipeline() async {
        let clock = ManualClock(now: 100)
        let brain = ScriptedBrain(script: [
            .init(toolCalls: [.captureScreen(callId: "c1")]),
            .init(toolCalls: [.speak(callId: "s1", text: "What's the complexity of that nested loop?")]),
        ])
        let screen = FakeScreen()
        let overlay = FakeOverlay()
        let (driver, transcript) = makeDriver(brain: brain, screen: screen, overlay: overlay, clock: clock)
        transcript.append(.init(speaker: .me, text: "I'll brute-force two-sum with a double loop", at: 100))

        await driver.handleTrigger(.turnEnd)

        XCTAssertEqual(screen.captureCount, 1, "model asked for the screen once")
        XCTAssertEqual(overlay.rendered, ["What's the complexity of that nested loop?"])
        // Second brain call must contain the screenshot image we fed back
        XCTAssertTrue(brain.calls.count == 2)
        XCTAssertTrue(brain.calls[1].contains { $0.imageBase64JPEG != nil })
    }

    func testStaySilentRendersNothing() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [])])
        let overlay = FakeOverlay()
        let (driver, _) = makeDriver(brain: brain, screen: FakeScreen(), overlay: overlay, clock: clock)
        await driver.handleTrigger(.turnEnd)
        XCTAssertTrue(overlay.rendered.isEmpty)
    }

    func testMuteSuppressesPipeline() async {
        let clock = ManualClock(now: 0)
        let brain = ScriptedBrain(script: [.init(toolCalls: [.speak(callId: "s1", text: "hi")])])
        let overlay = FakeOverlay()
        let guardrails = Guardrails(cooldownSeconds: 12, maxInterjectionsPerMinute: 4, clock: clock)
        guardrails.setMuted(true)
        let driver = CoachDriver(config: .default, transcript: RollingTranscript(),
                                 guardrails: guardrails, brain: brain,
                                 screen: FakeScreen(), overlay: overlay, clock: clock)
        await driver.handleTrigger(.turnEnd)
        XCTAssertTrue(overlay.rendered.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify fail** — Run: `swift test --filter CoachDriverPipelineTests` — Expected: FAIL (no `CoachDriver`).

- [ ] **Step 3: Implement `Sources/JarvisCore/CoachDriver.swift`**

```swift
import Foundation

/// The event loop. On a trigger, enforces guardrails, calls the brain with the timestamped
/// transcript + timing context and the tool set, and routes tool calls (capture_screen, speak).
/// All judgment lives in the model; this just wires events to tool calls and enforces safety.
public final class CoachDriver: @unchecked Sendable {
    private let config: Config
    private let transcript: RollingTranscript
    private let guardrails: Guardrails
    private let brain: BrainClient
    private let screen: ScreenCapturing
    private let overlay: OverlayRendering
    private let clock: Clock
    private let sessionStart: TimeInterval

    /// Optional hook for the menu-bar session counter.
    public var onSpoke: (@Sendable () -> Void)?

    /// Safety backstop against a pathological model that loops on capture_screen forever.
    private let maxToolIterations = 4

    public init(config: Config, transcript: RollingTranscript, guardrails: Guardrails,
                brain: BrainClient, screen: ScreenCapturing, overlay: OverlayRendering, clock: Clock) {
        self.config = config
        self.transcript = transcript
        self.guardrails = guardrails
        self.brain = brain
        self.screen = screen
        self.overlay = overlay
        self.clock = clock
        self.sessionStart = clock.now()
    }

    public func handleTrigger(_ reason: TriggerReason) async {
        guard guardrails.allow() else { return }

        let now = clock.now()
        let ctx = TriggerContext(
            reason: reason,
            secondsSinceLastSpeech: transcript.silenceDuration(now: now),
            sessionElapsedSeconds: now - sessionStart
        )

        var convo: [ChatMessage] = [
            .system(coachSystemPrompt),
            .user("""
            Recent transcript (timestamped):
            \(transcript.renderWindow(seconds: config.transcriptWindowSeconds, now: now))

            \(ctx.promptLine)
            """),
        ]

        var iterations = 0
        while iterations < maxToolIterations {
            iterations += 1
            let response: BrainResponse
            do {
                response = try await brain.respond(messages: convo, tools: coachTools)
            } catch {
                return // network/model error: fail silent this turn
            }

            // No tool call → stay silent.
            guard let call = response.toolCalls.first else { return }

            switch call {
            case .captureScreen(let callId):
                if let img = screen.capture() {
                    convo.append(.init(role: .tool, text: "screenshot captured", toolCallId: callId))
                    convo.append(.userImage(img))
                } else {
                    convo.append(.init(role: .tool, text: "screenshot failed", toolCallId: callId))
                }
                continue // let the model reason over the image

            case .speak(_, let text):
                // Re-check guardrails right before emitting (state may have changed during await).
                guard guardrails.allow() else { return }
                overlay.render(text, maxSentences: config.maxSentences,
                               perSentenceSeconds: config.sentenceDisplaySeconds)
                guardrails.noteSpoke()
                onSpoke?()
                return
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify pass** — Run: `swift test --filter CoachDriverPipelineTests` — Expected: PASS (3 tests). Then full `swift test` — Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/JarvisCore/CoachDriver.swift Tests/JarvisCoreTests/CoachDriverPipelineTests.swift
git commit -m "feat(core): CoachDriver tool-loop + offline pipeline test"
```

---

## Task 9: Real OpenAI brain client (Chat Completions)

**Files:**
- Create: `Sources/JarvisCore/OpenAIBrainClient.swift`
- Create: `Tests/JarvisCoreTests/OpenAIBrainClientTests.swift`

Implements `BrainClient` against `POST /v1/chat/completions` with function tools and image content parts. Network calls are injected via a `URLSession`-like sender so request encoding and response decoding are unit-tested without hitting the network.

- [ ] **Step 1: Write failing test** — `Tests/JarvisCoreTests/OpenAIBrainClientTests.swift`

```swift
import XCTest
@testable import JarvisCore

final class OpenAIBrainClientTests: XCTestCase {
    func testDecodesSpeakToolCall() async throws {
        let json = """
        {"choices":[{"message":{"tool_calls":[
          {"id":"call_1","type":"function","function":{"name":"speak","arguments":"{\\"text\\":\\"Try a hash map.\\"}"}}
        ]}}]}
        """
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), 200) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        XCTAssertEqual(resp.toolCalls, [.speak(callId: "call_1", text: "Try a hash map.")])
    }

    func testDecodesCaptureScreenToolCall() async throws {
        let json = """
        {"choices":[{"message":{"tool_calls":[
          {"id":"c9","type":"function","function":{"name":"capture_screen","arguments":"{}"}}
        ]}}]}
        """
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), 200) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        XCTAssertEqual(resp.toolCalls, [.captureScreen(callId: "c9")])
    }

    func testNoToolCallsMeansSilent() async throws {
        let json = #"{"choices":[{"message":{"content":"(thinking)"}}]}"#
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data(json.utf8), 200) })
        let resp = try await client.respond(messages: [.user("hi")], tools: coachTools)
        XCTAssertTrue(resp.toolCalls.isEmpty)
    }

    func testHttpErrorThrows() async {
        let client = OpenAIBrainClient(apiKey: "sk-x", model: "gpt-5.5",
                                       send: { _ in (Data("nope".utf8), 500) })
        do { _ = try await client.respond(messages: [.user("hi")], tools: coachTools); XCTFail("should throw") }
        catch {}
    }
}
```

- [ ] **Step 2: Run to verify fail** — Run: `swift test --filter OpenAIBrainClientTests` — Expected: FAIL.

- [ ] **Step 3: Implement `Sources/JarvisCore/OpenAIBrainClient.swift`**

```swift
import Foundation

public struct OpenAIBrainClient: BrainClient, @unchecked Sendable {
    public typealias Sender = @Sendable (URLRequest) async throws -> (Data, Int)

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let send: Sender

    /// `send` defaults to URLSession; tests inject a stub returning (body, statusCode).
    public init(apiKey: String,
                model: String,
                endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
                send: Sender? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.send = send ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, code)
        }
    }

    public func respond(messages: [ChatMessage], tools: [ToolDef]) async throws -> BrainResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encodeBody(messages: messages, tools: tools)

        let (data, status) = try await send(request)
        guard (200..<300).contains(status) else {
            throw NSError(domain: "OpenAIBrainClient", code: status,
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "http \(status)"])
        }
        return try decode(data)
    }

    // MARK: - Encoding

    private func encodeBody(messages: [ChatMessage], tools: [ToolDef]) throws -> Data {
        var msgs: [[String: Any]] = []
        for m in messages {
            switch m.role {
            case .system, .assistant:
                msgs.append(["role": m.role.rawValue, "content": m.text ?? ""])
            case .user:
                if let img = m.imageBase64JPEG {
                    msgs.append([
                        "role": "user",
                        "content": [["type": "image_url",
                                     "image_url": ["url": "data:image/jpeg;base64,\(img)"]]],
                    ])
                } else {
                    msgs.append(["role": "user", "content": m.text ?? ""])
                }
            case .tool:
                msgs.append(["role": "tool",
                             "tool_call_id": m.toolCallId ?? "",
                             "content": m.text ?? ""])
            }
        }
        let toolsJSON: [[String: Any]] = try tools.map { t in
            let params = try JSONSerialization.jsonObject(with: Data(t.parametersJSON.utf8))
            return ["type": "function",
                    "function": ["name": t.name, "description": t.description, "parameters": params]]
        }
        let body: [String: Any] = [
            "model": model,
            "messages": msgs,
            "tools": toolsJSON,
            "tool_choice": "auto",
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Decoding

    private struct Response: Decodable {
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let tool_calls: [ToolCall]? }
        struct ToolCall: Decodable {
            let id: String
            let function: Function
        }
        struct Function: Decodable { let name: String; let arguments: String }
        let choices: [Choice]
    }

    private func decode(_ data: Data) throws -> BrainResponse {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let calls = decoded.choices.first?.message.tool_calls else {
            return BrainResponse(toolCalls: [])
        }
        var invocations: [ToolInvocation] = []
        for c in calls {
            switch c.function.name {
            case "capture_screen":
                invocations.append(.captureScreen(callId: c.id))
            case "speak":
                let text = (try? JSONDecoder().decode([String: String].self,
                                                      from: Data(c.function.arguments.utf8)))?["text"] ?? ""
                invocations.append(.speak(callId: c.id, text: text))
            default:
                break
            }
        }
        return BrainResponse(toolCalls: invocations)
    }
}
```

- [ ] **Step 4: Run tests to verify pass** — Run: `swift test --filter OpenAIBrainClientTests` — Expected: PASS (4 tests). Then full `swift test`.

- [ ] **Step 5: Commit**

```bash
git add Sources/JarvisCore/OpenAIBrainClient.swift Tests/JarvisCoreTests/OpenAIBrainClientTests.swift
git commit -m "feat(core): OpenAIBrainClient over Chat Completions (tools + vision)"
```

---

## Task 10: App shell — overlay, menu bar, bootstrap (compiles + launches)

**Files:**
- Modify: `Sources/JarvisApp/main.swift`
- Create: `Sources/JarvisApp/AppDelegate.swift`
- Create: `Sources/JarvisApp/OverlayPanel.swift`
- Create: `Sources/JarvisApp/MenuBarController.swift`

This task has no unit tests (AppKit + main-thread + windowing). Verification = it builds and launches (Task 14).

- [ ] **Step 1: Implement `Sources/JarvisApp/OverlayPanel.swift`**

```swift
import AppKit
import JarvisCore

/// A non-activating, always-on-top panel that shows coaching sentences one at a time and is
/// excluded from screen capture (so the model never sees Jarvis's own output).
final class OverlayPanel: NSObject, OverlayRendering {
    private let panel: NSPanel
    private let label: NSTextField
    private var hideWorkItem: DispatchWorkItem?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 80),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.78)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Exclude from screen capture so capture_screen never sees the overlay.
        panel.sharingType = .none

        label = NSTextField(wrappingLabelWithString: "")
        label.textColor = .white
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false

        let content = panel.contentView!
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        super.init()
        positionBottomCenter()
    }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let w: CGFloat = 520, h: CGFloat = 80
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.minY + 80, width: w, height: h), display: true)
    }

    /// OverlayRendering: split into sentences and show each in turn.
    func render(_ text: String, maxSentences: Int, perSentenceSeconds: TimeInterval) {
        let sentences = splitIntoSentences(text, maxSentences: maxSentences)
        guard !sentences.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.show(sentences, each: perSentenceSeconds) }
    }

    private func show(_ sentences: [String], each: TimeInterval) {
        hideWorkItem?.cancel()
        var idx = 0
        func next() {
            guard idx < sentences.count else { hide(); return }
            label.stringValue = sentences[idx]
            panel.orderFrontRegardless()
            idx += 1
            let work = DispatchWorkItem(block: next)
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + each, execute: work)
        }
        next()
    }

    private func hide() { panel.orderOut(nil) }
}
```

- [ ] **Step 2: Implement `Sources/JarvisApp/MenuBarController.swift`**

```swift
import AppKit
import JarvisCore

/// Menu-bar status item: on/off (mute), API-key entry, and a session token/call counter.
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let guardrails: Guardrails
    private let keychain: KeychainSecretStore
    private let counterItem = NSMenuItem(title: "Interjections: 0", action: nil, keyEquivalent: "")
    private var interjections = 0

    var onMuteChanged: ((Bool) -> Void)?

    init(guardrails: Guardrails, keychain: KeychainSecretStore) {
        self.guardrails = guardrails
        self.keychain = keychain
        super.init()
        statusItem.button?.title = "🟢 Jarvis"
        let menu = NSMenu()
        let mute = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: "m")
        mute.target = self
        menu.addItem(mute)
        let key = NSMenuItem(title: "Set OpenAI API Key…", action: #selector(setKey), keyEquivalent: "k")
        key.target = self
        menu.addItem(key)
        menu.addItem(.separator())
        menu.addItem(counterItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func noteSpoke() {
        interjections += 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.counterItem.title = "Interjections: \(self.interjections)"
        }
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        let nowMuted = !guardrails.isMuted
        guardrails.setMuted(nowMuted)
        sender.state = nowMuted ? .on : .off
        statusItem.button?.title = nowMuted ? "🔇 Jarvis" : "🟢 Jarvis"
        onMuteChanged?(nowMuted)
    }

    @objc private func setKey() {
        let alert = NSAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "Stored in your login Keychain."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            keychain.setApiKey(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
```

- [ ] **Step 3: Implement `Sources/JarvisApp/AppDelegate.swift`** (audio/transcriber wired in Tasks 12–13; this version compiles and runs the menu bar + overlay)

```swift
import AppKit
import JarvisCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let clock = SystemClock()
    private let config = Config.default
    private let transcript = RollingTranscript()
    private lazy var guardrails = Guardrails(
        cooldownSeconds: config.cooldownSeconds,
        maxInterjectionsPerMinute: config.maxInterjectionsPerMinute,
        clock: clock)
    private let keychain = KeychainSecretStore()
    private lazy var secrets = ChainedSecretStore([keychain, EnvSecretStore()])
    private let overlay = OverlayPanel()

    private var menuBar: MenuBarController!
    private var driver: CoachDriver!
    private var transcriber: RealtimeTranscriber?
    private var audio: AudioInput?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar app, no Dock icon

        menuBar = MenuBarController(guardrails: guardrails, keychain: keychain)

        let brain = OpenAIBrainClient(apiKey: secrets.apiKey() ?? "", model: config.brainModel)
        driver = CoachDriver(config: config, transcript: transcript, guardrails: guardrails,
                             brain: brain, screen: ScreenCaptureCLI(), overlay: overlay, clock: clock)
        driver.onSpoke = { [weak self] in self?.menuBar.noteSpoke() }

        startTranscription()
    }

    /// Wired fully in Tasks 12–13. Guarded so the app still launches without audio/key.
    private func startTranscription() {
        guard let key = secrets.apiKey(), !key.isEmpty else {
            NSLog("Jarvis: no API key yet — set it via the menu bar, then relaunch.")
            return
        }
        let transcriber = RealtimeTranscriber(apiKey: key, model: config.transcriptionModel,
                                              transcript: transcript, clock: clock)
        transcriber.onTurnEnd = { [weak self] in
            Task { await self?.driver.handleTrigger(.turnEnd) }
        }
        transcriber.onSilence = { [weak self] secs in
            Task { await self?.driver.handleTrigger(.silence(secondsQuiet: secs)) }
        }
        let audio = AudioInput(captureSystemAudio: true) { [weak transcriber] pcm in
            transcriber?.sendAudio(pcm)
        }
        self.transcriber = transcriber
        self.audio = audio
        transcriber.connect()
        audio.start()
    }
}
```

- [ ] **Step 4: Replace `Sources/JarvisApp/main.swift`**

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 5: Add temporary stubs so the app target compiles before Tasks 12–13.** Create `Sources/JarvisApp/_Stubs.swift` with minimal `AudioInput` and `RealtimeTranscriber` that satisfy the calls in `AppDelegate`. These are REPLACED in Tasks 12–13.

```swift
import Foundation
import JarvisCore

// TEMPORARY — replaced by real implementations in Tasks 12 and 13.
final class AudioInput {
    init(captureSystemAudio: Bool, onPCM: @escaping (Data) -> Void) {}
    func start() {}
    func stop() {}
}

final class RealtimeTranscriber {
    var onTurnEnd: (() -> Void)?
    var onSilence: ((TimeInterval) -> Void)?
    init(apiKey: String, model: String, transcript: RollingTranscript, clock: Clock) {}
    func connect() {}
    func sendAudio(_ pcm: Data) {}
}
```

- [ ] **Step 6: Build to verify it compiles** — Run: `swift build` — Expected: success.

- [ ] **Step 7: Commit**

```bash
git add Sources/JarvisApp
git commit -m "feat(app): overlay panel, menu bar, app bootstrap (audio stubbed)"
```

---

## Task 11: App bundle + ad-hoc sign + launch

**Files:**
- Create: `scripts/build-app.sh`
- Create: `Resources/Info.plist`

- [ ] **Step 1: Create `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Jarvis</string>
  <key>CFBundleDisplayName</key><string>Jarvis</string>
  <key>CFBundleIdentifier</key><string>com.jarvis.coach</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>JarvisApp</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Jarvis listens to you think aloud to offer coaching tips.</string>
</dict>
</plist>
```

> Screen Recording has no Info.plist usage key — macOS prompts on first `ScreenCaptureKit`/`screencapture` use and the grant is managed in System Settings → Privacy. `LSUIElement` makes it a menu-bar-only app.

- [ ] **Step 2: Create `scripts/build-app.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="Jarvis.app"
BIN_NAME="JarvisApp"

echo "▶ swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"

echo "▶ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▶ ad-hoc signing"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

echo "✅ built $APP"
echo "   run: open ./$APP   (or ./$APP/Contents/MacOS/$BIN_NAME for console logs)"
```

- [ ] **Step 3: Make executable and build the app** — Run:

```bash
chmod +x scripts/build-app.sh && ./scripts/build-app.sh release
```

Expected: ends with `✅ built Jarvis.app`, `codesign --verify` prints no errors.

- [ ] **Step 4: Verify it launches headlessly** — Run:

```bash
./Jarvis.app/Contents/MacOS/JarvisApp & sleep 3; kill %1 2>/dev/null; echo "launched-and-exited cleanly"
```

Expected: prints the "no API key yet" NSLog line (no key set in the build env) and a menu-bar item appears; no crash. (A full GUI smoke is in the human checklist.)

- [ ] **Step 5: Commit**

```bash
git add scripts/build-app.sh Resources/Info.plist
git commit -m "build: app bundle assembly + ad-hoc sign script"
```

---

## Task 12: AudioInput — mic + system audio

**Files:**
- Delete `AudioInput` from `Sources/JarvisApp/_Stubs.swift`
- Create: `Sources/JarvisApp/AudioInput.swift`

Captures mic via AVFoundation and (best-effort) system audio via ScreenCaptureKit, delivering 16-kHz mono PCM16 `Data` chunks to a callback. **Live behavior is deferred to the human smoke run**; this task's bar is "compiles and starts without crashing."

- [ ] **Step 1: Remove the `AudioInput` stub** from `_Stubs.swift` (leave the `RealtimeTranscriber` stub until Task 13).

- [ ] **Step 2: Implement `Sources/JarvisApp/AudioInput.swift`**

```swift
import AVFoundation
import JarvisCore

/// Mic capture via AVAudioEngine, downsampled to 16 kHz mono PCM16, delivered as Data chunks.
/// System-audio capture (the "them" side) is a follow-on; mic is the critical path (spec §6).
final class AudioInput {
    private let engine = AVAudioEngine()
    private let onPCM: (Data) -> Void
    private let captureSystemAudio: Bool
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 16_000, channels: 1, interleaved: true)!

    init(captureSystemAudio: Bool, onPCM: @escaping (Data) -> Void) {
        self.onPCM = onPCM
        self.captureSystemAudio = captureSystemAudio
    }

    func start() {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inFormat, to: targetFormat) else {
            NSLog("Jarvis audio: cannot create converter"); return
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = self.targetFormat.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else { return }
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                status.pointee = .haveData; return buffer
            }
            if let err { NSLog("Jarvis audio convert error: \(err)"); return }
            if let data = out.int16Data() { self.onPCM(data) }
        }
        do { try engine.start() } catch { NSLog("Jarvis audio: engine start failed: \(error)") }
        // System-audio tap (ScreenCaptureKit) is set up lazily by RealtimeTranscriber consumers later.
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

private extension AVAudioPCMBuffer {
    /// Raw little-endian PCM16 bytes for the filled frames.
    func int16Data() -> Data? {
        guard let ch = int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(frameLength) * MemoryLayout<Int16>.size)
    }
}
```

> System-audio (ScreenCaptureKit `SCStream` with `capturesAudio = true`) is the first feature cut if it threatens the timeline (spec §6). It is left as a documented extension point in this file rather than blocking the mic path. If implemented, it feeds the same `onPCM` with a `.them` speaker tag.

- [ ] **Step 3: Build to verify it compiles** — Run: `swift build` — Expected: success. Re-run `./scripts/build-app.sh release` — Expected: builds.

- [ ] **Step 4: Commit**

```bash
git add Sources/JarvisApp/AudioInput.swift Sources/JarvisApp/_Stubs.swift
git commit -m "feat(app): AudioInput — mic capture → 16kHz PCM16 chunks"
```

---

## Task 13: RealtimeTranscriber — gpt-realtime-2 websocket

**Files:**
- Delete `RealtimeTranscriber` from `Sources/JarvisApp/_Stubs.swift` (file now empty → delete it)
- Create: `Sources/JarvisApp/RealtimeTranscriber.swift`

Streams PCM audio to the OpenAI Realtime API over a websocket, appends transcribed lines to `RollingTranscript`, and emits `onTurnEnd` (semantic VAD) and `onSilence` events. **Live behavior deferred to the human smoke run**; bar is "compiles, connects lazily, no crash on construction."

- [ ] **Step 1: Delete the now-empty `_Stubs.swift`** (after removing both stubs).

- [ ] **Step 2: Implement `Sources/JarvisApp/RealtimeTranscriber.swift`**

```swift
import Foundation
import JarvisCore

/// Minimal client for the OpenAI Realtime API (GA). Sends PCM16 audio and parses transcription +
/// turn-detection events. Event/payload shapes must be confirmed against live docs at run time
/// (spec §5 model note) — the IDs/fields here follow the documented Realtime event names.
final class RealtimeTranscriber: NSObject, URLSessionWebSocketDelegate {
    var onTurnEnd: (() -> Void)?
    var onSilence: ((TimeInterval) -> Void)?

    private let apiKey: String
    private let model: String
    private let transcript: RollingTranscript
    private let clock: Clock
    private let sessionStart: TimeInterval

    private var task: URLSessionWebSocketTask?
    private var silenceTimer: Timer?
    private let silenceTimeout: TimeInterval

    init(apiKey: String, model: String, transcript: RollingTranscript, clock: Clock,
         silenceTimeout: TimeInterval = 8) {
        self.apiKey = apiKey
        self.model = model
        self.transcript = transcript
        self.clock = clock
        self.sessionStart = clock.now()
        self.silenceTimeout = silenceTimeout
        super.init()
    }

    func connect() {
        var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta") // header name per GA docs; confirm at run time
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: req)
        self.task = task
        task.resume()
        configureSession()
        receiveLoop()
        resetSilenceTimer()
    }

    /// Enable input-audio transcription + server turn detection.
    private func configureSession() {
        send(json: [
            "type": "session.update",
            "session": [
                "input_audio_format": "pcm16",
                "input_audio_transcription": ["model": model],
                "turn_detection": ["type": "server_vad"],
            ],
        ])
    }

    func sendAudio(_ pcm: Data) {
        send(json: ["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(str)) { err in if let err { NSLog("Jarvis realtime send error: \(err)") } }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                NSLog("Jarvis realtime closed: \(err)")
                return
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "conversation.item.input_audio_transcription.completed":
            if let transcriptText = obj["transcript"] as? String, !transcriptText.isEmpty {
                let at = clock.now() - sessionStart
                transcript.append(.init(speaker: .me, text: transcriptText, at: at))
                resetSilenceTimer()
            }
        case "input_audio_buffer.speech_stopped",
             "response.done":
            DispatchQueue.main.async { [weak self] in self?.onTurnEnd?() }
            resetSilenceTimer()
        default:
            break
        }
    }

    private func resetSilenceTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.silenceTimer?.invalidate()
            self.silenceTimer = Timer.scheduledTimer(withTimeInterval: self.silenceTimeout, repeats: false) { [weak self] _ in
                guard let self else { return }
                let quiet = self.transcript.silenceDuration(now: self.clock.now() - self.sessionStart)
                self.onSilence?(max(self.silenceTimeout, quiet))
            }
        }
    }
}
```

> **Honest limitation:** the exact Realtime event names/headers (`server_vad`, `input_audio_transcription.completed`, the `OpenAI-Beta` header) follow the documented GA shapes but were last confirmed pre-cutoff. They are isolated to this one file and must be checked against live docs during the smoke run. If `gpt-realtime-2` accepts image input, a future simplification merges the brain + transcriber (spec §5 note) — out of scope here.

- [ ] **Step 3: Build to verify it compiles** — Run: `swift build` — Expected: success. Re-run `./scripts/build-app.sh release` — Expected: builds + signs.

- [ ] **Step 4: Commit**

```bash
git add Sources/JarvisApp/RealtimeTranscriber.swift
git rm Sources/JarvisApp/_Stubs.swift
git commit -m "feat(app): RealtimeTranscriber websocket → transcript + turn/silence events"
```

---

## Task 14: Full verification pass

**Files:** none (verification + docs).

- [ ] **Step 1: Run the whole test suite** — Run: `swift test` — Expected: ALL tests pass (Clock, Config, Transcript, Guardrails, OverlayText, ToolDefs, OpenAIBrainClient, CoachDriverPipeline).

- [ ] **Step 2: Build the signed app** — Run: `./scripts/build-app.sh release` — Expected: `✅ built Jarvis.app`, codesign verifies.

- [ ] **Step 3: Launch smoke (headless)** — Run:

```bash
./Jarvis.app/Contents/MacOS/JarvisApp & sleep 3; kill %1 2>/dev/null; echo ok
```

Expected: no crash; logs the "no API key" line; process killable.

- [ ] **Step 4: Write `README.md` run instructions** (append a "Running Jarvis" section): how to set the key (menu bar or `OPENAI_API_KEY`), grant Screen Recording + Microphone, and the live smoke steps from spec §8.

- [ ] **Step 5: Final commit**

```bash
git add README.md
git commit -m "docs: how to run Jarvis + live smoke checklist pointer"
```

---

## Live Smoke Checklist (requires the user — deferred)

These cannot be run headlessly; they need a human, a real key, and granted permissions. From [specification.md §8](./specification.md#8-self-verification-plan):

1. Launch `Jarvis.app`; confirm menu-bar icon; grant Screen Recording + Microphone when prompted.
2. Set a real `OPENAI_API_KEY` (menu bar → "Set OpenAI API Key…"), relaunch.
3. **Confirm the model IDs are real** (`gpt-5.5`, `gpt-realtime-2`) against live OpenAI docs; edit `Config` if not.
4. Speak — confirm transcript lines arrive (check Console logs).
5. With a LeetCode problem on screen, say "Jarvis, I'm stuck on two-sum" — expect a coaching overlay within ~2s, and observe a `capture_screen` call.
6. Confirm the screenshot excludes the overlay window.
7. Rapid triggers don't exceed `maxInterjectionsPerMinute`; mute silences output.

---

## Self-Review (completed during planning)

- **Spec coverage:** harness loop (Task 8) ✔; `capture_screen`+`speak` tools (Tasks 6–8) ✔; coach prompt (Task 6) ✔; config tunables (Task 1) ✔; timing/"stuck" context (Tasks 2–3, 8) ✔; audio sources (Task 12; system audio = documented extension) ✔; latency (streaming sentence-by-sentence overlay, Task 10) ✔; unit + offline tests (Tasks 1–9) ✔; live smoke (deferred section) ✔; build/run constraints — SwiftPM+CLT, bundle, ad-hoc sign, TCC (Tasks 0, 11) ✔; Keychain secret (Task 1) ✔.
- **Deferred/■ honest gaps:** real Realtime event shapes (Task 13) and live audio (Task 12) are compile-verified only; system-audio capture is a documented extension, not built; model IDs assumed. All flagged inline.
- **Type consistency:** `BrainClient.respond(messages:tools:)`, `ToolInvocation.{captureScreen,speak}`, `ScreenCapturing.capture()`, `OverlayRendering.render(_:maxSentences:perSentenceSeconds:)`, `Guardrails.{allow,noteSpoke,setMuted,isMuted}`, `RollingTranscript.{append,renderWindow,silenceDuration}` are used identically across tasks.
