<!--
Read CONTRIBUTING.md before opening. Jarvis has unusually sensitive audio, screen, credential,
and local-process boundaries, so the security/privacy section below is not boilerplate.
Delete any section that genuinely does not apply, rather than leaving it blank.
-->

## Summary

<!--
Plain language, kept short. What changes, and what someone using Jarvis notices afterwards — a
reader should understand it without opening the diff. A few clear sentences beat a wall of detail;
save the depth for the sections below. Link the issue this implements.
-->

## Security and privacy impact

<!--
State the impact even when it is "none". Call out anything touching: ghost mode (no activation,
no UI beyond the two capture-excluded panels, no sound), owner-only persistence under `.jarvis/`,
raw microphone audio or live transcript retention, the API key or secrets file, or the
coaching-attempt and provider-route boundaries.
-->

## Validation

- [ ] `swift build && ./scripts/run-tests.sh` passes — output pasted below
- [ ] Behavior changes are covered by swift-testing cases
- [ ] Commits follow Conventional Commits (`type(scope): summary`, lowercase imperative)

<!-- Paste the gate result below, including the test count. -->

```text

```

### Live smoke — optional, and only for `JarvisApp` changes

<!--
Skip this section entirely for Core, Overlay, docs, or CI changes.

CI can neither grant TCC permissions nor drive real capture devices, so App-layer behavior is only
ever confirmed by hand in the signed app (`./scripts/build-app.sh --run`). If you ran one, say what
you did and what you saw. If you cannot — no Apple silicon Mac, no signing identity, no microphone
or screen access to spare — say so and leave it; a maintainer runs it before merge. A missing live
smoke is never a reason not to open the pull request.
-->

## Out of scope

<!-- Anything a reviewer might expect here but that belongs to a follow-up. Omit if nothing. -->
