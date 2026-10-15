# Overlay Invisibility — Capture Protection and Its Limits

Jarvis requests capture exclusion for its Overlay Box and explicitly opened Settings surfaces. This
is a best-effort macOS window hint. It is not a guarantee that a recorder, meeting app, or proctoring
agent cannot see Jarvis. Capture behavior must be measured on the actual OS and capture path.

## Mechanism and ownership

[`NSWindow.excludeFromScreenCapture()`](../Sources/JarvisOverlay/NSWindow+CaptureExclusion.swift)
sets `sharingType = .none` and weakly registers the window for reassertion. The registry does not
retain closed windows. It covers:

- The [`OverlayBoxPanel`](../Sources/JarvisOverlay/OverlayBoxPanel.swift), including its history,
  streamed replies, details, and appearance preview. The box reasserts exclusion when it becomes
  visible and when visible content renders.
- [`SettingsWindow`](../Sources/JarvisApp/Settings/SettingsWindow.swift), which contains Activity,
  credentials, provider state, and configuration. Opening and closing Settings reasserts the
  registered windows after its activation-policy change, including an idle overlay with no new text.
- Activity's export-session picker, alerts, and file panels, and the Tools source picker. The code
  requests exclusion on the `NSOpenPanel` as well; remote system-owned file-picker content still
  requires separate capture validation.
- The expected-language popover. Its
  [`CaptureExcludedView`](../Sources/JarvisOverlay/CaptureExcludedView.swift) registers the hosting
  window when AppKit attaches the content view.

Settings and Activity use inline text and accessibility help instead of native hover tooltips.
AppKit creates tooltip windows separately from their parent; excluding the parent does not protect
those windows. The static presentation guard rejects native tooltip assignments and registration
calls in those areas.
The overlay follows the same rule with help drawn inside its own panel.

Native menus, system-owned dialogs, macOS privacy UI, and pages opened in a browser have independent
presentation paths. A protected Settings window does not establish protection for those surfaces.
The runtime still permits Settings and its dialogs only after an explicit user action; capture
exclusion does not authorize autonomous UI. See [AGENTS.md](../AGENTS.md#runtime-safety-boundaries).

## Why there is no protection timer

An activation-policy change can invalidate window sharing state on some configurations. Jarvis
reasserts exclusion at the relevant events: construction, showing, rendering, appearance preview,
and Settings' policy transitions. A periodic assignment could repair state that the OS dropped
between those events, but would still leave an interval before repair. Add such a timer only after
reproducing that failure and measuring whether it helps. Repeatedly setting `.none` cannot make a
capture API honor a flag that it ignores.

Apple documents `.none` as a legacy constant and says there is no public API that prevents screen
capture. Electron also warns that ScreenCaptureKit-based applications can capture protected windows.
Other products using the same AppKit mechanism do not establish parity across their auxiliary
windows, OS versions, or capture implementations. Closed-source behavior cannot be inferred from
marketing or a framework choice.

## Validation layers

The checks establish different facts; a passing flag test is not a passing capture test.

1. **Offline Gate.** `OverlayBoxPanelTests` verifies construction and the box's show/render/preview
   reassertion paths. macOS may normalize the public sharing property, so the invocation counters
   prove those paths run, not that another process cannot capture the window.
2. **Synthetic screenshot check.** `OverlayInvisibilityTests` creates protected and ordinary colored
   panels on the [automatic test display](./build-and-run.md#automatic-test-display) and takes one
   `SCScreenshotManager` image of that display. It does not exercise the signed app, streaming,
   Settings, or a meeting application. Run from a terminal with Screen Recording permission:

   ```sh
   JARVIS_RUN_CAPTURE_TESTS=1 ./scripts/run-tests.sh --filter OverlayInvisibilityTests
   ```

3. **Signed-app continuous stream check.**
   [`run-capture-privacy-tests.sh`](../scripts/run-capture-privacy-tests.sh) builds and launches the
   signed debug app using `open`. The debug-only
   [`CapturePrivacyAppDelegate`](../Sources/JarvisApp/LiveE2E/CapturePrivacyAppDelegate.swift) drives
   the real Overlay Box and Settings/Activity while
   [`CapturePrivacyStream`](../Sources/JarvisApp/LiveE2E/CapturePrivacyStream.swift) records a display
   through `SCStream`, without excluding any app or window in the recorder's filter.

   ```sh
   ./scripts/run-capture-privacy-tests.sh
   ```

   The app needs its own Screen Recording grant. Missing permission fails the check without opening
   privacy UI. A three-color stripe marker is attached inside the real windows. It changes only
   synthetic test content, leaving their capture policy intact. An ordinary panel with the same
   marker must be captured as a positive control before and after the protected phases; the baseline
   must contain no marker. The remaining phases require no detected marker: session start, streaming and detail, resize, Settings opening
   while the overlay is idle, Activity navigation, Settings closing, session stop, and restart.

   Results retain the OS build, bundle identity, source revision/dirty state, signature information,
   per-phase frame counts, and marker detections under the checkout's owner-only
   `.jarvis/capture-privacy/` directory. Captured frames stay in memory and are never written. The
   recorder requests sRGB output and samples a pixel grid at a requested ten frames per second with
   color tolerance. Any detected marker fails a protected phase; a missing positive control invalidates the run. This
   checks window-level exclusion, not every child rendering surface, arbitrary pixel, or a flash
   between sampled frames. A passing result does not certify native menus or system-owned pickers.

4. **Actual receiving-app checks.** Zoom, Google Meet, Microsoft Teams, OBS/QuickTime, macOS
   screenshots, and Jarvis's own `screencapture` CLI path need their own evidence. An `SCStream`
   result is not a substitute for a meeting application's actual capture implementation.

Hosted CI runs the property/static checks. It does not silently grant TCC or claim pixel validation.
Run capture checks locally on supported OS versions, after OS upgrades, and for release candidates.

## Receiving-app evidence

For each supported OS and meeting-app release, record these conditions in the release or PR evidence:

| Condition | Required evidence |
|---|---|
| Platform | Exact macOS version/build, machine/display setup, Jarvis build/signature |
| Recorder | App/browser version, screen-share mode (display, window, or tab), recording settings |
| Viewpoint | What the remote participant or final recording receives, not just the sender's preview |
| Scenarios | Streaming text, detail expansion, resize, idle overlay across Settings open/close, stop/start |
| Auxiliary UI | Activity, hover, menus, language popover, export/source picker, and alerts |
| Outcome | Pass/fail or unverified for each scenario; never infer untested combinations |

The signed test can hold each phase for up to thirty seconds (`./scripts/run-capture-privacy-tests.sh
30`) to help inspect a real receiving view. System-owned pickers and other auxiliary actions still
need explicit manual exercise. The generated report labels meeting applications unverified; a manual
check belongs alongside that report and does not rewrite its automated result.

## Detection boundaries

Window capture exclusion does not hide the process, executable, installation path, bundle identity,
code signature, network connections, permission indicators, or files. It cannot protect against an
external camera or capture hardware. Jarvis's current product scope excludes process-name disguise;
that is a separate decision from protecting window contents. A neutral process name would change
casual listings but would not establish invisibility to software inspecting executable identity.

Jarvis's own screenshot path also needs protection against reading its overlay back as new context.
Its current `screencapture` adapter relies on the same best-effort behavior. If that path changes to
ScreenCaptureKit, recorder-owned content filters provide explicit exclusions for that recorder;
they cannot control someone else's recorder.

## References

- [Apple: NSWindow.SharingType.none](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none)
- [Apple DTS: preventing screen capture](https://developer.apple.com/forums/thread/792152)
- [Electron: setContentProtection limitations](https://www.electronjs.org/docs/latest/api/browser-window#winsetcontentprotectionenable)
- [Apple: capturing screen content with ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [Sandbox and data egress](./sandbox.md)
