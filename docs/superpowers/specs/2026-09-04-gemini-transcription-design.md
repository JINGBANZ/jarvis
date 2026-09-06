# Gemini live transcription

**Status:** approved design, not yet implemented
**Date:** 2026-09-04
**Scope:** add Google Gemini as a third `TranscriptionProvider`, alongside OpenAI Realtime and
Apple Speech.

## Goal

A user can pick **Gemini** in Settings → Brain → Transcription, save a Gemini API key in
Settings → Connections, press Start, and have Jarvis hear the conversation through
`gemini-3.5-transcribe-live` exactly as it does through OpenAI today.

## Non-goals

- Gemini as a **brain** provider. `BrainProvider` is untouched; Gemini supplies ears only.
- The batch `gemini-3.5-transcribe` model. Jarvis is a live coach; only the streaming model applies.
- Migrating the existing OpenAI credential file. Its path and env var are unchanged.
- Extracting a shared streaming-transcriber base class. See "Rejected alternatives".

## Contract

**Expected behavior.** With a saved Gemini key and Gemini selected, Start opens one Gemini Live
socket per speaker stream (mic and system audio), streams PCM16, and appends each finalized
utterance to the transcript with the same batching, silence, and turn-end behavior as the other two
providers.

**Failure behavior.** A missing key blocks Start with the existing pre-flight message, extended to
name whichever credential is missing. A rejected key, exhausted quota, or rejected model surfaces as
a terminal failure through the existing `TranscriptionFailureReason` path and ends the session with
the standard degradation notice. Transient socket loss reconnects with backoff, as OpenAI does.

**Acceptable degradation.** Interim (speculative) transcripts are dropped, not shown — Jarvis coaches
from finalized text only, matching today's behavior. A Gemini session captures at 16 kHz rather than
24 kHz, discarding content above 8 kHz that carries no phonetic information; recognition is
unaffected and per-stream bandwidth drops from 48 to 32 KB/s.

**Completion criteria.** `swift build && ./scripts/run-tests.sh` passes; a live smoke run transcribes
both speaker streams through Gemini; the OpenAI and Apple Speech paths are behaviorally unchanged.

## Findings that shape the design

**Gemini needs far less machinery than OpenAI.** OpenAI Realtime emits per-item events that can
finish out of order, which is why `RealtimeTranscriber.swift` is 1203 lines plus a 289-line
`RealtimeTranscriptionLedger` and a 156-line `RealtimeJarvisManagedTurnCoordinator`. Gemini's socket
emits `interimInputTranscription` (speculative) and `inputTranscription` (final); the server owns
turn boundaries. Gemini therefore needs **no ledger, no turn coordinator, and no client-commit
path**.

**Two components are already provider-neutral and are reused unchanged.**
`TranscriptionCoachingCoordinator` is documented as the "provider-neutral owner for finalized
transcript delivery and the coaching triggers derived from it" and is already shared by both existing
providers; it keeps transcript batching, speech gating, and silence backoff identical.
`RealtimeContinuityReporter` supplies the capture heartbeat.

**The wire sample rate is a provider requirement, not a global constant.**
`TranscriptionAudioFormat.pcm16Mono` is 24 kHz because that is what OpenAI Realtime requires; Gemini
Live requires 16 kHz (`audio/pcm;rate=16000`, fixed — the docs specify raw 16-bit mono
little-endian PCM at 16 kHz with no server-side resampling). Neither rate is an accuracy choice:
speech carries no phonetically relevant energy above 8 kHz, so 16 kHz (8 kHz Nyquist) already covers
every formant and fricative, and ASR models are trained at 16 kHz and downsample internally. 24 kHz
is therefore 1.5× the bytes for no recognition benefit.

This makes the wire format **provider-derived** rather than a shared constant. Capture already
resamples once, at a single point: `AggregateEchoCapture` runs AEC at 48 kHz and downsamples to the
wire rate through `micDown`/`sysDown`. Retargeting those two resamplers to 16 kHz for a Gemini
session gives a single 48 → 16 conversion — an exact 3:1 integer decimation, cheaper and cleaner
than chaining a second 24 → 16 stage at a 2:3 ratio. Provider selection is resolved before capture
begins and frozen for the session (that is what the `TranscriptionConfiguration` Start snapshot is
for), so the target rate is known at capture-build time and never changes mid-session.

## Wire protocol

Verified against Google's Live API transcription guide (2026-09).

- **Endpoint:** `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=<API_KEY>`
  The key is a query parameter, not a header.
- **Setup message**, sent immediately on open; the socket is not usable until acknowledged:
  ```json
  {"setup": {
    "model": "models/gemini-3.5-transcribe-live",
    "generationConfig": {"responseModalities": ["TEXT"]},
    "inputAudioTranscription": {
      "languageCodes": [], "customVocabulary": [], "mode": "VERBATIM"
    }}}
  ```
  Empty `languageCodes` means automatic detection. `customVocabulary` accepts up to 1,000 terms.
  `mode` is `VERBATIM` (raw speech) or `SMART` (filler words removed, output formatted).
- **Audio frame:** `{"realtimeInput": {"audio": {"data": "<base64 PCM16>", "mimeType": "audio/pcm;rate=16000"}}}`.
  Google recommends ~100 ms per chunk (1,024–2,048 frames).
- **Stream end:** `{"realtimeInput": {"audioStreamEnd": true}}`
- **Responses:** `serverContent.interimInputTranscription.text` (dropped) and
  `serverContent.inputTranscription.text` (finalized → transcript).

Putting the key in the URL means it must never reach a log. `GeminiLiveSession.connectURL` is the
only place the key appears, and every diagnostic logs the endpoint without its query string.

## Design

### Credentials — generalize the single-key store

`Secrets.swift` is currently OpenAI-specific end to end: `SecretStore.apiKey()` takes no argument,
`FileSecretStore` hardcodes the filename `openai-api-key`, `EnvSecretStore` hardcodes
`OPENAI_API_KEY`, and one shared `secrets` instance in `AppDelegate` feeds both the brain and
transcription. A second key-based provider makes this a per-credential concern.

A credential-identity enum already exists — `JarvisReadiness.Credential` (`case openAIAPIKey`),
used as Start-gating set identity and never rendered to the user. Rather than adding a parallel type,
it is **promoted** out of the diagnostics type to a top-level `Credential` in
`Sources/JarvisCore/Config/Credential.swift`, gains the Gemini case and its file/env mapping, and
`JarvisReadiness` refers to the promoted type. Raw values are preserved so readiness semantics and
its existing tests are unaffected.

```swift
public enum Credential: String, Sendable, Hashable, CaseIterable {
    case openAIAPIKey        // raw values unchanged from JarvisReadiness.Credential
    case geminiAPIKey

    var fileName: String            // "openai-api-key" / "gemini-api-key"
    var environmentVariable: String // "OPENAI_API_KEY" / "GEMINI_API_KEY"
    var displayName: String         // "OpenAI API" / "Gemini API"
}

public protocol SecretStore {
    func apiKey(for credential: Credential) -> String?
}
```

`FileSecretStore` resolves the filename from the credential inside the same
`~/Library/Application Support/Jarvis/` directory, keeping the existing 0700-directory and
atomic 0600-file-creation logic and its rationale comment about avoiding the Keychain.
`EnvSecretStore` reads the matching variable. `ChainedSecretStore` forwards the credential.
Existing call sites (`AppDelegate`, `BrainComposition`, `TranscriptionBenchmarkRunner`) pass
`.openAIAPIKey`; the OpenAI credential path and file location are unchanged.

`FileSecretStore.fileURL` is currently a stored property used by `SessionArtifacts` and
`BrainComposition` to locate the *directory*, not the key file. It becomes
`fileURL(for: Credential)` plus a `directoryURL` those two callers use instead, so the sessions
directory no longer derives from a credential filename.

### Start-time credential gating

`TranscriptionProvider.requiresOpenAIAPIKey(for:)` is misnamed once a second key exists, and its
single-Bool answer cannot express "Gemini ears + OpenAI brain". It is replaced by:

```swift
public func requiredCredentials(for brainRoute: BrainRoute?) -> Set<Credential>
```

which unions the provider's own credential (`.geminiAPIKey` or `.openAIAPIKey`; Apple Speech
contributes none) with `.openAIAPIKey` when any authorized brain target is OpenAI. Its result feeds
`JarvisReadiness.Configuration.requiredCredentials` directly, replacing the hand-built
`requiresOpenAIKey ? [.openAIAPIKey] : []` in `AppDelegate.start()`. `AppDelegate` fails Start when any
required credential is missing, naming the missing one.

### Transcription types (JarvisCore)

- `TranscriptionProvider` gains `case gemini = "gemini"` with display name `"Gemini"`.
- New `GeminiTranscriptionModel` — one case, `geminiTranscribeLive = "gemini-3.5-transcribe-live"`.
  Modeled on `OpenAITranscriptionModel` so a second Gemini model is a one-line addition.
- New `GeminiTranscriptionMode` — `verbatim` / `smart`, mapping to the wire `mode` field.
- `OpenAITranscriptionLanguage` is renamed `TranscriptionLanguage` (English, Mandarin) and reused for
  both providers. Its `multipleHint` values (`en`, `zh-cn`) are already BCP-47 and serve as Gemini's
  `languageCodes`. The persisted raw values are unchanged, so no stored preference migrates.
- `TranscriptionPreferences` and the immutable `TranscriptionConfiguration` snapshot gain
  `geminiModel`, `geminiExpectedLanguages`, `geminiVocabularyKeywords`, and `geminiMode`, with
  `Defaults.Transcription` keys `transcription.gemini.*` and empty/`verbatim` defaults.
- New pure `GeminiLiveSession` — the unit-testable wire contract, mirroring `RealtimeSession`:
  `connectURL(apiKey:)`, `setupMessage(model:languages:vocabulary:mode:)`, `audioFrame(base64PCM:)`,
  `audioStreamEnd()`, `isSetupComplete(_:)`, `finalTranscript(from:speaker:)`, and
  `terminalFailure(from:)` mapping Gemini error codes onto `TranscriptionFailureReason`.
  It reuses `RealtimeSession.meaningfulTranscript` for hallucination and punctuation-only filtering,
  which is provider-independent — that helper moves to a shared `TranscriptFiltering` type.
- `TranscriptionFailureReason.activityDescription` names OpenAI in four of its six cases ("OpenAI
  rejected the API key…"). That copy is written into the user-facing Activity log, so it becomes
  wrong when Gemini fails. The wording is made provider-neutral ("the transcription provider rejected
  the API key; check Settings → Connections"), keeping these notices fixed strings as
  `ActivityLog`'s contract requires. The provider name stays available in `jarvis-debug.log`.

### Provider-derived wire audio format

`TranscriptionAudioFormat.pcm16Mono` is replaced by two named formats — `pcm16Mono24k` (OpenAI,
Apple Speech) and `pcm16Mono16k` (Gemini) — and `TranscriptionProvider` gains
`var audioFormat: TranscriptionAudioFormat`. The struct itself is unchanged; only the shared
singleton goes away.

`AggregateEchoCapture` takes the format in its initializer and builds `micDown`/`sysDown` against it,
so a Gemini session downsamples 48 → 16 in one step. AEC still runs at 48 kHz regardless.
`AppleSpeechTranscriber` and `RealtimeTranscriber` read the format they were constructed with instead
of the global constant, and `RealtimeSession.sessionUpdate` sends OpenAI's 24 kHz explicitly.

`LocalTurnDetector` is **not** affected: it is constructed with `inputSampleRate: aecRate` (48 kHz,
pre-downsample) and resamples to Silero's own rate, so local turn detection is independent of the
wire rate. `SystemAudioBenchmarkCapture` still captures at a fixed 24 kHz (`pcm16Mono24k`) regardless
of provider; the benchmark harness covers only OpenAI and Apple Speech today, and Gemini benchmark
support is a follow-up.

The two `TranscriptionAudioFormatTests` cases that assert against `pcm16Mono` move to the 24 kHz
format, with a new case covering 16 kHz.

### `GeminiLiveTranscriber` (JarvisApp/Capture)

A `TranscriptionSession` conformer owning one WebSocket per speaker stream. Responsibilities:
connect and await setup acknowledgement with a ready timeout; base64-encode and send the 16 kHz PCM
it already receives from capture (it does no resampling of its own); parse responses, dropping
interim and forwarding final text to
`TranscriptionCoachingCoordinator`; report `TranscriptionConnectionState` edges and capture heartbeat
through `RealtimeContinuityReporter`; reconnect with backoff on transient loss, and report terminal
failures once. It buffers audio while disconnected under the existing
`maxBufferedAudioSeconds` bound, as the other adapters do.

It does **not** implement `recordLocalSpeechEvent` — the protocol's default no-op applies, because
Gemini detects turns server-side.

`TranscriptionSessionFactory.make` gains a `.gemini` case constructing it from the Start snapshot.

### Settings UI (JarvisApp/Settings)

- `TranscriptionControls` already builds its provider popup from `TranscriptionProvider.allCases`, so
  Gemini appears without change there. It gains Gemini rows — model, expected languages, vocabulary,
  and mode — shown when the provider is `.gemini`. `applyState()`/`layoutRows()`/`preferredHeight`
  currently branch on a `provider == .openAI` Bool; they become a per-provider row list, since a
  two-state Bool no longer describes three providers.
- `APIKeyControls` is parameterized by `Credential` instead of hardcoding the OpenAI title and
  store call, so one class serves both cards.
- `ConnectionsSection` adds a Gemini key card. Its provider list and the three hardcoded card-height
  arrays in `recalculateDocumentHeight()` become one ordered card list, so the next card does not
  require edits in three places. The "N ready" badge counts saved keys plus signed-in CLIs.

## Testing

swift-testing, mirroring how `RealtimeSession` is covered today. The live socket is not unit-testable
and stays on the smoke checklist.

- `GeminiLiveSession`: setup-message shape for each mode/language/vocabulary combination; an empty
  language list is sent as `[]` (automatic detection) rather than omitted; audio frame encoding and
  mime type; final-vs-interim parsing; an interim message never yields a transcript; error-code →
  `TranscriptionFailureReason` mapping; the connect URL carries the key and diagnostics never do.
- `Credential` / `FileSecretStore`: per-credential filenames resolve inside one directory; saving a
  Gemini key leaves the OpenAI key intact; file mode is 0600 and directory 0700; env fallback reads
  the matching variable.
- `requiredCredentials(for:)`: every provider × brain-route combination, including Gemini ears with
  an OpenAI brain target and Apple Speech with CLI-only targets.
- `TranscriptionPreferences`: Gemini values round-trip; unknown stored values fall back to defaults;
  the configuration snapshot carries them.
- `TranscriptionProvider.audioFormat`: Gemini reports 16 kHz, OpenAI and Apple Speech 24 kHz; the
  format's derived `bytesPerSecond`/`duration`/`byteCount` are correct at both rates.
- Existing OpenAI and Apple Speech tests must pass unchanged — that is the regression guard for both
  the credential refactor and the audio-format split.

## Rejected alternatives

**Extract a shared streaming-transcriber base first.** Restructuring the 1203-line
`RealtimeTranscriber`, whose live socket cannot be unit-tested, to serve a provider that needs
neither its ledger nor its commit path would risk the primary transcription path for speculative
reuse. If a third streaming provider arrives, extract the base from two working implementations then.

**A dialect switch inside `RealtimeTranscriber`.** Smallest diff, but tangles two wire protocols
inside one class alongside OpenAI-specific item reconciliation state.

**A Gemini-private 24 → 16 kHz resampler, leaving the shared 24 kHz constant alone.** Smaller
blast radius, but it resamples twice (48 → 24 → 16) at a 2:3 ratio when capture can produce 16 kHz
directly with a single exact 3:1 decimation. It also keeps a constant named as if it were
provider-neutral while it actually encodes one provider's requirement.

**Capturing at 16 kHz for every provider.** One rate everywhere would be simpler, but OpenAI Realtime
requires 24 kHz, so this is not available.

**A parallel `GeminiSecretStore`.** Avoids touching brain-side code, but duplicates the
file-permission logic and the key-entry UI, and leaves the next provider with the same choice.

**Free-form BCP-47 language input for Gemini.** Gemini auto-detects 85+ languages, but a text field
needs validation and diverges from the existing picker for no current benefit. Automatic detection
already covers anything outside the two-language list.

## Wiki updates (part of implementation)

`wiki/settings-window.md` (Connections cards, Transcription rows), `wiki/architecture.md` (Models and
APIs — the Gemini wire contract and its turn-detection model), and `wiki/status.md` (provider list and
smoke checklist). Read `wiki/AGENTS.md` before editing. `wiki/transcription-benchmark.md` needs a
check: `TranscriptionBenchmarkRunner` carries `requiredProviders: Set<TranscriptionProvider>`, so the
benchmark harness may need the new case.
