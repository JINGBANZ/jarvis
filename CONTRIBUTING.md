# Contributing to Jarvis

Jarvis is an experimental macOS assistant with unusually sensitive audio, screen, credential, and
local-process boundaries. Small, testable changes are preferred.

## Before opening a pull request

1. Use an Apple silicon Mac with macOS 14.2+, Swift 6, and the Command Line Tools.
2. Create a branch or isolated worktree; never commit directly to `main`.
3. Put Foundation-only logic in `JarvisCore` and keep OS-bound code thin in `JarvisApp` or
   `JarvisOverlay`. Read [`CLAUDE.md`](./CLAUDE.md) and the relevant page under [`wiki/`](./wiki/).
4. Add or update swift-testing coverage for behavior changes.
5. Run the complete gate and read its output:

   ```bash
   swift build && ./scripts/run-tests.sh
   ```

Use Conventional Commits in lowercase imperative form, such as `fix(audio): preserve reconnect
order`. Pull requests should explain the user-visible behavior, security or privacy impact, and
validation performed.

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
