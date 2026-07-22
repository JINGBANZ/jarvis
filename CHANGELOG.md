# Changelog

## [0.1.1](https://github.com/JINGBANZ/jarvis/compare/v0.1.0...v0.1.1) (2026-07-18)


### Features

* **coach:** cut per-session brain cost ~7x — stay_silent, substance gate, client-managed history ([#46](https://github.com/JINGBANZ/jarvis/issues/46)) ([fe2e634](https://github.com/JINGBANZ/jarvis/commit/fe2e63411cf325cb8a7e25d4006002b07f1199ad))
* **coach:** local Claude Code / Codex CLI brain providers on the user's subscription ([#73](https://github.com/JINGBANZ/jarvis/issues/73)) ([39594d1](https://github.com/JINGBANZ/jarvis/commit/39594d1a06d499ec31a2d321938dbf49dd0f5a7e))
* **coach:** reasoning-item passthrough; prompt dedupe ([#69](https://github.com/JINGBANZ/jarvis/issues/69)) ([48fba38](https://github.com/JINGBANZ/jarvis/commit/48fba387774d7107d6201c5c4ea5a9acf5e56d4b))
* **eval:** agentic session auditor that reads the repo ([#71](https://github.com/JINGBANZ/jarvis/issues/71)) ([#72](https://github.com/JINGBANZ/jarvis/issues/72)) ([8254ffe](https://github.com/JINGBANZ/jarvis/commit/8254ffeb5ec70193147b09f427ec0c7f97289e5e))
* **eval:** per-session brain-traffic capture + one-click LLM session audit ([#64](https://github.com/JINGBANZ/jarvis/issues/64)) ([971ca11](https://github.com/JINGBANZ/jarvis/commit/971ca11c3951a5b25cf5beb1714df3dbfc03f759))
* **eval:** reopen saved report instead of re-evaluating an audited session ([#66](https://github.com/JINGBANZ/jarvis/issues/66)) ([cc16990](https://github.com/JINGBANZ/jarvis/commit/cc1699026ec7796d1762d49f2761b31bb22c90fb))
* **menubar:** minimal icon-prefixed menu via one standard item format ([#68](https://github.com/JINGBANZ/jarvis/issues/68)) ([1dd8b58](https://github.com/JINGBANZ/jarvis/commit/1dd8b586919092f487ee03c801da7afce9b2c255))
* **release:** automated signed+notarized releases via release-please ([#75](https://github.com/JINGBANZ/jarvis/issues/75)) ([7825fb5](https://github.com/JINGBANZ/jarvis/commit/7825fb5a963c9d54531b7a67bac84e275fd7cb2a))
* **screen:** user-selectable capture display with start-time prompt ([#51](https://github.com/JINGBANZ/jarvis/issues/51)) ([9f83d88](https://github.com/JINGBANZ/jarvis/commit/9f83d882fa06e0f1a72bc00b081d4f0de3f386da))
* **screen:** window-scoped capture with on-device OCR sidecar ([#54](https://github.com/JINGBANZ/jarvis/issues/54)) ([73ab04c](https://github.com/JINGBANZ/jarvis/commit/73ab04c1880fd565d1ac8bc499f953eedd79b733))
* **settings:** fold display choice into capture scope; uniform window size ([#70](https://github.com/JINGBANZ/jarvis/issues/70)) ([fa34b79](https://github.com/JINGBANZ/jarvis/commit/fa34b7910e3d495954de8a70fe6c1852b74e5d0d))


### Bug Fixes

* **coach:** context hygiene — fresh transcript per start, slim trigger notes, idle silence cutoff ([#65](https://github.com/JINGBANZ/jarvis/issues/65)) ([5ef8b8e](https://github.com/JINGBANZ/jarvis/commit/5ef8b8e66cd669929f088b8553174ac695b8bbbb))
* **coach:** raise brain request ceiling and drop in-request retry ([#45](https://github.com/JINGBANZ/jarvis/issues/45)) ([aea1765](https://github.com/JINGBANZ/jarvis/commit/aea176520ffff132631fcb14b17b0d8b30d776f9))
* harden realtime connection recovery ([#63](https://github.com/JINGBANZ/jarvis/issues/63)) ([d909dd6](https://github.com/JINGBANZ/jarvis/commit/d909dd6e5b191b935e912fa4a1cbd5e43cc05da7))
* **realtime:** preserve interview audio context ([#74](https://github.com/JINGBANZ/jarvis/issues/74)) ([bf20523](https://github.com/JINGBANZ/jarvis/commit/bf205236bf4353b616fb2b0c2825f60ab6903efa))


### Performance Improvements

* **coach:** stub screenshots at commit, log cache hits, fix speak tool wording ([#67](https://github.com/JINGBANZ/jarvis/issues/67)) ([f6b88f0](https://github.com/JINGBANZ/jarvis/commit/f6b88f0fd3ca7cb2a25519f92fcc0cf47699254b))
