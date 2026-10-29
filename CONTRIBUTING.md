# Contributing to Jarvis

Jarvis is an experimental macOS assistant with unusually sensitive audio, screen, credential, and
local-process boundaries. Small, testable changes are preferred.

## Developer setup

The coding agent performs this setup and runs the tests. Human contributors are not expected to run
tests manually.

Use an Apple silicon Mac with macOS 14.2+, Swift 6, Python 3, and the
[Command Line Tools](./wiki/build-and-run.md#toolchain). Keep a responsive logged-in macOS GUI session
and run tests as your ordinary development account. A physical monitor and full Xcode are optional.
On a headless Mac, `Jarvis Tests` serves as the main display. The offline Gate needs no API
keys or capture permissions; SwiftPM downloads dependencies on the first build.

Verify the tools, then run the Gate from the checkout:

```bash
xcode-select -p
swift --version
python3 --version
swift build && ./scripts/run-tests.sh
```

The runner initializes and reuses the fixed `Jarvis Tests` display automatically. Developers need no
display app, approval file, or A/B acceptance campaign. All worktrees on a Mac share its ownership
state, so use the same development account and current runner. The display stays available between
runs. On the first display check after a Mac boot, the runner can create it if absent and keep a small
idle owner process alive; no login service is installed. Later disappearance stops the Gate for
inspection, preventing repeated creation if detection is wrong. Test cleanup never destroys the
display. Quit any separately launched
`Jarvis Dev` app before testing. The framework's acceptance evidence belongs to framework development.

If admission reports unfinished cleanup, a changed identity, or unsafe ownership, stop and resolve
that specific failure using [test command recovery](./wiki/test-command-ownership.md#acceptance-and-recovery).
Do not delete the journal or lock, destroy the test display, use the hosted-CI wrapper locally, or invoke
raw `swift test` to get around a refusal. Include the error when reporting a setup blocker.

## Before opening a pull request

The coding agent completes this checklist:

1. Complete [developer setup](#developer-setup) and read [`AGENTS.md`](./AGENTS.md).
2. Create an isolated worktree on a feature branch; never commit directly to `main`.
3. Put Foundation-only logic in `JarvisCore` and keep OS-bound code thin in `JarvisApp` or
   `JarvisOverlay`. Read [`CLAUDE.md`](./CLAUDE.md) and the relevant page under [`wiki/`](./wiki/).
4. Add or update swift-testing coverage for behavior changes.
5. Run the complete, unfiltered Gate locally on the revision you will submit and read its output:

   ```bash
   swift build && ./scripts/run-tests.sh
   ```

6. Only after it passes, open a ready-for-review PR. Include the tested commit and passing output,
   including the test count. Rerun after changes. A blocked, failed, partial, or CI-only run does not
   satisfy this requirement, including for documentation changes. Resolve setup failures before
   opening the PR; do not mark an unrun Gate as passing.

Use Conventional Commits in lowercase imperative form, such as `fix(audio): preserve reconnect
order`. Pull requests should explain the user-visible behavior, security or privacy impact, and
validation performed.

## How a pull request merges

`main` takes squash merges only, and requires a pull request, one approving review, and a passing
`test` check. Hosted CI runs the test suites without the local virtual display and adds helper privacy
validation; it supplements the required local Gate. Pushing new commits dismisses an existing
approval, so expect to ask for another look after addressing review feedback.

You do not need write access to contribute: a pull request from your own fork gets the same CI run.
CodeRabbit comments on every pull request, forks included — it reviews, it never approves, and a
maintainer still reads the change.

The first workflow run on a fork pull request waits for a maintainer to approve it, so CI can sit
idle for a while before it starts. That is a repository setting, not something wrong with your
branch, and it stops applying once your first run has been approved.

## Security and privacy

- Never commit credentials, `.jarvis/` sessions, transcripts, screenshots, raw audio, or local CLI
  authentication state.
- Do not start live capture, transmit a real conversation, or intentionally interrupt a network
  connection without the operator's explicit consent. Use only audio and screen content you are
  authorized to process.
- Preserve ghost mode, owner-only persistence, provider selection, and the coaching-attempt boundary
  described in [`CLAUDE.md`](./CLAUDE.md).
- Report vulnerabilities privately according to [`SECURITY.md`](./SECURITY.md).

By submitting a contribution, you agree that it may be distributed under the repository's
[Apache License 2.0](./LICENSE).
