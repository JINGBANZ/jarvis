# Code snippet implementation plan

> Use subagent-driven-development to implement the bounded presentation task and review the integrated branch.

**Goal:** A Show code with hints setting and configurable fallback hotkey reveal the next logical coding snippet in a dedicated bottom area of the existing overlay.

**Approved spec:** User-approved conversation/mock, `jarvis-code-dock.html`: preserve visible names/structure/language, show a small coherent component rather than full solution, highlight nearby corrections with surrounding snippet, diagnose invalid overall approaches in hints, use the first component when code is not visible. The setting defaults off. When on, hints carry matching code and replace or clear the previous snippet. The hotkey enables the setting and requests current code. Code syntax must contrast with its background.

**Architecture:** Extend the existing manual trigger and strict speak schema with optional typed CodeSnippet. Harness accepts snippets only when enabled in SessionPlan in coding/general sessions. Keep system/tool schemas stable for local CLI clients. Add independent `showCodeSnippet` overlay delivery with default no-op for captions. The existing box owns a bottom snippet view and separate scrolling history, with no new windows or capture paths.

**Constraints:** Swift 6; macOS 14.2 floor; Foundation-only Core. One provider per attempt. User prefs read only at existing explicit boundaries. Ghost mode unchanged. No editor insertion, clipboard automation, new dependencies, or model-generated executable content. Code opt-in is the setting or its enabling hotkey; default Cmd-Option-K, independently configurable. Explain toggle does not govern code.

## Work

- [x] Core: typed bounded CodeSnippet (maximum 12 lines, no truncation), nullable strict JSON schema, parser fallback, manualCode identity/context/activity, runtime authorization, history and overlay dispatch. Tests prove disabled attempts cannot display code and enabled hints carry matching snippets, manual code uses recent context/screenshots, malformed/oversize snippet retains hint, no-code reply clears previous snippet, explanation-off independence, retry and coalescing.
- [x] Overlay: dock at bottom inside existing panel, monospace syntax colors with opaque dark code background, highlighted correction lines, placement label and dismiss action. History and code scroll separately; hints replace code with their matching snippet; off hides the area immediately. Respect clear/Stop/session/visibility and restore real code after Settings preview. Test layout and lifecycle with synthetic content.
- [x] App: register third configurable shortcut using existing collision-preserving recorder, persist binding independently; handle only coding/general sessions, disclose unavailable format or disabled overlay through existing hint presentation.
- [x] Verify: focused test cycles, signed synthetic AppKit/Carbon smoke, directional production-model checks, full Gate (`swift build && ./scripts/run-tests.sh`), independent review. Update wiki and open a stacked PR against `codex/explain-more`.

**Completion:** Gate passes, approved behavior is demonstrable in signed Dev preview, review has no unresolved contract violations, branch is committed and PR opened. No full live audio/screen-sharing verification claimed.

## Verification evidence

- Full Gate: build passed; 1,004 tests in 119 suites passed.
- Signed synthetic native smoke: dock rendering, correction contrast, incoming-hint persistence, preview restoration, clear; Carbon dispatch, independent rebind/collision handling, explanation toggle, and three-card small-window layouts passed.
- Revised production-model smoke could not complete: two attempts timed out. Runtime authorization is covered by deterministic tests.
- Independent review findings addressed: non-LF newline rejection; dock clipping and dismiss contrast also corrected and regression-tested.
- Real interview audio, screen sharing, and cross-app use remain manual smoke coverage.
