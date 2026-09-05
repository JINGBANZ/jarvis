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
from finalized text only, matching today's behavior. Resampling 24 kHz → 16 kHz is lossy for content
above 8 kHz, which is inaudible in speech and irrelevant to recognition.

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

**Sample-rate mismatch.** `TranscriptionAudioFormat.pcm16Mono` is 24 kHz; Gemini Live specifies
`audio/pcm;rate=16000`. Rather than change the shared capture format (which AEC and both existing
providers depend on), Gemini owns a private 24 kHz → 16 kHz `Resampler` per stream. `Resampler`
already exists for the AEC 24↔48 kHz conversion and is documented as one-instance-per-stream because
its filter state must carry across calls.

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
- **Audio frame:** `{"realtimeInput": {"audio": {"data": "<base64 PCM16>", "mimeType": "audio/pcm;rate=16000"}}}`,
  ~100 ms per chunk.
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

```swift
public enum CredentialID: String, CaseIterable, Sendable {
    case openAI = "openai"
    case gemini

    var fileName: String        // "openai-api-key" / "gemini-api-key"
    var environmentVariable: String  // "OPENAI_API_KEY" / "GEMINI_API_KEY"
    var displayName: String     // "OpenAI API" / "Gemini API"
}

public protocol SecretStore {
    func apiKey(for credential: CredentialID) -> String?
}
```

`FileSecretStore` resolves the filename from the credential inside the same
`~/Library/Application Support/Jarvis/` directory, keeping the existing 0700-directory and
atomic 0600-file-creation logic and its rationale comment about avoiding the Keychain.
`EnvSecretStore` reads the matching variable. `ChainedSecretStore` forwards the credential.
Existing call sites (`AppDelegate`, `BrainComposition`, `TranscriptionBenchmarkRunner`) pass
`.openAI`; the OpenAI credential path and file location are unchanged.

`FileSecretStore.fileURL` is currently a stored property used by `SessionArtifacts` and
`BrainComposition` to locate the *directory*, not the key file. It becomes
`fileURL(for: CredentialID)` plus a `directoryURL` those two callers use instead, so the sessions
directory no longer derives from a credential filename.

### Start-time credential gating

`TranscriptionProvider.requiresOpenAIAPIKey(for:)` is misnamed once a second key exists, and its
single-Bool answer cannot express "Gemini ears + OpenAI brain". It is replaced by:

```swift
public func requiredCredentials(for brainRoute: BrainRoute?) -> Set<CredentialID>
```

which unions the provider's own credential (`.gemini` or `.openAI`; Apple Speech contributes none)
with `.openAI` when any authorized brain target is OpenAI. `AppDelegate` fails Start when any
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

### `GeminiLiveTranscriber` (JarvisApp/Capture)

A `TranscriptionSession` conformer owning one WebSocket per speaker stream. Responsibilities:
connect and await setup acknowledgement with a ready timeout; resample 24 → 16 kHz and send base64
frames; parse responses, dropping interim and forwarding final text to
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
- `APIKeyControls` is parameterized by `CredentialID` instead of hardcoding the OpenAI title and
  store call, so one class serves both cards.
- `ConnectionsSection` adds a Gemini key card. Its provider list and the three hardcoded card-height
  arrays in `recalculateDocumentHeight()` become one ordered card list, so the next card does not
  require edits in three places. The "N ready" badge counts saved keys plus signed-in CLIs.

## Testing

swift-testing, mirroring how `RealtimeSession` is covered today. The live socket is not unit-testable
and stays on the smoke checklist.

- `GeminiLiveSession`: setup-message shape for each mode/language/vocabulary combination; empty
  language list omits nothing but sends `[]`; audio frame encoding and mime type; final-vs-interim
  parsing; interim never yields a transcript; error-code → `TranscriptionFailureReason` mapping;
  the connect URL carries the key and diagnostics never do.
- `CredentialID` / `FileSecretStore`: per-credential filenames resolve inside one directory; saving a
  Gemini key leaves the OpenAI key intact; file mode is 0600 and directory 0700; env fallback reads
  the matching variable.
- `requiredCredentials(for:)`: every provider × brain-route combination, including Gemini ears with
  an OpenAI brain target and Apple Speech with CLI-only targets.
- `TranscriptionPreferences`: Gemini values round-trip; unknown stored values fall back to defaults;
  the configuration snapshot carries them.
- Existing OpenAI and Apple Speech tests must pass unchanged — that is the regression guard for the
  credential refactor.

## Rejected alternatives

**Extract a shared streaming-transcriber base first.** Restructuring the 1203-line
`RealtimeTranscriber`, whose live socket cannot be unit-tested, to serve a provider that needs
neither its ledger nor its commit path would risk the primary transcription path for speculative
reuse. If a third streaming provider arrives, extract the base from two working implementations then.

**A dialect switch inside `RealtimeTranscriber`.** Smallest diff, but tangles two wire protocols
inside one class alongside OpenAI-specific item reconciliation state.

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
