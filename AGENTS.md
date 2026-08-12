# AGENTS.md

<!-- shared-rules:begin — machine-managed block; do not edit — propose changes in JINGBANZ/rules. -->

## Working principles

- **Think before coding.** State assumptions explicitly. If a request has multiple reasonable
  interpretations, surface them and ask — don't silently pick one. Push back when something
  looks wrong instead of running with it.
- **Define the scope contract.** Before non-trivial work, agree on the expected user behavior,
  failure behavior, acceptable degradation or data loss, explicit non-goals, and completion
  criteria. Treat this contract as the PR scope.
- **Review against the contract.** A confirmed contract, security, or privacy violation is
  actionable. Feedback that expands the contract or adds lifecycle state, retries, timers, or
  cross-component coordination requires owner approval before editing. Do not optimize for zero
  comments; stop when the contract is satisfied and the Gate passes.
- **Simplicity first.** Choose the smallest implementation that fully meets the current
  requirements. Avoid speculative features, abstractions, configuration, and indirection; do not
  add error handling for cases that can't occur. Ask whether a senior engineer would find the
  solution overcomplicated.
- **Avoid legacy baggage.** Preserve backward compatibility only when current project requirements
  demand it—for example, for a public API contract, persisted data, or a rolling deployment. When
  project context confirms compatibility is no longer required, remove obsolete paths instead of
  adding compatibility layers, fallbacks, or migrations.
- **Build in working layers.** Start with the smallest version that works end to end, then add each
  capability on top of a product that already works. Never trade a working product for unfinished
  complexity.
- **Keep boundaries clear.** Keep components modular and concerns separated.
- **Build for the long term.** Make durable architectural decisions. Do not accept a stopgap that
  only works for now and is meant to be replaced later.
- **Surgical changes.** Every changed line should trace to the request — but it's fine to refactor
  or improve nearby code and remove pre-existing dead code where there's clear room for improvement.
- **Goal-driven execution.** Turn the request into verifiable success criteria, state a brief plan
  for complex tasks, then loop until the criteria are met.
- **Document non-obvious decisions in comments** — explain *why*, not *what*.

## Workflow

- **Explore → plan → implement.** For non-trivial changes, understand the relevant code and
  agree on an approach before editing. Skip planning only for small, well-scoped fixes.
- **Evidence, not assertion.** Before claiming work is done, run the **Gate** command and show the
  output. Don't say "it works" without the passing result to back it.
- **Adopt proven patterns.** Before designing a solution, study how established products solve the
  problem and adopt their proven patterns and conventions. Within the repo, find similar code and
  mirror its structure, naming, and idioms rather than imposing a new approach.
- **Reuse before building.** Check the documentation and types of dependencies already in the
  project before writing your own implementation or adding a package. Prefer established,
  well-maintained libraries when they reduce overall complexity or improve reliability; reimplement
  common functionality only with a clear reason.
- **Prefer running focused tests** over the whole suite while iterating, then run the full **Gate**
  before finishing.
- **Open a PR when the work is done.** Once the change is complete and the **Gate** passes, commit
  to a branch and open a pull request without waiting to be asked. Don't leave finished work
  uncommitted on a local branch.

## Commit messages

Follow [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary` in
lowercase imperative mood (`feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`).
Mark breaking changes with `!` (`feat!:`) or a `BREAKING CHANGE:` footer. One logical change per commit.

## Security & safety

- Never hardcode or log secrets, tokens, or credentials; read them from env/secret storage.
- Validate and sanitize all external input; treat user data as untrusted.

## Never

- **Never** skip pre-commit/pre-push hooks (e.g. `--no-verify`) or the **Gate**.
- **Never** commit secrets, `.env` files, or credentials — nor generated artifacts or large binaries.
- **Never** commit directly to the default branch; open a PR.
- **Never** `git push --force` to a shared branch.
- **Never** modify or delete a test to make a broken change pass — fix the code, not the test.
- **Never** suppress an error or warning to hide a problem — address the root cause.

<!-- shared-rules:end -->

## Project overview

Jarvis is a proactive macOS menu-bar coach built with Swift 6, SwiftPM, and macOS 14+ APIs. Keep
Foundation-only logic in `JarvisCore`; keep AppKit, audio, capture, and other OS-bound code thin in
`JarvisOverlay` or `JarvisApp`. The event loop starts at `Sources/JarvisCore/Coach/CoachDriver.swift`.

## Commands

| Task | Command |
|---|---|
| Compile | `swift build` |
| Test | `./scripts/run-tests.sh` (never raw `swift test`) |
| Build or run app | `./scripts/build-app.sh [release\|debug]` or `./scripts/build-app.sh --run` |
| **Gate** | `swift build && ./scripts/run-tests.sh` |

## Development rules

- Build the harness, not model or OS intelligence. Add a target only for an isolated test boundary, a
  compiler-enforced boundary, or code shared by another executable.
- Preserve one brain target for an entire coaching attempt: no in-attempt provider retry or switch.
  Temporary or unknown failures exhaust a target after three failed attempts; only a proven permanent
  provider-boundary failure may exhaust it immediately. Advance only in a fresh attempt, move forward
  through the persisted route, and never rewrite preferences or revisit an exhausted target.
- Keep route and scheduling policy as Foundation-only state machines; the app supplies clients,
  timers, and speech-activity events.
- Use Swift 6 strict concurrency. Do not use `@unchecked` or `nonisolated(unsafe)` without a written
  reason. Keep one primary type per file; name focused extensions `Type+Purpose.swift`.
- Use swift-testing for Core, Overlay, and Viewer behavior. Verify `JarvisApp` through the live smoke
  checklist because it depends on TCC permissions and real capture devices.
- Work in an isolated git worktree. PRs squash-merge with the PR number in the subject.
- Read `wiki/AGENTS.md` before wiki edits; the wiki is the design source of truth.

## Runtime safety boundaries

- During the live pipeline and teardown, no autonomous path may activate Jarvis, present UI beyond
  the two nonactivating capture-excluded overlay panels, open apps or URLs, request attention, notify,
  or play sound. Explicit user-opened Settings/Activity and unavoidable macOS privacy UI are the only
  other presentation paths. Every presentation API call needs an inline `ghost-mode-allowed` reason.
- `ActivityLog` contains finalized speech, manual hints, brain actions, and fixed session-end or
  degradation notices. Retry, transport, timing, lifecycle, and raw-error detail goes only through
  `jlog` to `jarvis-debug.log`; never mirror debug logs into Activity.
- Persist screen- or audio-derived data only in owner-only files inside the workspace-local `.jarvis/`
  session directory, never `/tmp`. Never archive raw microphone audio or the live transcript.
- Store the API key only in the owner-only `0600` secrets file; `OPENAI_API_KEY` is a headless fallback.

## Gotchas

- Command Line Tools are sufficient; no Xcode project exists. The committed AEC archive is arm64-only.
- Launch the signed app through `./scripts/build-app.sh --run` / `open`, never the bare executable.

## Further context

- Start with `wiki/index.md` and `wiki/status.md`; the full security posture is in `wiki/sandbox.md`.
