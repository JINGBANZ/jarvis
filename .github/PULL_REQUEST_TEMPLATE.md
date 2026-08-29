<!--
Read CONTRIBUTING.md before opening. Jarvis has unusually sensitive audio, screen, credential,
and local-process boundaries, so the security/privacy section below is not boilerplate.
Delete any section that genuinely does not apply, rather than leaving it blank.
-->

## Summary

<!-- What changes, and the user-visible behavior afterwards. Link the issue this implements. -->

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

```
<!-- Paste the gate result, including the test count. -->
```

### Live smoke

<!--
CI cannot grant TCC permissions or drive real capture devices, so `JarvisApp` changes are verified
only by hand in the signed app (`./scripts/build-app.sh --run`). Describe what you ran and what you
observed, or state "not required — no App-layer change".
-->

## Out of scope

<!-- Anything a reviewer might expect here but that belongs to a follow-up. Omit if nothing. -->
