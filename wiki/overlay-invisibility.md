# Overlay Invisibility — Hiding the Coaching Overlay from Screen Capture

> How Jarvis keeps its on-screen coaching overlay out of screen recordings and screen shares (so an
> interviewer's Zoom/Meet/Teams never sees it) **and** out of Jarvis's own screen captures (so the
> brain never reads back its own output). The mechanism, how the alternatives do it, the empirical
> verification, and the limits.

## The Requirement

Jarvis draws short coaching tips in a floating overlay ([`OverlayPanel`](../Sources/JarvisOverlay/OverlayPanel.swift)).
That overlay must be invisible to two distinct audiences:

1. **Other apps capturing the screen** — the interviewer's Zoom/Meet/Teams share, a QuickTime/OBS
   recording, the macOS screenshot tool.
2. **Jarvis's own `capture_screen`** — otherwise the brain would read its own coaching text back in
   the next screenshot (a feedback loop). See [`ScreenCapture.swift`](../Sources/JarvisCore/ScreenCapture.swift).

Both are solved by the *same* single flag.

## The Mechanism — there is exactly one

macOS exposes one window-level content-protection flag:

```swift
panel.sharingType = .none   // NSWindow.SharingType.none / NSWindowSharingNone
```

It marks the window's contents as unreadable by other processes' capture paths. **There is no other
public API for this.** Apple DTS, verbatim: *"At this time there are no public APIs for preventing
screen capture."* Every comparable tool funnels down to this same flag:

| Tool | Framework | Capture-hiding call | Resolves to |
|---|---|---|---|
| **Jarvis** | native Swift | `panel.sharingType = .none` | — |
| Interview Coder (AGPL), Glass, cheating-daddy | Electron | `win.setContentProtection(true)` | `NSWindow.sharingType = .none` |
| Pluely | Tauri | `"contentProtected": true` | `.none` |
| Natively | Electron + Rust FFI | `setContentProtection(true)` **and** `msg_send![window, setSharingType: 0]` | `.none` |
| Cluely / LockedIn / Final Round | closed | content-protection flag (marketing aside) | `.none` |

Electron's `setContentProtection(true)` is literally `[window setSharingType:NSWindowSharingNone]`
in `native_window_mac.mm`; Tauri's `contentProtected` is the same on macOS. The "low-level GPU/Metal
hooks" some products market are dressing on this one flag. **Jarvis is at full parity, using the
native API directly.**

> Deprecation note: the `sharingType` property and the `.none` / `.readOnly` cases are **not**
> deprecated. Only the unrelated `.readWrite` case was deprecated in macOS 15.0. Anyone who says
> "`sharingType` is deprecated" has conflated it with that one case.

## Empirical Verification (macOS 26.5 Tahoe, 2026-06-16)

The online consensus — and Natively's own source comment — warned that **ScreenCaptureKit ignores
`.none` on macOS 15+** (it captures the whole composited framebuffer). We tested it directly on this
machine with a red `sharingType = .none` panel plus a blue control panel (no flag), captured four
ways:

| Capture path | API | Red `.none` panel | Blue control |
|---|---|---|---|
| Jarvis's own brain | `screencapture` CLI | **hidden** | visible |
| Interviewer (one-shot) | `SCScreenshotManager.captureImage` | **hidden** | visible |
| **Interviewer (live share)** | **`SCStream`** (what Zoom/Meet/Teams use) | **hidden** | visible |
| After `setKey()` activation-policy flip | `SCScreenshotManager` | **still hidden** | visible |

**Result:** on macOS 26.5, `.none` hides the overlay from *every* path tested — including the live
`SCStream` path real screen-shares use — and it survives an `NSApp` activation-policy flip. The
macOS-15 regression does **not** reproduce on Tahoe; Apple appears to have changed behavior again, or
it was specific to certain 15.x builds. Behavior here has been version-volatile, so this is
"verified-now," not "guaranteed-forever" — **re-test on major macOS updates** (the throwaway harness
used was a handful of standalone Swift programs driving `NSPanel` + ScreenCaptureKit).

## What Jarvis Does

- [`OverlayPanel`](../Sources/JarvisOverlay/OverlayPanel.swift) sets `panel.sharingType = .none` at
  construction.
- It **re-asserts** `.none` at the top of `show()` every time a coaching response is displayed.
  This is defense-in-depth, taken from Natively's documented lesson: flipping `NSApp` activation
  policy — which Jarvis does in the API-key dialog ([`MenuBarController.setKey()`](../Sources/JarvisApp/MenuBarController.swift))
  — can, on some OS versions/configs, make WindowServer drop the flag. It does **not** reproduce on
  macOS 26.5, but the failure would be silent and high-impact (the overlay would become visible to an
  interviewer with no signal), so re-asserting on every show is cheap insurance.

That is the entire implementation: no package, no entitlement, no private API. `OverlayPanel` lives in
its own small `JarvisOverlay` library target (not the executable) so the tests below can import it.

## Regression tests

`Tests/JarvisOverlayTests/OverlayInvisibilityTests.swift` guards this in two layers:

1. **Property tests (always run, incl. CI):** assert the panel sets `sharingType = .none` at
   construction and that `render()` re-asserts it (a counter proves the re-assert code runs — needed
   because macOS 26 normalizes `sharingType`, so a dropped flag can't be simulated by writing another
   value). These catch the realistic regression: the flag or the re-assert being deleted.
2. **On-screen capture test (opt-in, local):** paints a `.none` panel + a control, captures the
   display with ScreenCaptureKit (the Zoom/Meet/Teams path), and asserts the protected panel is
   absent while the control is present. CI can't grant Screen Recording, so it skips unless opted in:

   ```sh
   JARVIS_RUN_CAPTURE_TESTS=1 ./scripts/run-tests.sh --filter OverlayInvisibilityTests
   ```

   Run it from a terminal that has Screen Recording permission. This is the automated form of the
   manual verification recorded above — run it after major macOS updates to catch OS-level drift.

> Toolchain note: the tests use swift-testing but the async ones are nonisolated `@Test`s that `await`
> a `@MainActor` helper. A direct `@MainActor async @Test` miscompiles on the Command-Line-Tools
> swift-testing ("must be a compile-time constant to use @section"), and XCTest isn't available CLT-only.

## Limits — what `.none` does NOT protect against

`sharingType = .none` is a best-effort window-server hint, not a security boundary. It does nothing
against:

- **A phone/camera pointed at the screen**, or **HDMI capture cards / external recorders** — they
  capture downstream of compositing.
- **OS-version drift** — it worked on ≤14, was reported to leak on 15.4, and works on 26.5. Re-test
  on macOS upgrades.
- **Process-level detection** — proctoring agents (Proctorio, Talview) detect the *running
  app/process*, not pixels. This is a separate, stronger vector; the flag offers zero defense. Other
  tools respond with process-name disguise — out of scope for Jarvis (a personal tool, not an
  anti-proctoring product).
- Note: macOS shows a screen-capture indicator to *whoever is capturing*. It does not expose Jarvis's
  overlay to the interviewer, but a user recording their **own** screen is flagged to themselves.

## References

- Apple DTS, "no public APIs for preventing screen capture": developer.apple.com/forums/thread/792152
- Electron `native_window_mac.mm` — `setContentProtection` → `NSWindowSharingNone`
- Natively `native-module/src/stealth_window.rs` — direct FFI, the SCK-limitation comment, and the
  activation-policy re-assert loop that motivated Jarvis's `show()` re-assert
- `SCContentFilter(display:excludingApplications:exceptingWindows:)` — the robust way to exclude
  windows from *your own* `SCStream`, **if** Jarvis ever moves its brain capture off the
  `screencapture` CLI onto ScreenCaptureKit
- [landscape-survey.md](./landscape-survey.md) — the tools surveyed and why we built our own
