# Gemini Live Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Google Gemini (`gemini-3.5-transcribe-live`) as a third transcription provider, selectable in Settings with its own API key in Connections.

**Architecture:** Gemini slots behind the existing `TranscriptionSession` protocol as a new WebSocket adapter, reusing the already provider-neutral `TranscriptionCoachingCoordinator` and `RealtimeContinuityReporter`. Two shared single-provider assumptions are generalized first: the OpenAI-only secret store becomes per-credential, and the global 24 kHz wire audio format becomes provider-derived. The OpenAI Realtime path is left structurally untouched.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, macOS 14+, swift-testing, `URLSessionWebSocketTask`, AppKit for Settings.

**Spec:** `docs/superpowers/specs/2026-09-04-gemini-transcription-design.md`

## Global Constraints

- **Gate before any completion claim:** `swift build && ./scripts/run-tests.sh`. Never run raw `swift test`.
- **Swift 6 strict concurrency.** No `@unchecked Sendable` or `nonisolated(unsafe)` without a written reason comment. Existing adapters use `@unchecked Sendable` with an explicit "all mutable state guarded by `lock`" note — match that style.
- **One primary type per file.** Focused extensions are named `Type+Purpose.swift`.
- **Secrets never logged.** The Gemini key travels in the WebSocket URL query string; no diagnostic may log a URL with its query. Store keys only in the owner-only `0600` file inside the `0700` Application Support directory.
- **Activity log contract.** `ActivityLog` carries only finalized speech, manual hints, brain actions, and fixed session-end/degradation notices. Retry, transport, timing, and raw-error detail go to `jlog` (`jarvis-debug.log`) only — never mirrored into Activity.
- **Ghost mode.** No new presentation API calls. Every existing one carries an inline `ghost-mode-allowed` reason; do not add more.
- **Conventional Commits**, lowercase imperative: `type(scope): summary`. One logical change per commit.
- **Commit trailer** — append to every commit message:
  ```
  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Diw4AKtt8yvZ5u4zQBSiEX
  ```
- **Wire values, exact:**
  - Endpoint host/path: `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`, key as query item `key`.
  - Model string sent on the wire: `models/gemini-3.5-transcribe-live` (note the `models/` prefix).
  - Audio mime type: `audio/pcm;rate=16000`. Raw 16-bit mono little-endian PCM at 16 kHz.
  - Gemini wire modes: `VERBATIM`, `SMART`.
- **Do not** modify or delete an existing test to make a change pass. If an existing assertion becomes wrong by design, the task says so explicitly and states the new expected value.

---

## File Structure

**Created**
| File | Responsibility |
|---|---|
| `Sources/JarvisCore/Config/Credential.swift` | Credential identity + file/env/display mapping |
| `Sources/JarvisCore/Transcription/TranscriptFiltering.swift` | Provider-neutral hallucination / punctuation-only filter |
| `Sources/JarvisCore/Transcription/GeminiTranscriptionModel.swift` | Gemini model enum |
| `Sources/JarvisCore/Transcription/GeminiTranscriptionMode.swift` | VERBATIM / SMART |
| `Sources/JarvisCore/Transcription/GeminiLiveSession.swift` | Pure, unit-testable Gemini wire contract |
| `Sources/JarvisApp/Capture/GeminiLiveTranscriber.swift` | WebSocket `TranscriptionSession` adapter |
| `Tests/JarvisCoreTests/Config/CredentialTests.swift` | Credential mapping + per-credential store |
| `Tests/JarvisCoreTests/Transcription/GeminiLiveSessionTests.swift` | Wire contract |
| `Tests/JarvisCoreTests/Transcription/TranscriptFilteringTests.swift` | Shared filter |

**Modified** — `Secrets.swift`, `JarvisReadiness.swift`, `TranscriptionProvider.swift`, `TranscriptionAudioFormat.swift`, `TranscriptionPreferences.swift`, `TranscriptionConfiguration.swift`, `Defaults.swift`, `TranscriptionFailureReason.swift`, `RealtimeSession.swift`, `OpenAITranscriptionLanguage.swift` → `TranscriptionLanguage.swift`, `AppDelegate.swift`, `BrainComposition.swift`, `SessionArtifacts.swift`, `AggregateEchoCapture.swift`, `RealtimeTranscriber.swift`, `AppleSpeechTranscriber.swift`, `TranscriptionSessionFactory.swift`, `SystemAudioBenchmarkCapture.swift`, `TranscriptionBenchmarkRunner.swift`, `APIKeyControls.swift`, `ConnectionsSection.swift`, `TranscriptionControls.swift`.

---

### Task 1: Per-credential secret store

**Files:**
- Create: `Sources/JarvisCore/Config/Credential.swift`
- Modify: `Sources/JarvisCore/Config/Secrets.swift`
- Modify: `Sources/JarvisCore/Diagnostics/JarvisReadiness.swift:37-39`
- Test: `Tests/JarvisCoreTests/Config/CredentialTests.swift`

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `public enum Credential: String, Sendable, Hashable, CaseIterable { case openAIAPIKey, geminiAPIKey }` with `public var fileName: String`, `public var environmentVariable: String`, `public var displayName: String`
  - `public protocol SecretStore { func apiKey(for credential: Credential) -> String? }`
  - `FileSecretStore.init(directoryURL: URL? = nil)`, `public func fileURL(for credential: Credential) -> URL`, `public var directoryURL: URL`, `@discardableResult public func setApiKey(_ key: String, for credential: Credential) -> Bool`
  - `JarvisReadiness.Credential` is removed; `JarvisReadiness` uses the top-level `Credential`.

- [ ] **Step 1: Write the failing test**

Create `Tests/JarvisCoreTests/Config/CredentialTests.swift`:

```swift
import Testing
import Foundation
@testable import JarvisCore

@Suite struct CredentialTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-credential-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func eachCredentialMapsToItsOwnFileAndEnvironmentVariable() {
        #expect(Credential.openAIAPIKey.fileName == "openai-api-key")
        #expect(Credential.geminiAPIKey.fileName == "gemini-api-key")
        #expect(Credential.openAIAPIKey.environmentVariable == "OPENAI_API_KEY")
        #expect(Credential.geminiAPIKey.environmentVariable == "GEMINI_API_KEY")
        #expect(Credential.openAIAPIKey.displayName == "OpenAI API")
        #expect(Credential.geminiAPIKey.displayName == "Gemini API")
    }

    /// Two credentials share one directory but never one file — saving Gemini must not disturb OpenAI.
    @Test func savingOneCredentialLeavesTheOtherIntact() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSecretStore(directoryURL: directory)

        #expect(store.setApiKey("sk-openai", for: .openAIAPIKey))
        #expect(store.setApiKey("gem-key", for: .geminiAPIKey))

        #expect(store.apiKey(for: .openAIAPIKey) == "sk-openai")
        #expect(store.apiKey(for: .geminiAPIKey) == "gem-key")
        #expect(store.fileURL(for: .openAIAPIKey) != store.fileURL(for: .geminiAPIKey))
        #expect(store.fileURL(for: .openAIAPIKey).deletingLastPathComponent()
            == store.fileURL(for: .geminiAPIKey).deletingLastPathComponent())
    }

    @Test func missingCredentialReadsNil() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSecretStore(directoryURL: directory)
        store.setApiKey("sk-openai", for: .openAIAPIKey)
        #expect(store.apiKey(for: .geminiAPIKey) == nil)
    }

    /// The credential file must never be group- or world-readable, and neither may its directory.
    @Test func savedCredentialIsOwnerOnlyInsideAnOwnerOnlyDirectory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSecretStore(directoryURL: directory)
        #expect(store.setApiKey("gem-key", for: .geminiAPIKey))

        let fileMode = try FileManager.default.attributesOfItem(
            atPath: store.fileURL(for: .geminiAPIKey).path)[.posixPermissions] as? NSNumber
        let directoryMode = try FileManager.default.attributesOfItem(
            atPath: directory.path)[.posixPermissions] as? NSNumber
        #expect(fileMode?.int16Value == 0o600)
        #expect(directoryMode?.int16Value == 0o700)
    }

    @Test func environmentStoreReadsTheVariableMatchingTheCredential() {
        let store = EnvSecretStore(environment: [
            "OPENAI_API_KEY": "sk-env",
            "GEMINI_API_KEY": "gem-env",
        ])
        #expect(store.apiKey(for: .openAIAPIKey) == "sk-env")
        #expect(store.apiKey(for: .geminiAPIKey) == "gem-env")
    }

    @Test func emptyEnvironmentValueIsTreatedAsAbsent() {
        let store = EnvSecretStore(environment: ["GEMINI_API_KEY": ""])
        #expect(store.apiKey(for: .geminiAPIKey) == nil)
    }

    /// The chain forwards the credential rather than collapsing to one key.
    @Test func chainedStoreFallsBackPerCredential() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = FileSecretStore(directoryURL: directory)
        file.setApiKey("sk-file", for: .openAIAPIKey)
        let chained = ChainedSecretStore([
            file,
            EnvSecretStore(environment: ["GEMINI_API_KEY": "gem-env"]),
        ])
        #expect(chained.apiKey(for: .openAIAPIKey) == "sk-file")
        #expect(chained.apiKey(for: .geminiAPIKey) == "gem-env")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/run-tests.sh 2>&1 | grep -A5 CredentialTests`
Expected: compile failure — `cannot find 'Credential' in scope`.

- [ ] **Step 3: Create the Credential type**

Create `Sources/JarvisCore/Config/Credential.swift`:

```swift
import Foundation

/// One API credential Jarvis stores on the user's behalf.
///
/// Raw values are stable identity, never user-facing copy: they key the readiness gate's required/
/// available sets and name the owner-only file each credential lives in.
public enum Credential: String, Sendable, Hashable, CaseIterable {
    case openAIAPIKey
    case geminiAPIKey

    /// Filename inside the shared Application Support directory. Kept lowercase-hyphenated so the
    /// existing `openai-api-key` file keeps working without a migration.
    public var fileName: String {
        switch self {
        case .openAIAPIKey: "openai-api-key"
        case .geminiAPIKey: "gemini-api-key"
        }
    }

    /// Headless fallback source, read only when the file is absent.
    public var environmentVariable: String {
        switch self {
        case .openAIAPIKey: "OPENAI_API_KEY"
        case .geminiAPIKey: "GEMINI_API_KEY"
        }
    }

    /// Card title in Connections Settings.
    public var displayName: String {
        switch self {
        case .openAIAPIKey: "OpenAI API"
        case .geminiAPIKey: "Gemini API"
        }
    }
}
```

- [ ] **Step 4: Rewrite Secrets.swift for per-credential access**

Replace the contents of `Sources/JarvisCore/Config/Secrets.swift`:

```swift
import Foundation

/// Source of an API credential. An owner-only file is primary (spec §5); env is a headless fallback.
public protocol SecretStore {
    func apiKey(for credential: Credential) -> String?
}

/// Reads each credential's environment variable from a provided dictionary (defaults to process env).
public struct EnvSecretStore: SecretStore {
    private let environment: [String: String]
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }
    public func apiKey(for credential: Credential) -> String? {
        guard let v = environment[credential.environmentVariable], !v.isEmpty else { return nil }
        return v
    }
}

/// Reads/writes each credential in its own owner-only file under one Application Support directory.
///
/// We deliberately do *not* use the login Keychain. macOS keys Keychain access to a per-build code
/// *partition* (a cdhash, for a self-signed app with no Apple Team ID), so a fresh build is treated as
/// a new program and re-prompts for the login password on every rebuild — unlike TCC (mic/screen),
/// which keys to the stable signing identity and persists. A 0600 file in a 0700 directory has the
/// same practical trust boundary as the headless environment fallback (any process running as this
/// user can read it) but never prompts and survives every rebuild.
public struct FileSecretStore: SecretStore {
    /// Directory holding every credential file. Exposed because callers also derive sibling
    /// Jarvis-managed paths (for example the sessions directory) from it.
    public let directoryURL: URL

    /// Defaults to `~/Library/Application Support/Jarvis/`. Pass an explicit URL in tests.
    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directoryURL = base.appendingPathComponent("Jarvis", isDirectory: true)
        }
    }

    /// Absolute path of one credential's file.
    public func fileURL(for credential: Credential) -> URL {
        directoryURL.appendingPathComponent(credential.fileName)
    }

    public func apiKey(for credential: Credential) -> String? {
        guard let data = try? Data(contentsOf: fileURL(for: credential)),
              let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    public func setApiKey(_ key: String, for credential: Credential) -> Bool {
        let fm = FileManager.default
        // 0700 dir: a 0755 parent would leak the credential files' names/metadata to other local
        // users (CWE-732). Mirrors how the per-session log directory is created.
        do {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // createDirectory only applies the mode to directories it *creates*; a pre-existing dir
            // (e.g. a 0755 left by a restored backup or another tool) keeps its mode. Tighten it so the
            // owner-only guarantee holds regardless. Best-effort: a metadata-perms failure must not
            // block saving the key, whose own bytes are still protected 0600.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        } catch { return false }
        // Create the file 0600 from the start (createFile applies attributes atomically on creation),
        // so the secret is never briefly world-readable between write and chmod.
        return fm.createFile(atPath: fileURL(for: credential).path, contents: Data(key.utf8),
                             attributes: [.posixPermissions: 0o600])
    }
}

/// Tries each store in order for the requested credential; first non-nil wins. App uses [File, Env].
public struct ChainedSecretStore: SecretStore {
    private let stores: [SecretStore]
    public init(_ stores: [SecretStore]) { self.stores = stores }
    public func apiKey(for credential: Credential) -> String? {
        for s in stores { if let k = s.apiKey(for: credential) { return k } }
        return nil
    }
}
```

- [ ] **Step 5: Point JarvisReadiness at the promoted enum**

In `Sources/JarvisCore/Diagnostics/JarvisReadiness.swift`, delete the nested enum (lines 37-39):

```swift
    public enum Credential: String, Sendable, Hashable, CaseIterable {
        case openAIAPIKey
    }
```

The remaining references inside that file (`Set<Credential>`, `case credentials(Set<Credential>)`, `requiredCredentials`) now resolve to the top-level `Credential` with no edit, because both live in `JarvisCore`. Existing test references written as `JarvisReadiness.Credential` do not exist — `Tests/JarvisCoreTests/Diagnostics/JarvisReadinessTests.swift` uses the bare `.openAIAPIKey` member syntax throughout, which still compiles.

Add a `typealias` only if the build reports an unresolved `JarvisReadiness.Credential`:

```swift
    public typealias Credential = JarvisCore.Credential
```

- [ ] **Step 6: Run the new test to verify it passes**

Run: `./scripts/run-tests.sh 2>&1 | grep -E "CredentialTests|Test run"`
Expected: all `CredentialTests` cases pass. Other targets still fail to compile — Task 2 fixes the call sites. Do not commit yet.

- [ ] **Step 7: Commit (after Task 2 builds)**

This task and Task 2 land in one commit, because the protocol change breaks every caller. Proceed directly to Task 2.

---

### Task 2: Migrate app call sites to the credential API

**Files:**
- Modify: `Sources/JarvisApp/App/AppDelegate.swift:14-15,202-205,248-250,301,420`
- Modify: `Sources/JarvisApp/App/BrainComposition.swift:293,360`
- Modify: `Sources/JarvisApp/App/SessionArtifacts.swift:26,140`
- Modify: `Sources/JarvisApp/Benchmark/TranscriptionBenchmarkRunner.swift:33`
- Modify: `Sources/JarvisApp/Settings/APIKeyControls.swift:7,28-32,41,49,58,185`
- Modify: `Sources/JarvisApp/Settings/ConnectionsSection.swift:25-30`

**Interfaces:**
- Consumes: `Credential`, `SecretStore.apiKey(for:)`, `FileSecretStore.directoryURL` / `fileURL(for:)` / `setApiKey(_:for:)` from Task 1.
- Produces: `APIKeyControls.init(credential: Credential, store: FileSecretStore, onKeySaved: @escaping (String) -> Void)`; `ConnectionsSection.init(detector:keyStore:onKeySaved:)` unchanged in shape.

- [ ] **Step 1: Update AppDelegate's stores and reads**

`Sources/JarvisApp/App/AppDelegate.swift` line 14 keeps `private let secretFile = FileSecretStore()` unchanged (its initializer now takes `directoryURL`, which still defaults). Update the three read sites:

Line 248-250 becomes:

```swift
        if transcriptionPreferences.provider.requiresOpenAIAPIKey(
            for: brain.preferences.route
        ), secrets.apiKey(for: .openAIAPIKey)?.isEmpty != false {
```

Line 301 becomes:

```swift
        let key = secrets.apiKey(for: .openAIAPIKey) ?? ""
```

Line 420 becomes:

```swift
                || (self.secrets.apiKey(for: .openAIAPIKey) ?? "") == key
```

Line 202-205, the Connections wiring, gains the credential:

```swift
            keyStore: secretFile,
```

stays as-is; `ConnectionsSection` supplies the credential internally in Step 4.

- [ ] **Step 2: Update BrainComposition and SessionArtifacts**

`Sources/JarvisApp/App/BrainComposition.swift` line 293:

```swift
        let key = apiKeyOverride ?? secrets.apiKey(for: .openAIAPIKey) ?? ""
```

Line 360 currently derives the sessions directory from the key file's parent. Use the directory directly:

```swift
        FileSecretStore().directoryURL.appendingPathComponent("sessions")
```

`Sources/JarvisApp/App/SessionArtifacts.swift` line 140, same change:

```swift
        return secretFile.directoryURL.appendingPathComponent("sessions")
```

- [ ] **Step 3: Update the benchmark runner**

`Sources/JarvisApp/Benchmark/TranscriptionBenchmarkRunner.swift` line 33:

```swift
    let apiKey = ChainedSecretStore([FileSecretStore(), EnvSecretStore()]).apiKey(for: .openAIAPIKey)
```

- [ ] **Step 4: Parameterize APIKeyControls by credential**

`Sources/JarvisApp/Settings/APIKeyControls.swift`. Change the doc comment, stored properties, and initializer:

```swift
/// Jarvis-managed credential editor used by Connections Settings. One instance per `Credential`.
@MainActor
final class APIKeyControls: NSObject {
    private let credential: Credential
    private let store: FileSecretStore
    private let onKeySaved: (String) -> Void
```

```swift
    var hasSavedKey: Bool { store.apiKey(for: credential) != nil }

    init(credential: Credential, store: FileSecretStore, onKeySaved: @escaping (String) -> Void) {
        self.credential = credential
        self.store = store
        self.onKeySaved = onKeySaved
    }
```

Line 41's header, line 49's accessibility label, line 58's identifier, and line 185's save all become credential-derived:

```swift
        card.setHeader(title: credential.displayName, detail: "Jarvis-managed credential")
```

```swift
        statusBadge.setAccessibilityLabel("\(credential.displayName) key saved")
```

```swift
        action.identifier = NSUserInterfaceItemIdentifier("\(credential.rawValue)-action")
```

```swift
        guard store.setApiKey(token, for: credential) else {
```

- [ ] **Step 5: Update ConnectionsSection's construction**

`Sources/JarvisApp/Settings/ConnectionsSection.swift` line 29:

```swift
        self.apiKeyControls = APIKeyControls(
            credential: .openAIAPIKey, store: keyStore, onKeySaved: onKeySaved)
```

- [ ] **Step 6: Build and run the full Gate**

Run: `swift build && ./scripts/run-tests.sh`
Expected: build succeeds; all tests pass including the new `CredentialTests`. The OpenAI credential file path is unchanged, so no user-visible behavior changes.

- [ ] **Step 7: Commit**

```bash
git add Sources/JarvisCore/Config/Credential.swift Sources/JarvisCore/Config/Secrets.swift \
  Sources/JarvisCore/Diagnostics/JarvisReadiness.swift Sources/JarvisApp Tests/JarvisCoreTests/Config/CredentialTests.swift
git commit -m "$(cat <<'EOF'
refactor(config): key the secret store by credential

The store hardcoded one OpenAI key end to end — filename, environment
variable, and a single shared instance — which cannot express a second
provider's credential. Promote the existing readiness credential enum to
a top-level Credential carrying its own file and environment mapping, and
take it as a parameter throughout. The OpenAI file path is unchanged.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Diw4AKtt8yvZ5u4zQBSiEX
EOF
)"
```

---

### Task 3: Replace the single-Bool credential gate

**Files:**
- Modify: `Sources/JarvisCore/Transcription/TranscriptionProvider.swift:20-28`
- Modify: `Sources/JarvisApp/App/AppDelegate.swift:248,302,310,333-334`
- Test: `Tests/JarvisCoreTests/Config/TranscriptionPreferencesTests.swift:84-86,142-144`

**Interfaces:**
- Consumes: `Credential` from Task 1.
- Produces: on `TranscriptionProvider` — `public var ownCredential: Credential?` and `public func requiredCredentials(for brainRoute: BrainRoute?) -> Set<Credential>`, plus `case gemini = "gemini"` with `displayName` `"Gemini"`. `requiresOpenAIAPIKey` and `requiresOpenAIAPIKey(for:)` are removed.

- [ ] **Step 1: Write the failing test**

In `Tests/JarvisCoreTests/Config/TranscriptionPreferencesTests.swift`, **replace** the existing assertions at lines 84-86 and 142-144 (they reference `requiresOpenAIAPIKey`, which this task removes by design) with a new test. Keep the surrounding file's existing `cliOnly` / route fixtures — reuse whatever local helper builds a `BrainRoute`:

```swift
    @Test func openAITranscriptionAlwaysNeedsItsOwnKey() {
        #expect(TranscriptionProvider.openAI.requiredCredentials(for: nil) == [.openAIAPIKey])
    }

    @Test func appleSpeechNeedsNoCredentialOfItsOwn() {
        #expect(TranscriptionProvider.appleSpeech.requiredCredentials(for: nil).isEmpty)
    }

    @Test func geminiTranscriptionNeedsOnlyItsOwnKeyWithACLIBrain() {
        #expect(TranscriptionProvider.gemini.requiredCredentials(for: cliOnly) == [.geminiAPIKey])
    }

    /// The combination the old single-Bool gate could not express: Gemini ears, OpenAI brain.
    @Test func geminiEarsWithAnOpenAIBrainNeedBothKeys() {
        #expect(TranscriptionProvider.gemini.requiredCredentials(for: openAIRoute)
            == [.geminiAPIKey, .openAIAPIKey])
    }

    @Test func appleSpeechWithAnOpenAIBrainNeedsTheOpenAIKey() {
        #expect(TranscriptionProvider.appleSpeech.requiredCredentials(for: openAIRoute)
            == [.openAIAPIKey])
    }
```

If the file has no `openAIRoute` fixture, add one next to the existing `cliOnly` fixture, mirroring its construction but with an OpenAI target.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/run-tests.sh 2>&1 | grep -E "requiredCredentials|value of type"`
Expected: compile failure — no member `requiredCredentials`, and no `.gemini` case yet. Add `case gemini = "gemini"` to `TranscriptionProvider` now (its `displayName` returns `"Gemini"`); Task 6 fills in the rest of the Gemini types.

- [ ] **Step 3: Implement the credential requirement**

Replace lines 20-28 of `Sources/JarvisCore/Transcription/TranscriptionProvider.swift`:

```swift
    /// The credential this provider needs to transcribe, if any. Apple Speech is on-device.
    /// `public` because `AppDelegate` (JarvisApp) selects the transcription key from it.
    public var ownCredential: Credential? {
        switch self {
        case .openAI: .openAIAPIKey
        case .gemini: .geminiAPIKey
        case .appleSpeech: nil
        }
    }

    /// Every credential a Start needs: this provider's own, plus OpenAI's when any authorized brain
    /// target is OpenAI. Both halves can require a key independently — Gemini ears with an OpenAI
    /// brain needs two — which a single Bool could not express.
    public func requiredCredentials(for brainRoute: BrainRoute?) -> Set<Credential> {
        var required = Set(ownCredential.map { [$0] } ?? [])
        if brainRoute?.targets.contains(where: { $0.provider == .openAI }) == true {
            required.insert(.openAIAPIKey)
        }
        return required
    }
```

- [ ] **Step 4: Feed the readiness gate from it**

In `Sources/JarvisApp/App/AppDelegate.swift`, replace line 302's `requiresOpenAIKey` with the set:

```swift
        let requiredCredentials = transcriptionProvider.requiredCredentials(for: brainRoute)
```

Line 310 in the readiness configuration:

```swift
            requiredCredentials: requiredCredentials,
```

Lines 333-334, building the available set — read each credential rather than assuming one key:

```swift
        let availableCredentials = Set(Credential.allCases.filter {
            secrets.apiKey(for: $0)?.isEmpty == false
        })
        observeReadiness(.credentials(available: availableCredentials), for: readinessSession)
        let missingCredentials = requiredCredentials.subtracting(availableCredentials)
        guard missingCredentials.isEmpty else {
            jlog("Jarvis: can't start — missing credential(s): "
                 + missingCredentials.map(\.rawValue).sorted().joined(separator: ", "))
            if wasRunning {
                artifacts.sessionAudit?.record(.settingsChangeNotApplied)
            }
            errorReporter.reportImmediately(.noAPIKey, context: reportContext)
            return false
        }
```

Note `key` (line 301) is still the OpenAI key and is still passed to the OpenAI transcriber and brain; leave it. Line 248's startup hint becomes:

```swift
        if !transcriptionPreferences.provider.requiredCredentials(
            for: brain.preferences.route
        ).allSatisfy({ secrets.apiKey(for: $0)?.isEmpty == false }) {
            jlog("Jarvis: missing an API key — paste it in Settings, then press Start.")
```

- [ ] **Step 5: Run the Gate**

Run: `swift build && ./scripts/run-tests.sh`
Expected: build succeeds, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/JarvisCore/Transcription/TranscriptionProvider.swift Sources/JarvisApp/App/AppDelegate.swift \
  Tests/JarvisCoreTests/Config/TranscriptionPreferencesTests.swift
git commit -m "$(cat <<'EOF'
refactor(transcription): require credentials as a set, not a bool

requiresOpenAIAPIKey could not express a non-OpenAI transcription
provider paired with an OpenAI brain target, which needs two distinct
keys. Return the required credential set instead and feed the readiness
gate from it directly.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Diw4AKtt8yvZ5u4zQBSiEX
EOF
)"
```

---

### Task 4: Provider-derived wire audio format

**Files:**
- Modify: `Sources/JarvisCore/Transcription/TranscriptionAudioFormat.swift:5-9`
- Modify: `Sources/JarvisCore/Transcription/TranscriptionProvider.swift`
- Modify: `Sources/JarvisCore/Transcription/RealtimeSession.swift:73-80`
- Modify: `Sources/JarvisApp/Capture/AggregateEchoCapture.swift:51-56,92-98`
- Modify: `Sources/JarvisApp/Capture/RealtimeTranscriber.swift`, `Sources/JarvisApp/Capture/AppleSpeechTranscriber.swift`
- Modify: `Sources/JarvisApp/Benchmark/SystemAudioBenchmarkCapture.swift:123`
- Modify: `Sources/JarvisApp/App/AppDelegate.swift:677`
- Test: `Tests/JarvisCoreTests/Transcription/TranscriptionAudioFormatTests.swift`

**Interfaces:**
- Consumes: `TranscriptionProvider.gemini` from Task 3.
- Produces: `TranscriptionAudioFormat.pcm16Mono24k`, `TranscriptionAudioFormat.pcm16Mono16k`, `TranscriptionProvider.audioFormat: TranscriptionAudioFormat`. `TranscriptionAudioFormat.pcm16Mono` is removed. `AggregateEchoCapture.init` gains a first parameter `audioFormat: TranscriptionAudioFormat`. `RealtimeSession.sessionUpdate` gains `sampleRate: Int`.

- [ ] **Step 1: Write the failing test**

In `Tests/JarvisCoreTests/Transcription/TranscriptionAudioFormatTests.swift`, **update** the two existing cases that reference `pcm16Mono` to reference `pcm16Mono24k` (the constant is renamed by design, values unchanged), then append:

```swift
    @Test func geminiCapturesAtSixteenKilohertzAndTheOthersAtTwentyFour() {
        #expect(TranscriptionProvider.gemini.audioFormat == .pcm16Mono16k)
        #expect(TranscriptionProvider.openAI.audioFormat == .pcm16Mono24k)
        #expect(TranscriptionProvider.appleSpeech.audioFormat == .pcm16Mono24k)
    }

    @Test func sixteenKilohertzFormatDerivesItsOwnByteMath() {
        let format = TranscriptionAudioFormat.pcm16Mono16k
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
        #expect(format.bytesPerSecond == 32_000)
        #expect(format.byteCount(forDuration: 0.1) == 3_200)
        #expect(format.duration(forByteCount: 32_000) == 1.0)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/run-tests.sh 2>&1 | grep -E "pcm16Mono16k|audioFormat"`
Expected: compile failure — `type 'TranscriptionAudioFormat' has no member 'pcm16Mono16k'`.

- [ ] **Step 3: Split the format constant**

In `Sources/JarvisCore/Transcription/TranscriptionAudioFormat.swift`, replace the single `pcm16Mono` static with two, and update the type's doc comment:

```swift
/// PCM contract between capture and one live transcription adapter. The rate is a provider
/// requirement — OpenAI Realtime takes 24 kHz, Gemini Live takes 16 kHz — not a quality knob:
/// speech carries nothing above 8 kHz that a recognizer uses, so 16 kHz is already sufficient.
public struct TranscriptionAudioFormat: Equatable, Sendable {
    /// OpenAI Realtime's required input rate; also what Apple Speech is fed today.
    public static let pcm16Mono24k = TranscriptionAudioFormat(
        sampleRate: 24_000,
        channelCount: 1,
        bytesPerSample: MemoryLayout<Int16>.size)

    /// Gemini Live's required input rate (`audio/pcm;rate=16000`).
    public static let pcm16Mono16k = TranscriptionAudioFormat(
        sampleRate: 16_000,
        channelCount: 1,
        bytesPerSample: MemoryLayout<Int16>.size)
```

In `Sources/JarvisCore/Transcription/TranscriptionProvider.swift`, add:

```swift
    /// The PCM format capture must deliver for this provider. Fixed for the session, because the
    /// provider is resolved before capture is built and never changes inside a live session.
    public var audioFormat: TranscriptionAudioFormat {
        switch self {
        case .openAI, .appleSpeech: .pcm16Mono24k
        case .gemini: .pcm16Mono16k
        }
    }
```

- [ ] **Step 4: Make OpenAI's wire rate explicit**

In `Sources/JarvisCore/Transcription/RealtimeSession.swift`, add a `sampleRate: Int` parameter to `sessionUpdate` (after `noiseReduction`) and use it at line 76:

```swift
        sampleRate: Int = TranscriptionAudioFormat.pcm16Mono24k.sampleRate
```

```swift
            "format": [
                "type": "audio/pcm",
                "rate": sampleRate,
            ],
```

- [ ] **Step 5: Thread the format through capture and the adapters**

`Sources/JarvisApp/Capture/AggregateEchoCapture.swift` — replace the two stored resamplers (lines 51-56) with lazily-built ones fed by an injected format, and add the initializer parameter:

```swift
    private let micDown: Resampler?
    private let sysDown: Resampler?
```

In `init`, as the first parameter and first assignments:

```swift
    init(audioFormat: TranscriptionAudioFormat,
         onMicCaptured: @escaping @Sendable (UInt64, Int, TimeInterval) -> Void,
```

```swift
        // AEC always runs at 48 kHz; the wire rate is the selected provider's requirement. Gemini's
        // 16 kHz is an exact 3:1 decimation from 48, so there is never a second resampling stage.
        micDown = Resampler(fromHz: Self.aecRate, toHz: Double(audioFormat.sampleRate))
        sysDown = Resampler(fromHz: Self.aecRate, toHz: Double(audioFormat.sampleRate))
```

Every existing `micDown.convert(...)` / `sysDown.convert(...)` call site becomes optional-chained (`micDown?.convert(...) ?? []`) — the previous `let micDown = Resampler(...)` was already failable and implicitly optional, so most call sites need no change; fix whatever the compiler flags.

In `Sources/JarvisApp/App/AppDelegate.swift` line 677, pass the format from the Start snapshot:

```swift
        let capture = AggregateEchoCapture(
            audioFormat: transcriptionConfiguration.provider.audioFormat,
```

In `RealtimeTranscriber.swift` and `AppleSpeechTranscriber.swift`, replace each `TranscriptionAudioFormat.pcm16Mono` reference with `TranscriptionAudioFormat.pcm16Mono24k`. In `SystemAudioBenchmarkCapture.swift:123`, the same.

- [ ] **Step 6: Run the Gate**

Run: `swift build && ./scripts/run-tests.sh`
Expected: build succeeds, all tests pass. `LocalTurnDetector` needs no change — it is constructed with `inputSampleRate: Self.aecRate` (48 kHz, pre-downsample), so it is independent of the wire rate.

- [ ] **Step 7: Commit**

```bash
git add Sources/JarvisCore/Transcription Sources/JarvisApp Tests/JarvisCoreTests/Transcription/TranscriptionAudioFormatTests.swift
git commit -m "$(cat <<'EOF'
refactor(capture): derive the wire audio format from the provider

pcm16Mono was named as a neutral contract but encoded OpenAI Realtime's
24 kHz requirement. Name both rates, resolve one from the selected
provider, and inject it into capture so a 16 kHz provider is a single
48 -> 16 decimation rather than a second resampling stage.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Diw4AKtt8yvZ5u4zQBSiEX
EOF
)"
```

---

### Task 5: Rename the language enum for reuse

**Files:**
- Rename: `Sources/JarvisCore/Transcription/OpenAITranscriptionLanguage.swift` → `Sources/JarvisCore/Transcription/TranscriptionLanguage.swift`
- Modify: every referencing file (see Step 2)

**Interfaces:**
- Consumes: nothing new.
- Produces: `public enum TranscriptionLanguage` with unchanged cases (`english`, `mandarinChinese`), raw values, `displayName`, `singularHint`, `multipleHint`, and `canonicalizing(_:)`. `OpenAITranscriptionLanguage` no longer exists.

- [ ] **Step 1: Rename the file and type**

```bash
git mv Sources/JarvisCore/Transcription/OpenAITranscriptionLanguage.swift \
       Sources/JarvisCore/Transcription/TranscriptionLanguage.swift
```

In the renamed file, change the declaration and doc comment. Raw values stay identical so no persisted preference migrates:

```swift
/// One language a user expects speakers to use during a transcription session.
///
/// Expected languages are persisted and transported as a list so adding another supported language
/// never requires defining every possible language combination. An empty list means automatic
/// detection and sends no language hint. Shared by every provider that accepts language hints:
/// `multipleHint` is already BCP-47, which is also what Gemini's `languageCodes` expects.
public enum TranscriptionLanguage: String, CaseIterable, Codable, Sendable {
```

Update the two internal references inside the file:

```swift
    public static func canonicalizing(
        _ languages: [TranscriptionLanguage]
    ) -> [TranscriptionLanguage] {
```

- [ ] **Step 2: Update every reference**

Run this to find them, then update each:

```bash
grep -rln "OpenAITranscriptionLanguage" Sources Tests
```

Expected files: `TranscriptionPreferences.swift`, `TranscriptionConfiguration.swift`, `Defaults.swift`, `RealtimeSession.swift`, `TranscriptionControls.swift`, `ExpectedLanguagePicker` (wherever it lives — find with `grep -rl ExpectedLanguagePicker Sources`), and the Core tests. The property names `openAIExpectedLanguages` stay as they are in this task; Task 6 adds the Gemini sibling.

- [ ] **Step 3: Run the Gate**

Run: `swift build && ./scripts/run-tests.sh`
Expected: build succeeds, all tests pass. This is a pure rename — no behavior changes.

- [ ] **Step 4: Commit**

```bash
git add -A Sources Tests
git commit -m "$(cat <<'EOF'
refactor(transcription): rename the language enum to be provider-neutral

Its BCP-47 hints are what Gemini's languageCodes expects too, so the
OpenAI prefix no longer describes it. Raw values are unchanged, so no
persisted preference migrates.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Diw4AKtt8yvZ5u4zQBSiEX
EOF
)"
```

---

### Task 6: Gemini types, preferences, and configuration

**Files:**
- Create: `Sources/JarvisCore/Transcription/GeminiTranscriptionModel.swift`
- Create: `Sources/JarvisCore/Transcription/GeminiTranscriptionMode.swift`
- Modify: `Sources/JarvisCore/Config/Defaults.swift:52-72`
- Modify: `Sources/JarvisCore/Config/TranscriptionPreferences.swift`
- Modify: `Sources/JarvisCore/Transcription/TranscriptionConfiguration.swift`
- Test: `Tests/JarvisCoreTests/Config/TranscriptionPreferencesTests.swift`

**Interfaces:**
- Consumes: `TranscriptionLanguage` (Task 5), `TranscriptionProvider.gemini` (Task 3).
- Produces:
  - `public enum GeminiTranscriptionModel: String, CaseIterable, Codable, Sendable { case geminiTranscribeLive = "gemini-3.5-transcribe-live" }` with `public var displayName: String` and `public var wireModelName: String` (returns `"models/gemini-3.5-transcribe-live"`)
  - `public enum GeminiTranscriptionMode: String, CaseIterable, Codable, Sendable { case verbatim, smart }` with `public var displayName: String` and `public var wireValue: String` (`"VERBATIM"` / `"SMART"`)
  - `TranscriptionPreferences.geminiModel`, `.geminiExpectedLanguages`, `.geminiVocabularyKeywords`, `.geminiMode`
  - `TranscriptionConfiguration.init(provider:openAIModel:openAIExpectedLanguages:openAIVocabularyKeywords:appleSpeechLocaleIdentifier:geminiModel:geminiExpectedLanguages:geminiVocabularyKeywords:geminiMode:)` with Gemini parameters defaulted

- [ ] **Step 1: Write the failing test**

Append to `Tests/JarvisCoreTests/Config/TranscriptionPreferencesTests.swift`. Use the file's existing pattern for a scratch `UserDefaults` (find it near the top; it typically builds a suite-named instance):

```swift
    @Test func geminiModelExposesItsWireNameWithTheModelsPrefix() {
        #expect(GeminiTranscriptionModel.geminiTranscribeLive.rawValue == "gemini-3.5-transcribe-live")
        #expect(GeminiTranscriptionModel.geminiTranscribeLive.wireModelName
            == "models/gemini-3.5-transcribe-live")
    }

    @Test func geminiModeMapsToTheUppercaseWireValues() {
        #expect(GeminiTranscriptionMode.verbatim.wireValue == "VERBATIM")
        #expect(GeminiTranscriptionMode.smart.wireValue == "SMART")
    }

    @Test func geminiPreferencesRoundTrip() {
        let defaults = makeDefaults()   // existing helper in this file
        let preferences = TranscriptionPreferences(defaults: defaults)

        preferences.geminiExpectedLanguages = [.mandarinChinese, .english]
        preferences.geminiVocabularyKeywords = [" gRPC ", "", "Kubernetes"]
        preferences.geminiMode = .smart

        // Canonicalized to declaration order; blank keywords dropped and trimmed.
        #expect(preferences.geminiExpectedLanguages == [.english, .mandarinChinese])
        #expect(preferences.geminiVocabularyKeywords == ["gRPC", "Kubernetes"])
        #expect(preferences.geminiMode == .smart)
    }

    @Test func geminiPreferencesFallBackToDefaultsWhenUnset() {
        let preferences = TranscriptionPreferences(defaults: makeDefaults())
        #expect(preferences.geminiModel == .geminiTranscribeLive)
        #expect(preferences.geminiExpectedLanguages.isEmpty)
        #expect(preferences.geminiVocabularyKeywords.isEmpty)
        #expect(preferences.geminiMode == .verbatim)
    }

    @Test func startSnapshotCarriesTheGeminiChoices() {
        let defaults = makeDefaults()
        let preferences = TranscriptionPreferences(defaults: defaults)
        preferences.provider = .gemini
        preferences.geminiMode = .smart
        preferences.geminiVocabularyKeywords = ["Kubernetes"]

        let configuration = preferences.configuration
        #expect(configuration.provider == .gemini)
        #expect(configuration.geminiMode == .smart)
        #expect(configuration.geminiVocabularyKeywords == ["Kubernetes"])
        // Gemini's server owns turn boundaries, so no client strategy is derived.
        #expect(configuration.turnDetectionStrategy == nil)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/run-tests.sh 2>&1 | grep -E "GeminiTranscription|geminiMode"`
Expected: compile failure — `cannot find 'GeminiTranscriptionModel' in scope`.

- [ ] **Step 3: Create the two Gemini enums**

`Sources/JarvisCore/Transcription/GeminiTranscriptionModel.swift`:

```swift
import Foundation

/// A Gemini speech-to-text model Jarvis can select. Only the live/streaming model applies — Jarvis
/// coaches a conversation as it happens, so the batch `gemini-3.5-transcribe` has no place here.
public enum GeminiTranscriptionModel: String, CaseIterable, Codable, Sendable {
    case geminiTranscribeLive = "gemini-3.5-transcribe-live"

    public var displayName: String {
        switch self {
        case .geminiTranscribeLive: "Gemini 3.5 Transcribe Live"
        }
    }

    /// The Live API addresses models by resource name, so the wire value carries a `models/` prefix
    /// the persisted raw value deliberately does not.
    public var wireModelName: String { "models/\(rawValue)" }
}
```

`Sources/JarvisCore/Transcription/GeminiTranscriptionMode.swift`:

```swift
import Foundation

/// How literally Gemini transcribes speech. Verbatim preserves the raw utterance; smart removes
/// filler words and formats the output, which reads better but is no longer what was said.
public enum GeminiTranscriptionMode: String, CaseIterable, Codable, Sendable {
    case verbatim
    case smart

    public var displayName: String {
        switch self {
        case .verbatim: "Verbatim"
        case .smart: "Smart"
        }
    }

    /// The wire enum is uppercase.
    public var wireValue: String { rawValue.uppercased() }
}
```

- [ ] **Step 4: Add the defaults**

In `Sources/JarvisCore/Config/Defaults.swift`, inside `enum Transcription` after the Apple Speech block:

```swift
        public static let geminiModelKey = "transcription.gemini.model"
        public static let geminiModel: GeminiTranscriptionModel = .geminiTranscribeLive

        public static let geminiExpectedLanguagesKey = "transcription.gemini.expected-languages"
        /// Empty means automatic detection across every language Gemini supports.
        public static let geminiExpectedLanguages: [TranscriptionLanguage] = []

        public static let geminiVocabularyKeywordsKey = "transcription.gemini.vocabulary-keywords"
        /// Empty until the user adds terms; Gemini accepts up to 1,000.
        public static let geminiVocabularyKeywords: [String] = []

        public static let geminiModeKey = "transcription.gemini.mode"
        /// Verbatim by default: coaching reasons about what was actually said.
        public static let geminiMode: GeminiTranscriptionMode = .verbatim
```

- [ ] **Step 5: Add the preferences**

In `Sources/JarvisCore/Config/TranscriptionPreferences.swift`, after `appleSpeechLocaleIdentifier`:

```swift
    public var geminiModel: GeminiTranscriptionModel {
        get {
            guard let raw = defaults.string(forKey: Defaults.Transcription.geminiModelKey),
                  let model = GeminiTranscriptionModel(rawValue: raw) else {
                return Defaults.Transcription.geminiModel
            }
            return model
        }
        set {
            defaults.set(newValue.rawValue, forKey: Defaults.Transcription.geminiModelKey)
        }
    }

    /// Every language speakers may use. An empty list means automatic detection.
    public var geminiExpectedLanguages: [TranscriptionLanguage] {
        get {
            guard let stored = defaults.stringArray(
                forKey: Defaults.Transcription.geminiExpectedLanguagesKey) else {
                return Defaults.Transcription.geminiExpectedLanguages
            }
            return TranscriptionLanguage.canonicalizing(
                stored.compactMap(TranscriptionLanguage.init(rawValue:)))
        }
        set {
            let languages = TranscriptionLanguage.canonicalizing(newValue)
            defaults.set(
                languages.map(\.rawValue),
                forKey: Defaults.Transcription.geminiExpectedLanguagesKey)
        }
    }

    /// Literal terms (jargon, names) that bias Gemini recognition; the API accepts up to 1,000.
    public var geminiVocabularyKeywords: [String] {
        get {
            guard let stored = defaults.stringArray(
                forKey: Defaults.Transcription.geminiVocabularyKeywordsKey) else {
                return Defaults.Transcription.geminiVocabularyKeywords
            }
            return stored
        }
        set {
            let keywords = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            defaults.set(keywords, forKey: Defaults.Transcription.geminiVocabularyKeywordsKey)
        }
    }

    public var geminiMode: GeminiTranscriptionMode {
        get {
            guard let raw = defaults.string(forKey: Defaults.Transcription.geminiModeKey),
                  let mode = GeminiTranscriptionMode(rawValue: raw) else {
                return Defaults.Transcription.geminiMode
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Defaults.Transcription.geminiModeKey)
        }
    }
```

Extend the `configuration` computed property to pass the four new values.

- [ ] **Step 6: Extend the Start snapshot**

In `Sources/JarvisCore/Transcription/TranscriptionConfiguration.swift`, add the four stored properties and initializer parameters (defaulted so existing test construction keeps compiling):

```swift
    public let geminiModel: GeminiTranscriptionModel
    public let geminiExpectedLanguages: [TranscriptionLanguage]
    public let geminiVocabularyKeywords: [String]
    public let geminiMode: GeminiTranscriptionMode
```

```swift
        geminiModel: GeminiTranscriptionModel = .geminiTranscribeLive,
        geminiExpectedLanguages: [TranscriptionLanguage] = [],
        geminiVocabularyKeywords: [String] = [],
        geminiMode: GeminiTranscriptionMode = .verbatim
```

```swift
        self.geminiModel = geminiModel
        self.geminiExpectedLanguages = TranscriptionLanguage.canonicalizing(geminiExpectedLanguages)
        self.geminiVocabularyKeywords = geminiVocabularyKeywords
        self.geminiMode = geminiMode
```

`turnDetectionStrategy` needs no change: it already returns `nil` for any provider other than `.openAI`, which is correct for Gemini (its server owns turn boundaries).

- [ ] **Step 7: Run the Gate**

Run: `swift build && ./scripts/run-tests.sh`
Expected: build succeeds, all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/JarvisCore Tests/JarvisCoreTests/Config/TranscriptionPreferencesTests.swift
git commit -m "$(cat <<'EOF'
feat(transcription): persist the Gemini provider choices

Adds the Gemini model and verbatim/smart mode enums with their wire
encodings, plus the persisted language, vocabulary, and mode preferences
carried in the immutable Start snapshot.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Diw4AKtt8yvZ5u4zQBSiEX
EOF
)"
```

---

### Task 7: The Gemini wire contract

**Files:**
- Create: `Sources/JarvisCore/Transcription/TranscriptFiltering.swift`
- Create: `Sources/JarvisCore/Transcription/GeminiLiveSession.swift`
- Modify: `Sources/JarvisCore/Transcription/RealtimeSession.swift:206-239`
- Test: `Tests/JarvisCoreTests/Transcription/TranscriptFilteringTests.swift`
- Test: `Tests/JarvisCoreTests/Transcription/GeminiLiveSessionTests.swift`

**Interfaces:**
- Consumes: `GeminiTranscriptionModel`, `GeminiTranscriptionMode`, `TranscriptionLanguage`, `TranscriptionFailureReason`, `Speaker`.
- Produces:
  - `public enum TranscriptFiltering { public static func meaningfulTranscript(_ raw: String, speaker: Speaker) -> String? }`
  - `public enum GeminiLiveSession` with `connectURL(apiKey:) -> URL`, `setupMessage(model:languages:vocabulary:mode:) -> [String: Any]`, `audioFrame(base64PCM:sampleRate:) -> [String: Any]`, `audioStreamEnd() -> [String: Any]`, `isSetupComplete(_:) -> Bool`, `finalTranscript(from:speaker:) -> String?`, `terminalFailure(from:) -> TranscriptionFailureReason?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/JarvisCoreTests/Transcription/TranscriptFilteringTests.swift`:

```swift
import Testing
@testable import JarvisCore

@Suite struct TranscriptFilteringTests {
    @Test func punctuationOnlyOutputIsDroppedForBothSpeakers() {
        #expect(TranscriptFiltering.meaningfulTranscript(".", speaker: .me) == nil)
        #expect(TranscriptFiltering.meaningfulTranscript("  …  ", speaker: .them) == nil)
    }

    @Test func captionArtifactsAreDroppedOnlyOnTheMicSide() {
        #expect(TranscriptFiltering.meaningfulTranscript("Thank you.", speaker: .me) == nil)
        // A turn-ending reply from the other side is real speech, not an artifact.
        #expect(TranscriptFiltering.meaningfulTranscript("Thank you.", speaker: .them) == "Thank you.")
    }

    @Test func realSpeechContainingADenylistedWordSurvives() {
        #expect(TranscriptFiltering.meaningfulTranscript("Thank you for the walkthrough", speaker: .me)
            == "Thank you for the walkthrough")
    }
}
```

Create `Tests/JarvisCoreTests/Transcription/GeminiLiveSessionTests.swift`:

```swift
import Testing
import Foundation
@testable import JarvisCore

@Suite struct GeminiLiveSessionTests {
    private func setup(
        languages: [TranscriptionLanguage] = [],
        vocabulary: [String] = [],
        mode: GeminiTranscriptionMode = .verbatim
    ) -> [String: Any] {
        GeminiLiveSession.setupMessage(
            model: .geminiTranscribeLive, languages: languages, vocabulary: vocabulary, mode: mode)
    }

    private func transcription(_ message: [String: Any]) -> [String: Any] {
        let setup = message["setup"] as? [String: Any]
        return setup?["inputAudioTranscription"] as? [String: Any] ?? [:]
    }

    @Test func connectURLCarriesTheKeyAsAQueryItem() {
        let url = GeminiLiveSession.connectURL(apiKey: "gem-secret")
        #expect(url.scheme == "wss")
        #expect(url.host == "generativelanguage.googleapis.com")
        #expect(url.path == "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first(where: { $0.name == "key" })?.value == "gem-secret")
    }

    /// The key lives in the URL, so anything logged must be the query-free form.
    @Test func redactedEndpointDropsTheQueryString() {
        #expect(!GeminiLiveSession.redactedEndpoint.contains("key"))
        #expect(GeminiLiveSession.redactedEndpoint.hasPrefix("wss://generativelanguage.googleapis.com/"))
    }

    @Test func setupRequestsTextOnlyResponsesFromTheLiveModel() {
        let message = setup()
        let inner = message["setup"] as? [String: Any]
        #expect(inner?["model"] as? String == "models/gemini-3.5-transcribe-live")
        let generation = inner?["generationConfig"] as? [String: Any]
        #expect(generation?["responseModalities"] as? [String] == ["TEXT"])
    }

    /// An empty list is sent, not omitted: `[]` is what selects automatic detection.
    @Test func noSelectedLanguagesSendsAnEmptyList() {
        #expect(transcription(setup())["languageCodes"] as? [String] == [])
    }

    @Test func selectedLanguagesAreSentAsBCP47Codes() {
        let codes = transcription(setup(languages: [.english, .mandarinChinese]))["languageCodes"]
        #expect(codes as? [String] == ["en", "zh-cn"])
    }

    @Test func vocabularyAndModeAreCarriedOnTheSetup() {
        let inner = transcription(setup(vocabulary: ["gRPC", "Kubernetes"], mode: .smart))
        #expect(inner["customVocabulary"] as? [String] == ["gRPC", "Kubernetes"])
        #expect(inner["mode"] as? String == "SMART")
    }

    @Test func audioFrameIsBase64PCMWithTheMatchingRate() {
        let frame = GeminiLiveSession.audioFrame(base64PCM: "AAECAw==", sampleRate: 16_000)
        let input = frame["realtimeInput"] as? [String: Any]
        let audio = input?["audio"] as? [String: Any]
        #expect(audio?["data"] as? String == "AAECAw==")
        #expect(audio?["mimeType"] as? String == "audio/pcm;rate=16000")
    }

    @Test func streamEndIsSignalledExplicitly() {
        let end = GeminiLiveSession.audioStreamEnd()
        let input = end["realtimeInput"] as? [String: Any]
        #expect(input?["audioStreamEnd"] as? Bool == true)
    }

    @Test func setupIsCompleteOnlyOnTheServersAcknowledgement() {
        #expect(GeminiLiveSession.isSetupComplete(["setupComplete": [String: Any]()]))
        #expect(!GeminiLiveSession.isSetupComplete(["serverContent": [String: Any]()]))
    }

    @Test func finalTranscriptIsReadFromTheFinalizedField() {
        let event: [String: Any] = ["serverContent": [
            "inputTranscription": ["text": "let's talk about indexes"],
        ]]
        #expect(GeminiLiveSession.finalTranscript(from: event, speaker: .me)
            == "let's talk about indexes")
    }

    /// Interim hypotheses are speculative and are never appended to the transcript.
    @Test func interimTranscriptNeverYieldsText() {
        let event: [String: Any] = ["serverContent": [
            "interimInputTranscription": ["text": "let's talk about ind"],
        ]]
        #expect(GeminiLiveSession.finalTranscript(from: event, speaker: .me) == nil)
    }

    @Test func finalTranscriptAppliesTheSharedHallucinationFilter() {
        let event: [String: Any] = ["serverContent": ["inputTranscription": ["text": "Thank you."]]]
        #expect(GeminiLiveSession.finalTranscript(from: event, speaker: .me) == nil)
        #expect(GeminiLiveSession.finalTranscript(from: event, speaker: .them) == "Thank you.")
    }

    @Test func authenticationAndQuotaErrorsAreTerminal() {
        #expect(GeminiLiveSession.terminalFailure(from: ["error": [
            "code": 401, "status": "UNAUTHENTICATED",
        ]]) == .authenticationFailed)
        #expect(GeminiLiveSession.terminalFailure(from: ["error": [
            "code": 429, "status": "RESOURCE_EXHAUSTED",
        ]]) == .quotaExceeded)
        #expect(GeminiLiveSession.terminalFailure(from: ["error": [
            "code": 403, "status": "PERMISSION_DENIED",
        ]]) == .accessDenied)
        #expect(GeminiLiveSession.terminalFailure(from: ["error": [
            "code": 400, "status": "INVALID_ARGUMENT",
        ]]) == .configurationRejected)
        #expect(GeminiLiveSession.terminalFailure(from: ["error": [
            "code": 404, "status": "NOT_FOUND",
        ]]) == .configurationRejected)
    }

    /// An unknown or transient server error must stay diagnostic rather than tearing the session down.
    @Test func unknownErrorsAreNotTerminal() {
        #expect(GeminiLiveSession.terminalFailure(from: ["error": [
            "code": 503, "status": "UNAVAILABLE",
        ]]) == nil)
        #expect(GeminiLiveSession.terminalFailure(from: ["serverContent": [String: Any]()]) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/run-tests.sh 2>&1 | grep -E "GeminiLiveSession|TranscriptFiltering"`
Expected: compile failure — `cannot find 'GeminiLiveSession' in scope`.

- [ ] **Step 3: Extract the shared transcript filter**

Create `Sources/JarvisCore/Transcription/TranscriptFiltering.swift`, moving the two members verbatim out of `RealtimeSession`:

```swift
import Foundation

/// Drops non-speech that a transcription model invents — the "`.`-on-silence" problem. Provider-
/// independent: every streaming recognizer emits these artifacts, so the filter lives beside the
/// transcript rather than inside one provider's wire contract.
public enum TranscriptFiltering {
    /// Stock non-speech hallucinations transcription models emit when VAD fires on silence — mostly
    /// YouTube-caption artifacts absorbed in training. Lower-cased, punctuation stripped; matched only
    /// against a whole utterance (see `meaningfulTranscript`) so a real sentence containing these words
    /// survives. Conservative on purpose — add only well-attested phrases here. Applied to the `.me`
    /// side only. "bye" is deliberately absent: it is a well-formed sign-off, and the punctuation
    /// filter already catches the lone-"." artifact.
    static let hallucinationDenylist: Set<String> = [
        "you", "thank you", "thank you very much", "thanks", "thanks for watching",
        "thank you for watching", "please subscribe",
    ]

    /// Returns the utterance trimmed if it is real speech, else nil. Drops two kinds of non-speech:
    ///   1. punctuation/whitespace-only output (a lone "." has no letter or digit) — both speakers, and
    ///   2. an utterance that, normalized, is exactly a known caption-artifact phrase — `.me` only.
    ///
    /// `speaker` scopes the phrase denylist: a bare "Thank you."/"Thanks" is a silence hallucination on
    /// the *me* (mic) side but a real turn-ending reply on the *them* (system-audio) side.
    /// Letting either through logs a phantom `heard` line, resets the silence timer, and fires a turn.
    public static func meaningfulTranscript(_ raw: String, speaker: Speaker) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        if speaker == .me {
            // Strip only the trailing punctuation the transcriber actually emits; no apostrophe (it
            // belongs inside contractions, and trimming it could mangle a legitimately-quoted word).
            let normalized = trimmed.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?…\" "))
            guard !hallucinationDenylist.contains(normalized) else { return nil }
        }
        return trimmed
    }
}
```

In `Sources/JarvisCore/Transcription/RealtimeSession.swift`, delete `hallucinationDenylist` and `meaningfulTranscript` (lines 212-239) and have `completedTranscript` delegate:

```swift
        return TranscriptFiltering.meaningfulTranscript(text, speaker: speaker)
```

If `Tests/JarvisCoreTests/Transcription/RealtimeSessionTests.swift` calls `RealtimeSession.meaningfulTranscript` directly, repoint those calls at `TranscriptFiltering.meaningfulTranscript` — the behavior is identical, only the owner moved.

- [ ] **Step 4: Implement the Gemini wire contract**

Create `Sources/JarvisCore/Transcription/GeminiLiveSession.swift`:

```swift
import Foundation

/// Pure builders and parsers for the Gemini Live transcription socket — extracted from the WebSocket
/// client so the wire contract is unit-testable (the live socket is not). Verified against Google's
/// Live API transcription guide (2026-09).
public enum GeminiLiveSession {
    private static let endpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    /// Gemini authenticates with a query parameter rather than a header, so the key is part of the
    /// URL. Never log this value — log `redactedEndpoint` instead.
    public static func connectURL(apiKey: String) -> URL {
        var components = URLComponents(string: endpoint)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return components.url!
    }

    /// The endpoint without its credential-bearing query, safe for diagnostics.
    public static let redactedEndpoint = endpoint

    /// The opening `setup` frame. The socket is not usable until the server acknowledges it, which
    /// `isSetupComplete` detects — an open socket alone does not prove the model or the audio format
    /// was accepted.
    ///
    /// `languageCodes` is always sent, including empty: `[]` is what selects automatic detection
    /// across every language Gemini supports, rather than an omission the server would have to guess at.
    public static func setupMessage(
        model: GeminiTranscriptionModel,
        languages: [TranscriptionLanguage] = [],
        vocabulary: [String] = [],
        mode: GeminiTranscriptionMode = .verbatim
    ) -> [String: Any] {
        var transcription: [String: Any] = [
            "languageCodes": TranscriptionLanguage.canonicalizing(languages).map(\.multipleHint),
            "mode": mode.wireValue,
        ]
        if !vocabulary.isEmpty {
            transcription["customVocabulary"] = vocabulary
        }
        return [
            "setup": [
                "model": model.wireModelName,
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": transcription,
            ],
        ]
    }

    /// One audio chunk. The rate travels in the mime type and must match the PCM actually sent.
    public static func audioFrame(base64PCM: String, sampleRate: Int) -> [String: Any] {
        ["realtimeInput": ["audio": [
            "data": base64PCM,
            "mimeType": "audio/pcm;rate=\(sampleRate)",
        ]]]
    }

    /// Tells the server no more audio is coming so it can finalize the last utterance.
    public static func audioStreamEnd() -> [String: Any] {
        ["realtimeInput": ["audioStreamEnd": true]]
    }

    /// The server's acknowledgement that the requested model and transcription config were accepted.
    public static func isSetupComplete(_ event: [String: Any]) -> Bool {
        event["setupComplete"] != nil
    }

    /// Finalized transcript text, if this event carries real speech.
    ///
    /// Only `inputTranscription` counts. `interimInputTranscription` is a speculative hypothesis that
    /// is revised while the speaker is still talking; appending it would log phantom turns and reset
    /// the silence timer mid-utterance.
    public static func finalTranscript(from event: [String: Any], speaker: Speaker) -> String? {
        guard let content = event["serverContent"] as? [String: Any],
              let transcription = content["inputTranscription"] as? [String: Any],
              let text = transcription["text"] as? String else { return nil }
        return TranscriptFiltering.meaningfulTranscript(text, speaker: speaker)
    }

    /// Classify only failures that cannot recover on a reconnect. An unrecognized or transient status
    /// stays diagnostic, so one bad frame never tears down an otherwise usable session.
    public static func terminalFailure(from event: [String: Any]) -> TranscriptionFailureReason? {
        guard let error = event["error"] as? [String: Any] else { return nil }
        let status = (error["status"] as? String)?.uppercased()
        switch status {
        case "UNAUTHENTICATED": return .authenticationFailed
        case "RESOURCE_EXHAUSTED": return .quotaExceeded
        case "PERMISSION_DENIED": return .accessDenied
        case "INVALID_ARGUMENT", "NOT_FOUND", "FAILED_PRECONDITION": return .configurationRejected
        default: return nil
        }
    }
}
```

- [ ] **Step 5: Run the Gate**

Run: `swift build && ./scripts/run-tests.sh`
Expected: build succeeds; all new `GeminiLiveSessionTests` and `TranscriptFilteringTests` pass, existing tests unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/JarvisCore/Transcription Tests/JarvisCoreTests/Transcription
git commit -m "$(cat <<'EOF'
feat(transcription): add the Gemini Live wire contract

Pure builders and parsers for the Gemini transcription socket, unit
tested the way the OpenAI Realtime contract already is. The hallucination
filter moves beside the transcript, since every streaming recognizer
emits those artifacts rather than only OpenAI.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Diw4AKtt8yvZ5u4zQBSiEX
EOF
)"
```

---

### Task 8: The Gemini transcriber

**Files:**
- Create: `Sources/JarvisApp/Capture/GeminiLiveTranscriber.swift`
- Modify: `Sources/JarvisApp/Capture/TranscriptionSessionFactory.swift:19-74`
- Modify: `Sources/JarvisApp/App/AppDelegate.swift` (the `apiKey:` argument at the factory call site)

**Interfaces:**
- Consumes: `GeminiLiveSession`, `TranscriptionCoachingCoordinator`, `RealtimeContinuityReporter`, `TranscriptionSession`, `TranscriptionConfiguration`.
- Produces: `final class GeminiLiveTranscriber: NSObject, TranscriptionSession, URLSessionWebSocketDelegate, @unchecked Sendable` with `init(apiKey:model:expectedLanguages:vocabularyKeywords:mode:audioFormat:speaker:transcript:clock:sessionStart:silenceTimeout:silenceMaxInterval:silenceIdleCutoff:transcriptBatchingWindow:maxBufferedAudioSeconds:readyTimeout:pingInterval:pongTimeout:networkStatus:activity:benchmark:)` and `func updateAPIKey(_ key: String)`.

**Reference implementation:** `Sources/JarvisApp/Capture/RealtimeTranscriber.swift` is the model for socket lifecycle, backoff, ping/pong, and buffering. Read it before writing this file and mirror its structure, its locking discipline, and its `@unchecked Sendable` rationale comment. Omit everything ledger- or commit-related: `RealtimeTranscriptionLedger`, `RealtimeJarvisManagedTurnCoordinator`, `recordLocalSpeechEvent`, and the client-commit path have no Gemini analogue.

- [ ] **Step 1: Write the transcriber**

Create `Sources/JarvisApp/Capture/GeminiLiveTranscriber.swift`. Required behavior, each point non-optional:

1. **Connect.** Open a `URLSessionWebSocketTask` to `GeminiLiveSession.connectURL(apiKey:)`, send `setupMessage(...)` immediately, and emit `.connecting`. Emit `.ready` only after `GeminiLiveSession.isSetupComplete` sees the acknowledgement. If it does not arrive within `readyTimeout`, treat it as a transient failure and retry with backoff.
2. **Never log the key.** Every `jlog` naming the endpoint uses `GeminiLiveSession.redactedEndpoint`. Never interpolate the connect URL.
3. **Send audio.** In `sendAudio(_:sequenceNumber:capturedAt:)`, base64-encode the PCM as received (capture already delivers `audioFormat`'s rate — do not resample here) and send `GeminiLiveSession.audioFrame(base64PCM:sampleRate: audioFormat.sampleRate)`. While disconnected, buffer, dropping oldest first once buffered audio exceeds `maxBufferedAudioSeconds` measured with `audioFormat.duration(forByteCount:)`.
4. **Receive.** On each message, in order: if `terminalFailure(from:)` is non-nil, report it once through `onTerminalFailure` and stop; if `isSetupComplete`, mark ready; if `finalTranscript(from:speaker:)` is non-nil, hand the text to the coaching coordinator. Ignore everything else, logging unknown message kinds through `jlog` only.
5. **Interim text never reaches Activity or the transcript.** `finalTranscript` already enforces this; do not add an interim path.
6. **Coordinator.** Construct `TranscriptionCoachingCoordinator` exactly as `RealtimeTranscriber` does (same `speaker`, `transcript`, `clock`, `sessionStart`, `transcriptBatchingWindow`, silence parameters, `activity`), forwarding its callbacks to this type's `onTurnEnd` / `onSilence` / `onTranscriptionWorkChanged`.
7. **Heartbeat.** Drive `RealtimeContinuityReporter` from `recordCapturedAudio(sequenceNumber:sampleCount:capturedAt:)` and forward its edges to `onCaptureHeartbeat`, mirroring `RealtimeTranscriber`.
8. **Reconnect.** On non-terminal socket closure while not stopped, emit `.reconnecting(attempt:)` and retry with the same backoff schedule `RealtimeTranscriber` uses. Send the setup message again on every new socket.
9. **Stop.** `stop()` sends `GeminiLiveSession.audioStreamEnd()` best-effort, cancels the socket and timers, emits `.stopped`, and is idempotent.
10. **`updateAPIKey(_:)`** stores the new key for the *next* connection only, leaving a healthy live socket untouched — matching `RealtimeTranscriber.updateAPIKey`.
11. **Do not implement `recordLocalSpeechEvent`.** The protocol's default no-op is correct: Gemini detects turns server-side.

Skeleton — the declarations and the receive path, where the provider-specific decisions live. Fill the socket lifecycle, backoff, ping/pong, and buffering in from `RealtimeTranscriber`:

```swift
import Foundation
import JarvisCore

/// Live transcription over the Gemini Live socket. Mirrors `RealtimeTranscriber`'s lifecycle —
/// setup-acknowledged readiness, backoff reconnect, ping/pong liveness, bounded offline buffering —
/// but carries no ledger or commit path: Gemini finalizes each utterance server-side, so there are
/// no out-of-order items to reconcile.
/// `@unchecked Sendable`: every mutable field is guarded by `lock`; collaborators are Sendable.
final class GeminiLiveTranscriber: NSObject, TranscriptionSession, URLSessionWebSocketDelegate,
    @unchecked Sendable {
    var onTurnEnd: (@Sendable (_ transcriptBoundary: Int) -> Void)?
    var onSilence: (@Sendable (TimeInterval) -> Void)?
    var onTranscriptionWorkChanged: (@Sendable (Bool) -> Void)?
    var onConnectionStateChange: (@Sendable (TranscriptionConnectionState) -> Void)?
    var onTerminalFailure: (@Sendable (TranscriptionFailureReason) -> Void)?
    var onCaptureHeartbeat: (@Sendable (CaptureHeartbeat) -> Void)?

    private let model: GeminiTranscriptionModel
    private let expectedLanguages: [TranscriptionLanguage]
    private let vocabularyKeywords: [String]
    private let mode: GeminiTranscriptionMode
    private let audioFormat: TranscriptionAudioFormat
    private let speaker: Speaker
    private var coachingCoordinator: TranscriptionCoachingCoordinator!
    private let continuityReporter: RealtimeContinuityReporter

    private let lock = NSLock()
    private var apiKey: String            // guarded by lock; used on the NEXT connect only
    private var socket: URLSessionWebSocketTask?
    private var isReady = false
    private var stopped = true
    private var terminalFailureReported = false
    private var bufferedAudio: [Data] = []
    private var bufferedByteCount = 0

    /// One received frame. Order matters: a terminal error outranks everything, and a setup
    /// acknowledgement must be seen before any transcript is trusted.
    private func handle(_ message: [String: Any]) {
        if let failure = GeminiLiveSession.terminalFailure(from: message) {
            reportTerminalFailureOnce(failure)
            return
        }
        if GeminiLiveSession.isSetupComplete(message) {
            markReady()
            return
        }
        if let text = GeminiLiveSession.finalTranscript(from: message, speaker: speaker) {
            // Gemini reports no per-utterance start time, so `spokenAt: nil` lets the coordinator
            // date the line from the session clock. `source` is debug-only detail, never Activity.
            coachingCoordinator.recordFinalizedTranscript(
                text, spokenAt: nil, source: "gemini-live")
            return
        }
        // Interim hypotheses and unknown frames are diagnostic only — never Activity, never the
        // transcript. See the ActivityLog contract in AGENTS.md.
        jlog("Jarvis: Gemini frame ignored (\(message.keys.sorted().joined(separator: ",")))")
    }

    func sendAudio(_ pcm: Data, sequenceNumber: UInt64, capturedAt: TimeInterval) {
        // Capture already delivers `audioFormat`'s rate — never resample here.
        let frame = GeminiLiveSession.audioFrame(
            base64PCM: pcm.base64EncodedString(), sampleRate: audioFormat.sampleRate)
        send(frame, bufferingIfDisconnected: pcm)
    }
}
```

Two coordinator calls complete the wiring, both mirroring `RealtimeTranscriber`: `start()` when the session begins and `stop()` on teardown, and `updateTranscriptionWork(_:)` — pass `true` while a socket is disconnected or reconnecting with buffered audio still unsent, `false` once the socket is ready and the buffer is drained. That flag is what lets a turn wait for a transcript still in flight.

- [ ] **Step 2: Add the factory case**

In `Sources/JarvisApp/Capture/TranscriptionSessionFactory.swift`, add to the switch:

```swift
        case .gemini:
            GeminiLiveTranscriber(
                apiKey: apiKey,
                model: configuration.geminiModel,
                expectedLanguages: configuration.geminiExpectedLanguages,
                vocabularyKeywords: configuration.geminiVocabularyKeywords,
                mode: configuration.geminiMode,
                audioFormat: configuration.provider.audioFormat,
                speaker: speaker,
                transcript: transcript,
                clock: clock,
                sessionStart: sessionStart,
                silenceTimeout: config.silenceTimeoutSeconds,
                silenceMaxInterval: config.silenceMaxIntervalSeconds,
                silenceIdleCutoff: speaker == .me
                    ? config.silenceIdleCutoffSeconds
                    : .infinity,
                transcriptBatchingWindow: config.transcriptBatchingWindowSeconds,
                maxBufferedAudioSeconds: config.maxBufferedAudioSeconds,
                readyTimeout: config.realtimeReadyTimeoutSeconds,
                pingInterval: config.realtimePingIntervalSeconds,
                pongTimeout: config.realtimePongTimeoutSeconds,
                networkStatus: networkStatus,
                activity: activity,
                benchmark: benchmark)
```

The factory's `apiKey` parameter is currently the OpenAI key. In `AppDelegate.start()`, pass the key matching the selected provider:

```swift
        let transcriptionKey = transcriptionProvider.ownCredential
            .flatMap { secrets.apiKey(for: $0) } ?? ""
```

and hand `transcriptionKey` to the factory, leaving the existing `key` (OpenAI) for the brain.

- [ ] **Step 3: Extend the running-session key update**

`applySavedAPIKeyToRunningSession(_:)` currently casts to `RealtimeTranscriber`. Add the Gemini cast so a saved Gemini key reaches a live Gemini session on its next reconnect:

```swift
        (transcriber as? GeminiLiveTranscriber)?.updateAPIKey(key)
        (themTranscriber as? GeminiLiveTranscriber)?.updateAPIKey(key)
```

Guard it so an OpenAI key is not written into a Gemini session: only call the Gemini casts when the saved credential is `.geminiAPIKey`. Adjust the `onKeySaved` closure at `AppDelegate.swift:203` to carry the credential alongside the key.

- [ ] **Step 4: Run the Gate**

Run: `swift build && ./scripts/run-tests.sh`
Expected: build succeeds, all tests pass. The socket itself is verified by smoke test in Task 10, not by unit tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/JarvisApp/Capture Sources/JarvisApp/App/AppDelegate.swift
git commit -m "$(cat <<'EOF'
feat(transcription): add the Gemini Live transcription adapter

A WebSocket TranscriptionSession for gemini-3.5-transcribe-live, reusing
the provider-neutral coaching coordinator and continuity reporter. It
carries no ledger or commit path: Gemini finalizes turns server-side, so
there are no out-of-order items to reconcile.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Diw4AKtt8yvZ5u4zQBSiEX
EOF
)"
```

---

### Task 9: Settings UI

**Files:**
- Modify: `Sources/JarvisApp/Settings/TranscriptionControls.swift:24-27,144-185`
- Modify: `Sources/JarvisApp/Settings/ConnectionsSection.swift:11-30,47-63,167-186`

**Interfaces:**
- Consumes: `APIKeyControls.init(credential:store:onKeySaved:)` (Task 2), Gemini preferences (Task 6).
- Produces: no new public API.

- [ ] **Step 1: Replace the two-state provider branch with a per-provider row list**

`TranscriptionControls` branches on `preferences.provider == .openAI`, which no longer describes three providers. Add a single source of truth for which rows a provider shows, and drive height, visibility, and layout from it.

Add the Gemini controls as stored properties alongside the existing ones (`geminiModelRow`, `geminiLanguagesRow`, `geminiVocabularyRow`, `geminiModeRow`, `geminiVocabularyField`), built in `makeView` exactly like their OpenAI counterparts but bound to the Gemini preferences. The mode row is an `NSPopUpButton` over `GeminiTranscriptionMode.allCases` using `displayName`, with detail text `"Smart removes filler words"`.

Then:

```swift
    /// The rows one provider shows, top to bottom. The provider row is always first.
    private var visibleRows: [SettingsRowView] {
        switch preferences.provider {
        case .openAI:
            [providerRow, modelRow, languagesRow, vocabularyRow].compactMap { $0 }
        case .gemini:
            [providerRow, geminiModelRow, geminiLanguagesRow,
             geminiVocabularyRow, geminiModeRow].compactMap { $0 }
        case .appleSpeech:
            [providerRow, localeRow].compactMap { $0 }
        }
    }

    var preferredHeight: CGFloat {
        SettingsStyle.cardHeaderHeight + CGFloat(visibleRows.count) * SettingsStyle.rowHeight
    }
```

`applyState()` hides every row not in `visibleRows`; `layoutRows()` iterates `visibleRows` instead of its hand-built array. Add `geminiVocabularyChanged(_:)`, `geminiLanguagesChanged(_:)`, `geminiModelChanged(_:)`, and `geminiModeChanged(_:)` mirroring the OpenAI handlers, each ending with the same `jlog` "selected for the next Start" phrasing.

Note `preferredHeight` is read before `makeView` runs (rows are still nil), so it must return the header-only height in that state — `compactMap` already yields an empty list, which is correct.

- [ ] **Step 2: Make Connections a card list**

In `ConnectionsSection`, replace the OpenAI-only control and the three hardcoded provider/height arrays with one ordered list.

```swift
    private let apiKeyControls: [Credential: APIKeyControls]
    private static let credentialOrder: [Credential] = [.openAIAPIKey, .geminiAPIKey]
    private static let cliProviders: [BrainProvider] = [.claudeCode, .codexCLI]
```

Build one `APIKeyControls` per credential in `init`, add one card per credential in `makeView` (in `credentialOrder`), and iterate `cliProviders` for the CLI cards. `refreshDetection()` and `renderStatuses()` iterate `Self.cliProviders` rather than a repeated literal. `recalculateDocumentHeight()` sums the live card heights instead of a hand-listed array:

```swift
        let visibleHeights = Self.credentialOrder.compactMap { apiKeyControls[$0]?.preferredHeight }
            + Self.cliProviders.map { _ in Self.cliCardHeight }
```

`renderPageStatus()` counts every saved key:

```swift
        let savedKeyCount = apiKeyControls.values.filter(\.hasSavedKey).count
        let readyCount = signedInCount + savedKeyCount
```

Each credential's height constraint is tracked in a `[Credential: NSLayoutConstraint]` rather than the single `apiKeyHeightConstraint`.

- [ ] **Step 3: Run the Gate**

Run: `swift build && ./scripts/run-tests.sh`
Expected: build succeeds, all tests pass.

- [ ] **Step 4: Verify in the running app**

Run: `./scripts/build-app.sh --run`
Then check, in the app:
- Settings → Connections shows three cards: OpenAI API, Gemini API, Claude Code, Codex CLI — with no clipped or overlapping rows and no dead space below the last card.
- Saving a Gemini key flips its badge to "Key saved" and increments the "N ready" count.
- Settings → Brain → Transcription: choosing Gemini shows model, expected languages, vocabulary, and mode; choosing OpenAI shows the original four rows; choosing Apple Speech shows the locale row. The card resizes cleanly between all three.

- [ ] **Step 5: Commit**

```bash
git add Sources/JarvisApp/Settings
git commit -m "$(cat <<'EOF'
feat(settings): add Gemini transcription and credential controls

Connections becomes an ordered card list rather than three hand-listed
arrays, and the Transcription card drives visibility, height, and layout
from one per-provider row list instead of an is-OpenAI bool that no
longer describes three providers.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Diw4AKtt8yvZ5u4zQBSiEX
EOF
)"
```

---

### Task 10: Provider-neutral failure copy, docs, and live smoke

**Files:**
- Modify: `Sources/JarvisCore/Transcription/TranscriptionFailureReason.swift:14-28`
- Modify: `Sources/JarvisCore/Diagnostics/UserFacingError+Catalog.swift:9-12`
- Modify: `wiki/settings-window.md`, `wiki/architecture.md`, `wiki/status.md`
- Test: `Tests/JarvisCoreTests/Diagnostics/` (whichever suite asserts this copy — find with `grep -rn "rejected the API key" Tests`)

**Interfaces:**
- Consumes: everything above.
- Produces: no new API.

- [ ] **Step 1: Make the Activity copy provider-neutral**

Four of the six `activityDescription` cases name OpenAI, which becomes wrong when Gemini fails. These strings are written into the user-facing Activity log, so they must stay fixed and accurate for any provider:

```swift
        case .quotaExceeded:
            "the transcription API quota is exhausted; check billing"
        case .authenticationFailed:
            "the transcription provider rejected the API key; check Settings → Connections"
        case .accessDenied:
            "the transcription provider denied access; check your API project"
        case .configurationRejected:
            "the transcription provider rejected the configuration; check jarvis-debug.log"
```

Update `UserFacingError.noAPIKey` the same way — it is raised for any missing credential now:

```swift
    /// No API key on Start for the selected transcription provider or a configured brain target.
    static var noAPIKey: UserFacingError {
        .init(title: "Missing API key",
              message: "The selected transcription provider or brain route needs an API key. Open \u{201C}Settings\u{2026}\u{201D} \u{2192} Connections, paste the missing key, then press Start.",
              severity: .fatal,
              sessionEndReason: .openAIAPIKeyMissing)
    }
```

Leave `SessionEndReason.openAIAPIKeyMissing`'s case name alone — it is persisted in session records; renaming it would invalidate existing logs for no user-visible gain.

Update any test asserting the old strings to the new ones. These are deliberate copy changes, not test breakage to work around.

- [ ] **Step 2: Run the Gate**

Run: `swift build && ./scripts/run-tests.sh`
Expected: build succeeds, all tests pass.

- [ ] **Step 3: Update the wiki**

Read `wiki/AGENTS.md` first — it governs wiki edits. Then:
- `wiki/settings-window.md`: Connections now lists four cards (OpenAI API, Gemini API, Claude Code, Codex CLI); the Transcription card's rows are per-provider, with Gemini's model/languages/vocabulary/mode.
- `wiki/architecture.md` (Models and APIs): the Gemini Live wire contract, its server-owned turn detection (no client commit, no ledger), and why the wire sample rate is provider-derived — including that 16 kHz is sufficient for recognition, so the rate is a provider requirement rather than a quality setting.
- `wiki/status.md`: add Gemini to the provider list and add its live smoke check.

- [ ] **Step 4: Check the benchmark harness**

`TranscriptionBenchmarkRunner` carries `requiredProviders: Set<TranscriptionProvider>`. Confirm whether adding a case breaks an exhaustive switch or a fixture:

```bash
grep -rn "requiredProviders" Sources
```

If the benchmark cannot run Gemini yet, leave it unsupported explicitly rather than silently — and say so in `wiki/transcription-benchmark.md`.

- [ ] **Step 5: Live smoke test**

Run: `./scripts/build-app.sh --run`

Verify, with a real Gemini key saved:
1. Selecting Gemini and pressing Start with no Gemini key refuses the Start and names the missing credential.
2. With the key saved, Start reaches the ready state and speech on the mic appears in Activity as `heard` lines.
3. System-audio speech appears from the other side.
4. `jarvis-debug.log` shows the Gemini endpoint **without** a `key=` query anywhere: `grep -c "key=" .jarvis/*/jarvis-debug.log` must print `0`.
5. Switching back to OpenAI and starting again still works — the primary path is unregressed.

- [ ] **Step 6: Commit**

```bash
git add Sources/JarvisCore wiki Tests
git commit -m "$(cat <<'EOF'
fix(transcription): stop naming OpenAI in shared failure copy

These notices are written to the user-facing Activity log and are raised
for whichever provider failed, so naming OpenAI is wrong once a second
provider can fail. Documents the Gemini wire contract and the
provider-derived audio format in the wiki.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Diw4AKtt8yvZ5u4zQBSiEX
EOF
)"
```

- [ ] **Step 7: Open the pull request**

```bash
git push -u origin feat/gemini-transcription
gh pr create --repo JINGBANZ/jarvis \
  --title "feat(transcription): add Gemini as a transcription provider" \
  --body "See docs/superpowers/specs/2026-09-04-gemini-transcription-design.md"
```
