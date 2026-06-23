# Device Audio Rate Adaptation & Fail-Loud Startup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Jarvis capture audio on any input device (AirPods/USB/44.1 kHz, not just 48 kHz hardware) by reading the device's native rate and resampling into AEC3, and surface every startup failure through one centralized error module instead of failing silently.

**Architecture:** Stop pinning the CoreAudio aggregate to 48 kHz; read its actual nominal rate and resample mic+tap up to a fixed 48 kHz before AEC3 (the one-clock aggregate and AEC config are untouched). Add a Foundation-only `UserFacingError` model in `JarvisCore` and a `@MainActor` `ErrorReporter` in `JarvisApp` that owns all `NSAlert` presentation and session teardown, driven by error severity. Every failure site reports through it.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, CoreAudio (aggregate device, IOProc), AVAudioConverter (resampling), WebRTC AEC3 (via `CJarvisAEC`), swift-testing.

## Global Constraints

- **Swift 6 strict concurrency** is on. Respect actor isolation and `Sendable`. No `@unchecked`/`nonisolated(unsafe)` without a written reason. (`AggregateEchoCapture` is already `@unchecked Sendable` with a documented reason — extend it, don't add new unsafe.)
- **`JarvisCore` is Foundation-only** — no AppKit/AVFoundation/etc. `UserFacingError` goes in Core; anything touching `NSAlert` goes in `JarvisApp`.
- **One primary type per file**, file named exactly after the type.
- **Build:** `swift build`. **Test:** `./scripts/run-tests.sh` (never raw `swift test`).
- **Branch, don't commit to `main`.** Commit subjects: capitalized imperative ("Add…", "Fix…").
- **No secrets** in code/tests/examples.

---

### Task 0: Create the working branch

**Files:** none (git only)

- [ ] **Step 1: Branch off main in this worktree**

Run:
```bash
git checkout -b device-rate-adaptation-fail-loud
```
Expected: `Switched to a new branch 'device-rate-adaptation-fail-loud'`

- [ ] **Step 2: Commit the already-written design doc**

```bash
git add docs/design/device-audio-rate-adaptation.html docs/superpowers/plans/2026-06-23-device-rate-adaptation-and-fail-loud.md
git commit -m "Add device-rate-adaptation design note and implementation plan"
```

---

### Task 1: `UserFacingError` model (JarvisCore)

The error model every failure constructs. Foundation-only and unit-testable. Severity carries the *decision* (alert? stop the session?) as pure properties so the App-layer presenter stays a thin renderer.

**Files:**
- Create: `Sources/JarvisCore/Diagnostics/UserFacingError.swift`
- Test: `Tests/JarvisCoreTests/Diagnostics/UserFacingErrorTests.swift`

**Interfaces:**
- Produces:
  - `public struct UserFacingError: Error, Sendable, Equatable` with `public let title: String`, `public let message: String`, `public let severity: Severity`, and `public init(title:message:severity:)`.
  - `public enum Severity: Sendable, Equatable { case fatal, degraded, info }` with `public var showsAlert: Bool` and `public var stopsSession: Bool`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import JarvisCore

@Suite struct UserFacingErrorTests {
    @Test func fatalAlertsAndStops() {
        #expect(UserFacingError.Severity.fatal.showsAlert)
        #expect(UserFacingError.Severity.fatal.stopsSession)
    }

    @Test func degradedNeitherAlertsNorStops() {
        #expect(!UserFacingError.Severity.degraded.showsAlert)
        #expect(!UserFacingError.Severity.degraded.stopsSession)
    }

    @Test func infoNeitherAlertsNorStops() {
        #expect(!UserFacingError.Severity.info.showsAlert)
        #expect(!UserFacingError.Severity.info.stopsSession)
    }

    @Test func carriesFields() {
        let e = UserFacingError(title: "T", message: "M", severity: .fatal)
        #expect(e.title == "T")
        #expect(e.message == "M")
        #expect(e.severity == .fatal)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/run-tests.sh`
Expected: FAIL — `cannot find 'UserFacingError' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// A failure worth showing the user. The model is Foundation-only and lives in Core so the decision
/// of *how loud* a failure is (alert? stop the session?) is unit-testable; the App-layer `ErrorReporter`
/// only renders it. Construct one at any failure site and hand it to the reporter.
public struct UserFacingError: Error, Sendable, Equatable {
    /// How the reporter should react. `.fatal` interrupts the user and tears the session down;
    /// `.degraded` is a non-blocking notice (the session keeps running); `.info` is log-only.
    public enum Severity: Sendable, Equatable {
        case fatal
        case degraded
        case info

        /// Whether the reporter pops a modal alert for this severity.
        public var showsAlert: Bool { self == .fatal }
        /// Whether the reporter tears down the running session for this severity.
        public var stopsSession: Bool { self == .fatal }
    }

    public let title: String
    public let message: String
    public let severity: Severity

    public init(title: String, message: String, severity: Severity) {
        self.title = title
        self.message = message
        self.severity = severity
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/run-tests.sh`
Expected: PASS (all three test targets build; the new tests pass).

- [ ] **Step 5: Commit**

```bash
git add Sources/JarvisCore/Diagnostics/UserFacingError.swift Tests/JarvisCoreTests/Diagnostics/UserFacingErrorTests.swift
git commit -m "Add UserFacingError model with severity-driven presentation rules"
```

---

### Task 2: `ErrorReporter` + wire into AppDelegate (JarvisApp)

The one place `NSAlert` is created and the one place a fatal error tears the session down. Replace the bespoke `warnNoKey` with a report through it (proves the funnel before the capture work depends on it).

**Files:**
- Create: `Sources/JarvisApp/App/ErrorReporter.swift`
- Modify: `Sources/JarvisApp/App/AppDelegate.swift` (add property + `onFatal` wiring; replace `warnNoKey`)

**Interfaces:**
- Consumes: `UserFacingError`, `UserFacingError.Severity` (Task 1).
- Produces:
  - `@MainActor final class ErrorReporter` with `var onFatal: (() -> Void)?` and `nonisolated func report(_ error: UserFacingError)`.

- [ ] **Step 1: Create `ErrorReporter`**

```swift
import AppKit
import JarvisCore

/// The single funnel for user-facing failures. Every error in the app is reported here; severity
/// decides the response — `.fatal` pops a modal alert AND tears the session down (`onFatal`),
/// `.degraded`/`.info` are logged only. `NSAlert` exists nowhere else.
///
/// Diagnostics stay in `JarvisLog`/`jlog` (it still owns the debug + activity logs); this type owns
/// *user-facing surfacing + session-lifecycle consequence*. `report(_:)` is `nonisolated` so any
/// thread (the capture IOProc, a URLSession delegate) can call it directly; it hops to the main actor.
@MainActor
final class ErrorReporter {
    /// Invoked for a `.fatal` error (on the main actor) to stop the running session and correct the
    /// menu. Wired by `AppDelegate` once the menu bar exists.
    var onFatal: (() -> Void)?

    nonisolated func report(_ error: UserFacingError) {
        Task { @MainActor in self.present(error) }
    }

    private func present(_ error: UserFacingError) {
        jlog("Jarvis: \(error.severity) — \(error.title): \(error.message)")  // diagnostics still go to JarvisLog
        if error.severity.stopsSession { onFatal?() }
        guard error.severity.showsAlert else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = error.title
        alert.informativeText = error.message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
```

- [ ] **Step 2: Add the property and wire `onFatal` in AppDelegate**

In `Sources/JarvisApp/App/AppDelegate.swift`, add the property near the other `private let` members (after line 11):

```swift
    /// The single funnel for user-facing failures (alerts + fatal session teardown). See `ErrorReporter`.
    private let errorReporter = ErrorReporter()
```

Then in `applicationDidFinishLaunching(_:)`, after the menu bar is constructed (find where `menuBar` is assigned), wire the fatal consequence:

```swift
        // A fatal error tears the session down and corrects the menu — one place owns that.
        errorReporter.onFatal = { [weak self] in
            self?.stop()
            self?.menuBar.setRunning(false)
        }
```

> NOTE for the implementer: `menuBar` is assigned in `applicationDidFinishLaunching`. Place this wiring AFTER that assignment so `menuBar` is non-nil when `onFatal` fires. If unsure, put it as the last line of `applicationDidFinishLaunching`.

- [ ] **Step 3: Replace `warnNoKey` with a report**

In `start()`, replace the no-key branch (currently lines 116-120):

```swift
        guard let key = secrets.apiKey(), !key.isEmpty else {
            jlog("Jarvis: can't start — no API key.")
            errorReporter.report(UserFacingError(
                title: "No OpenAI API key set",
                message: "Open \u{201C}Settings\u{2026}\u{201D} from the Jarvis menu, paste your key, then press Start.",
                severity: .fatal))
            return false
        }
```

Then delete the now-unused `warnNoKey()` method (currently lines 222-229).

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!` with no errors. (No new warnings about actor isolation — `report` is `nonisolated`, `present`/`onFatal` are main-actor.)

- [ ] **Step 5: Commit**

```bash
git add Sources/JarvisApp/App/ErrorReporter.swift Sources/JarvisApp/App/AppDelegate.swift
git commit -m "Add ErrorReporter as the single funnel for user-facing failures"
```

---

### Task 3: Device-rate adaptation in `AggregateEchoCapture`

Remove the 48 kHz pin; read the device's actual rate, resample mic+tap up to 48 kHz before AEC (nil resamplers when already 48 kHz, so the built-in path is unchanged). `start()`/`buildAudioLocked()` return a failure *reason* string; `onUnavailable` carries it.

**Files:**
- Modify: `Sources/JarvisApp/Capture/AggregateEchoCapture.swift`

**Interfaces:**
- Consumes: `Resampler(fromHz:toHz:)`, `WebRTCEchoCanceller`, `PCM16Framer` (existing).
- Produces (changed signatures consumed by Task 4):
  - `func start() -> String?` (nil = success, non-nil = human-readable failure reason)
  - `var onUnavailable: (@Sendable (String) -> Void)?` (now carries a reason)

- [ ] **Step 1: Add up-resampler properties and the AEC-rate constant**

Replace the resampler property block (currently lines 34-36):

```swift
    private let aec = WebRTCEchoCanceller()          // adaptive; re-converges across route rebuilds
    private let micDown = Resampler(fromHz: 48_000, toHz: 24_000)   // cleaned mic → 24 kHz wire
    private let sysDown = Resampler(fromHz: 48_000, toHz: 24_000)   // tap → 24 kHz wire
    /// Device-native → 48 kHz, rebuilt per `buildAudioLocked` from the aggregate's actual rate. `nil`
    /// when the device is already 48 kHz (then mic/tap feed AEC directly — the built-in path, unchanged).
    /// Touched only by the IOProc thread (read in `handle`) and by build/rebuild under `lock` while the
    /// device is stopped — same discipline as `procID`/`aggregateID`, covered by `@unchecked Sendable`.
    private var micUp: Resampler?
    private var sysUp: Resampler?

    private static let aecRate = 48_000.0
```

- [ ] **Step 2: Change `onUnavailable` to carry a reason**

Replace line 27-28:

```swift
    /// Fired if the device can't be built/started mid-session (route-change rebuild) — the caller
    /// decides how to surface it. Carries a human-readable reason.
    var onUnavailable: (@Sendable (String) -> Void)?
```

- [ ] **Step 3: Make `start()` return a failure reason**

Replace `start()` (currently lines 49-60):

```swift
    /// Build + start capture. Returns `nil` on success, or a human-readable reason on failure (the
    /// caller surfaces it via `ErrorReporter`). Mid-session rebuild failures go through `onUnavailable`.
    func start() -> String? {
        var reason: String?
        lock.lock()
        if #available(macOS 14.2, *), aec != nil, micDown != nil, sysDown != nil {
            reason = buildAudioLocked()
            if reason == nil { registerRouteListenersLocked() }
        } else {
            jlog("Jarvis: one-clock capture unavailable — needs macOS 14.2+ and AEC/resampler")
            reason = "Jarvis needs macOS 14.2 or later for echo-cancelled capture."
        }
        lock.unlock()
        return reason
    }
```

- [ ] **Step 4: Replace the 48 kHz pin with read-rate + build up-resamplers**

In `buildAudioLocked()`, replace the pin block (currently lines 108-113):

```swift
        // Don't fight the device's rate — read it. AEC3, the 480-sample framing, and the 48→24 resamplers
        // all run at 48 kHz, so resample the device-native rate up to 48 kHz before AEC (mic+tap come off
        // ONE clock, so they stay sample-synced; the far/near lockstep below absorbs converter slack).
        // If we can't read the rate, fail loud — assuming 48 kHz when it isn't would corrupt the echo
        // model and mislabel the wire rate (the exact thing the old pin guarded).
        guard let deviceRate = Self.nominalSampleRate(agg) else {
            jlog("Jarvis: capture — could not read the input device's sample rate")
            teardownAudioLocked(); return "Couldn't read the audio input device's sample rate."
        }
        if abs(deviceRate - Self.aecRate) < 1 {
            micUp = nil; sysUp = nil                         // already 48 kHz — feed AEC directly
        } else {
            guard let mu = Resampler(fromHz: deviceRate, toHz: Self.aecRate),
                  let su = Resampler(fromHz: deviceRate, toHz: Self.aecRate) else {
                jlog("Jarvis: capture — could not build \(Int(deviceRate))→48 kHz resampler")
                teardownAudioLocked()
                return "Couldn't prepare audio resampling for this input device (\(Int(deviceRate)) Hz)."
            }
            micUp = mu; sysUp = su
        }
```

> NOTE: `buildAudioLocked()` currently returns `Bool` (`return false` on failure, `return true` on success). Convert its signature to `-> String?` and convert EVERY existing failure return from `jlog("…"); teardownAudioLocked(); return false` to `jlog("…"); teardownAudioLocked(); return "<human reason>"`, and the final success `return true` to `return nil`. Do this in Steps 4–6.

- [ ] **Step 5: Convert `buildAudioLocked`'s signature and remaining returns**

Change the signature (line 75) and the earlier failure returns:

```swift
    private func buildAudioLocked() -> String? {
        guard #available(macOS 14.2, *) else { return "Jarvis needs macOS 14.2 or later." }
        guard let micUID = Self.defaultInputDeviceUID() else {
            jlog("Jarvis: capture — no default input device")
            return "No microphone is available. Connect an input device and press Start."
        }
```

Tap-creation failure (currently lines 85-87):

```swift
        guard AudioHardwareCreateProcessTap(tapDesc, &tap) == noErr, tap != kAudioObjectUnknown else {
            jlog("Jarvis: capture — process tap creation failed (audio-capture permission?)")
            return "Couldn't capture system audio. Grant Jarvis the audio-capture permission and press Start."
        }
```

Aggregate-creation failure (currently lines 102-105):

```swift
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg) == noErr,
              agg != kAudioObjectUnknown else {
            jlog("Jarvis: capture — aggregate device creation failed")
            teardownAudioLocked(); return "Couldn't build the audio capture device."
        }
```

IOProc-creation failure (currently lines 116-120):

```swift
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil, { [weak self] _, input, _, _, _ in
            self?.handle(input)
        }) == noErr, let proc else {
            jlog("Jarvis: capture — IOProc creation failed")
            teardownAudioLocked(); return "Couldn't start the audio capture callback."
        }
```

Device-start failure (currently lines 123-125):

```swift
        guard AudioDeviceStart(agg, proc) == noErr else {
            jlog("Jarvis: capture — device start failed")
            teardownAudioLocked(); return "Couldn't start the audio capture device."
        }
```

- [ ] **Step 6: Update the success log + return, and the rebuild call site**

Success tail (currently lines 126-127):

```swift
        jlog("Jarvis: capture started (mic+tap @\(Int(deviceRate)) Hz → AEC3 @48 kHz, AEC3 on).")
        return nil
    }
```

In `rebuild()` (currently lines 175-191), adapt to the `String?` return:

```swift
    private func rebuild() {
        var reason: String?
        lock.lock()
        if !stopped {
            teardownAudioLocked()
            reason = buildAudioLocked()
            if reason == nil { jlog("Jarvis: rebuilt capture after audio route change") }
        }
        lock.unlock()
        if let reason {
            jlog("Jarvis: capture rebuild failed after route change")
            onUnavailable?(reason)        // notify outside the lock
        }
    }
```

- [ ] **Step 7: Resample in the hot path**

Replace the mic/tap capture lines in `handle()` (currently lines 199-207):

```swift
        var mic = Self.monoInt16(buffers[0])
        var tap = Self.monoInt16(buffers[1])
        // Resample device-native → 48 kHz for AEC (no-ops to today's path when the device is already
        // 48 kHz and the up-resamplers are nil).
        if let micUp { mic = micUp.convert(mic) }
        if let sysUp { tap = sysUp.convert(tap) }
        // Keep far and near in lockstep AT THE AEC RATE: AEC3's reference and capture must advance by the
        // SAME sample count each callback, or the two framers drift apart for the rest of the session. The
        // tap can legitimately be short/empty (silence), and the two converters can emit a sample or two
        // apart — so pad/truncate the tap to the mic's count after resampling.
        if tap.count != mic.count {
            if tap.count < mic.count { tap.append(contentsOf: repeatElement(0, count: mic.count - tap.count)) }
            else { tap.removeLast(tap.count - mic.count) }
        }
```

> NOTE: `let mic` becomes `var mic`. The `aec.processReverse(tap)` / `aec.process(mic)` / `onMicClean` / `onSystem` lines below stay exactly as they are.

- [ ] **Step 8: Replace `setNominalSampleRate` with a read-only `nominalSampleRate`**

Replace the `setNominalSampleRate` helper (currently lines 230-242):

```swift
    /// Read a device's current nominal sample rate. Returns nil if it can't be read.
    private static func nominalSampleRate(_ dev: AudioObjectID) -> Double? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }
```

- [ ] **Step 9: Build**

Run: `swift build`
Expected: `Build complete!` with no errors. (Task 4 fixes the now-broken `capture.start()`/`onUnavailable` call sites in `AppDelegate`; if building alone fails ONLY there, that's expected — proceed to Task 4 and build at its end. If you want a clean build here, do Task 4 in the same sitting.)

- [ ] **Step 10: Commit**

```bash
git add Sources/JarvisApp/Capture/AggregateEchoCapture.swift
git commit -m "Adapt capture to any input rate (resample to AEC's 48 kHz; drop the pin)"
```

---

### Task 4: Route every startup failure through `ErrorReporter` (AppDelegate)

Wire the new capture reason + the transcriber terminal failures through `errorReporter`, and stop `start()` from returning `true` when capture didn't come up.

**Files:**
- Modify: `Sources/JarvisApp/App/AppDelegate.swift` (`start()` body)

**Interfaces:**
- Consumes: `ErrorReporter.report(_:)`, `UserFacingError` (Tasks 1–2); `AggregateEchoCapture.start() -> String?`, `onUnavailable: (@Sendable (String) -> Void)?` (Task 3).

- [ ] **Step 1: Report mic/them terminal failures through the funnel**

Replace `onMicTerminalFailure` / `onThemTerminalFailure` (currently lines 142-153):

```swift
        // Mic socket gave up (bad key / quota / network): coaching can't continue. Report fatal — the
        // reporter's onFatal stops the session and corrects the menu (no more lying 🟢).
        let onMicTerminalFailure: @Sendable () -> Void = { [errorReporter] in
            errorReporter.report(UserFacingError(
                title: "Microphone disconnected",
                message: "Jarvis lost the microphone connection (often a bad API key, quota, or network issue). Coaching has stopped.",
                severity: .fatal))
        }
        // "Them" socket gave up: degrade gracefully — stop the system-audio transcriber, keep the mic
        // running. Still report it (a non-blocking .degraded notice) so it flows through the one funnel.
        let onThemTerminalFailure: @Sendable () -> Void = { [weak self, errorReporter] in
            Task { @MainActor in self?.themTranscriber?.stop(); self?.themTranscriber = nil }
            errorReporter.report(UserFacingError(
                title: "System audio stopped",
                message: "Stopped transcribing the other side's audio; your microphone is still active.",
                severity: .degraded))
        }
```

- [ ] **Step 2: Carry the reason from capture's `onUnavailable`**

Replace the capture `onUnavailable` wiring (currently line 189):

```swift
        capture.onUnavailable = { [errorReporter] reason in
            errorReporter.report(UserFacingError(
                title: "Audio capture stopped", message: reason, severity: .fatal))
        }
```

- [ ] **Step 3: Check `capture.start()` and stop returning `true` blindly**

Replace the start tail (currently lines 197-201):

```swift
        transcriber.connect()
        themTranscriber.connect()
        if let reason = capture.start() {
            stop()                      // tear down the sockets we just opened
            errorReporter.report(UserFacingError(
                title: "Couldn't start audio capture", message: reason, severity: .fatal))
            return false
        }
        jlog("Jarvis: coaching started (one-clock capture + AEC).")
        return true
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!` with no errors or warnings.

- [ ] **Step 5: Run the full test suite**

Run: `./scripts/run-tests.sh`
Expected: all three targets build; all tests pass (including Task 1's `UserFacingErrorTests`).

- [ ] **Step 6: Commit**

```bash
git add Sources/JarvisApp/App/AppDelegate.swift
git commit -m "Fail loud on every startup failure via ErrorReporter; honor capture result"
```

---

### Task 5: Update the wiki (design source of truth)

Fold the decision into the wiki per CLAUDE.md (wiki holds final state; no alternatives/tradeoffs there — those live in the design HTML).

**Files:**
- Modify: `wiki/architecture.md` (the `AggregateEchoCapture` / `WebRTCEchoCanceller` rows)
- Modify: `wiki/status.md` (the echo-cancellation decision entry)

- [ ] **Step 1: Update `wiki/architecture.md`**

In the `AggregateEchoCapture` row (line ~110), change the "sample-synced at 48 kHz" claim to reflect adaptation. Replace "A single IOProc delivers both, sample-synced at 48 kHz — the one-clock case AEC3 needs." with:

```
A single IOProc delivers both, sample-synced at the device's native rate (the one-clock case AEC3 needs); the capture reads that rate and resamples mic+tap up to 48 kHz for AEC3 (no-op when the device is already 48 kHz). Any input device works — built-in, USB, 44.1 kHz gear, or AirPods (Bluetooth HFP, 16/24 kHz).
```

Add (or extend an adjacent row) a one-line entry for the error funnel:

```
| **ErrorReporter** | The single funnel for user-facing failures: severity (`fatal`/`degraded`/`info`) decides whether to pop an `NSAlert` and tear the session down. The only place `NSAlert` is created; diagnostics stay in `JarvisLog`. Model is `UserFacingError` in Core. | AppKit (`NSAlert`). |
```

- [ ] **Step 2: Update `wiki/status.md`**

In the echo-cancellation decision entry (line ~71), strike the "sample-synced at 48 kHz" absolute and note the adaptation + fail-loud. Append to that entry:

```
Capture now reads the device's native rate and resamples to AEC3's 48 kHz rather than pinning the aggregate, so any input device works (AirPods/USB/44.1 kHz) — the old hard 48 kHz pin silently failed to start on Bluetooth mics. Every startup failure now surfaces through `ErrorReporter` (an `NSAlert`), never silently. (2026-06-23)
```

- [ ] **Step 3: Commit**

```bash
git add wiki/architecture.md wiki/status.md
git commit -m "Update wiki: device-rate adaptation and fail-loud capture"
```

---

### Task 6: Live verification (manual smoke — run by the maintainer)

`JarvisApp` is intentionally not unit-tested; verify the real behavior live.

**Files:** none

- [ ] **Step 1: Build and launch in dev mode**

Run: `./scripts/build-app.sh --dev`
Expected: builds, signs, launches.

- [ ] **Step 2: Built-in mic (regression check)**

Set System Settings → Sound → Input to the built-in mic. Click Start. In the log viewer expect:
`capture started (mic+tap @48000 Hz → AEC3 @48 kHz, AEC3 on).` and live transcription. Confirms the 48 kHz path is unchanged.

- [ ] **Step 3: AirPods (the fix)**

Connect AirPods, set them as Input. Click Start. Expect a `capture started (mic+tap @16000 Hz → AEC3 @48 kHz …)` (or 24000) line, NO `could not pin` line, and live transcription. Swap input built-in↔AirPods mid-session and confirm a clean `rebuilt capture after audio route change`.

- [ ] **Step 4: No echo regression**

On a non-48k input WITH speakers (not earbuds) as output, play far-end speech and confirm it does NOT re-transcribe as "me" (AEC still cancelling). This is the one thing the resample-alignment must not break.

- [ ] **Step 5: Fail-loud paths**

- Remove the API key → Start → expect the "No OpenAI API key set" alert.
- Deny microphone permission (System Settings → Privacy) → Start → expect a "Couldn't start audio capture" alert and the menu returning to stopped (not a silent no-op).

- [ ] **Step 6: Finish the branch**

Use `superpowers:finishing-a-development-branch` to open the PR (squash-merge, subject ending `(#N)`).

---

## Self-Review

**Spec coverage:**
- Adapt to any device (no hardcoded rate) → Task 3 (read rate, resample, nil-on-48k). ✓
- AEC stays fixed at 48 kHz / one-clock untouched → Task 3 (resample *into* AEC; aggregate/clock code unchanged). ✓
- No regression vs the pin's two concerns → Task 3 feeds true 48 kHz to AEC and to the 48→24 downsampler; fail-loud if rate unreadable. ✓
- Fail loud on every startup failure → Tasks 2 + 4 (no-key, capture build, mic-terminal, route-rebuild all `.fatal`; them-socket `.degraded`). ✓
- Centralized error module, OOD → Tasks 1 + 2 (`UserFacingError` model in Core; `ErrorReporter` funnel in App; severity-driven). ✓
- Diagnostics stay in JarvisLog → Task 2 (`report` calls `jlog`; `jlog` keeps owning logs). ✓
- Wiki is the design source of truth → Task 5. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**Type consistency:** `UserFacingError(title:message:severity:)`, `Severity.{fatal,degraded,info}`, `showsAlert`/`stopsSession`, `ErrorReporter.report(_:)`/`onFatal`, `AggregateEchoCapture.start() -> String?`, `onUnavailable: (@Sendable (String) -> Void)?`, `buildAudioLocked() -> String?`, `nominalSampleRate(_:)`, `aecRate`, `micUp`/`sysUp` — used consistently across tasks. ✓
