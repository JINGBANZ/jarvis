# Changelog

## [0.1.4](https://github.com/JINGBANZ/jarvis/compare/v0.1.3...v0.1.4) (2026-08-17)


### Features

* **release:** distribute jarvis as a dmg ([#164](https://github.com/JINGBANZ/jarvis/issues/164)) ([231662c](https://github.com/JINGBANZ/jarvis/commit/231662cae98707b147b3d6d8ebe7c2422a183a5b))

## [0.1.3](https://github.com/JINGBANZ/jarvis/compare/v0.1.2...v0.1.3) (2026-08-13)


### Bug Fixes

* **build:** separate development app identity ([#158](https://github.com/JINGBANZ/jarvis/issues/158)) ([1fd3850](https://github.com/JINGBANZ/jarvis/commit/1fd3850690a38a246883ae19509b32940e8b7298))
* **release:** align distributed app appearance ([#159](https://github.com/JINGBANZ/jarvis/issues/159)) ([28400ab](https://github.com/JINGBANZ/jarvis/commit/28400abb400c893d9a12665870b94d1a1636e185))

## [0.1.2](https://github.com/JINGBANZ/jarvis/compare/v0.1.1...v0.1.2) (2026-08-12)


### Features

* **app:** add Listening Lens app and menu-bar icon ([#81](https://github.com/JINGBANZ/jarvis/issues/81)) ([55faf12](https://github.com/JINGBANZ/jarvis/commit/55faf128c4801cf76a91b28f62197c62e7e08d36))
* **brain:** add ordered provider fallback route ([#108](https://github.com/JINGBANZ/jarvis/issues/108)) ([b3f633d](https://github.com/JINGBANZ/jarvis/commit/b3f633d4cc30857ae8531a7a07dc06382f205808))
* **brain:** switch providers during live sessions ([#98](https://github.com/JINGBANZ/jarvis/issues/98)) ([de3a32c](https://github.com/JINGBANZ/jarvis/commit/de3a32cad2f1c1b04c2666abe92b9141649c42d2))
* **capture:** gate coaching readiness on audio-frame arrival ([#131](https://github.com/JINGBANZ/jarvis/issues/131)) ([dddc763](https://github.com/JINGBANZ/jarvis/commit/dddc763d6922a45c42fb3df0c3d263943be2f6c1))
* centralize session readiness ([#143](https://github.com/JINGBANZ/jarvis/issues/143)) ([f605c55](https://github.com/JINGBANZ/jarvis/commit/f605c556586336a17f8c8f9a12988ec0cbd5b2b4))
* **eval:** attribute coaching calls to transcript triggers ([#144](https://github.com/JINGBANZ/jarvis/issues/144)) ([249c2e9](https://github.com/JINGBANZ/jarvis/commit/249c2e9cc946c3009b0af079cdb2017152f9c8df))
* **eval:** harden session audit against counting errors and envelope confusion ([#91](https://github.com/JINGBANZ/jarvis/issues/91)) ([d651617](https://github.com/JINGBANZ/jarvis/commit/d651617f614a68536b9e6561b5144bcb4525de4d))
* **settings:** expand provider model catalog ([#116](https://github.com/JINGBANZ/jarvis/issues/116)) ([cce65f9](https://github.com/JINGBANZ/jarvis/commit/cce65f9697f961b37f7d261eb4c4e1c6eb11c0f6))
* **settings:** unify settings visual system ([#119](https://github.com/JINGBANZ/jarvis/issues/119)) ([c6532d1](https://github.com/JINGBANZ/jarvis/commit/c6532d1d6ad66996ba42b247746b73d281b566be))
* **transcription:** add Apple Speech and GPT Live transcription ([#123](https://github.com/JINGBANZ/jarvis/issues/123)) ([5e0509f](https://github.com/JINGBANZ/jarvis/commit/5e0509ff6e1c9d71bc816377d38d788f784e37c4))
* **transcription:** add GPT Transcribe committed turns ([#132](https://github.com/JINGBANZ/jarvis/issues/132)) ([7894240](https://github.com/JINGBANZ/jarvis/commit/7894240c30e8a0a93942d099b3d9a07b85002819))
* **transcription:** add repeatable system audio benchmark ([#145](https://github.com/JINGBANZ/jarvis/issues/145)) ([25cafec](https://github.com/JINGBANZ/jarvis/commit/25cafec1b4e07c38c4ecbcc9543dfb8901a56569))


### Bug Fixes

* **activity:** clarify coaching retry warning ([#150](https://github.com/JINGBANZ/jarvis/issues/150)) ([0dc7bc9](https://github.com/JINGBANZ/jarvis/commit/0dc7bc924112d9284e6537305cb01b264a442926))
* **activity:** compact session header ([#84](https://github.com/JINGBANZ/jarvis/issues/84)) ([83a2de9](https://github.com/JINGBANZ/jarvis/commit/83a2de900b05ff9338b93ed9856fb5fe5f642f8e))
* **activity:** log every brain action ([#99](https://github.com/JINGBANZ/jarvis/issues/99)) ([6212270](https://github.com/JINGBANZ/jarvis/commit/62122706dd04fe0fbaf71995c7db00b64d93cb35))
* **activity:** log every session end ([#113](https://github.com/JINGBANZ/jarvis/issues/113)) ([92d8bb3](https://github.com/JINGBANZ/jarvis/commit/92d8bb39e2525e499768b9d93a06c57407ff009c))
* **activity:** separate human and debug logs ([#77](https://github.com/JINGBANZ/jarvis/issues/77)) ([86855d2](https://github.com/JINGBANZ/jarvis/commit/86855d2c84918b91c4894d24e22b50a141e707c6))
* **audio:** start capture without system playback ([#124](https://github.com/JINGBANZ/jarvis/issues/124)) ([5e26546](https://github.com/JINGBANZ/jarvis/commit/5e26546f078adfcee96d345e453b644eab08bf75))
* **brain:** prevent Codex provider stalls ([#85](https://github.com/JINGBANZ/jarvis/issues/85)) ([342da88](https://github.com/JINGBANZ/jarvis/commit/342da88cf868b89f35f61e40a91332a693a38f7c))
* **coach:** inspect screen for context-dependent questions ([#78](https://github.com/JINGBANZ/jarvis/issues/78)) ([10e21e1](https://github.com/JINGBANZ/jarvis/commit/10e21e1bec29639cabc35831a56de889183db590))
* **coach:** reduce noisy coaching context ([#142](https://github.com/JINGBANZ/jarvis/issues/142)) ([b386e01](https://github.com/JINGBANZ/jarvis/commit/b386e01f4b06009ea75fd30e094c9e0e079d6e3d))
* **coach:** reword OCR-only guidance — a double-check tip, not a question ([#92](https://github.com/JINGBANZ/jarvis/issues/92)) ([0727e69](https://github.com/JINGBANZ/jarvis/commit/0727e6985945d3fe67298bf477eabf32bcdc1363))
* **coach:** stale-context and cache-busting fixes from the session audit ([#89](https://github.com/JINGBANZ/jarvis/issues/89)) ([f8fa9a5](https://github.com/JINGBANZ/jarvis/commit/f8fa9a5be1d09e8f72a41271f4631de21ce507a9))
* **coach:** stay silent on garbled fragments ([#101](https://github.com/JINGBANZ/jarvis/issues/101)) ([250de65](https://github.com/JINGBANZ/jarvis/commit/250de659c9dbb2aaa004ae3e7421cca3eeb7e893))
* harden CLI auth, ghost mode, and session diagnostics ([#83](https://github.com/JINGBANZ/jarvis/issues/83)) ([0d7175e](https://github.com/JINGBANZ/jarvis/commit/0d7175e62169c891965173dc3cf68ba0be212757))
* isolate CLI launches and preserve conversations ([#106](https://github.com/JINGBANZ/jarvis/issues/106)) ([f946f06](https://github.com/JINGBANZ/jarvis/commit/f946f066cc2636f332ced0c7fcee95ceb54dcd2f))
* preserve conversation chronology across activity and coaching ([#152](https://github.com/JINGBANZ/jarvis/issues/152)) ([97395e7](https://github.com/JINGBANZ/jarvis/commit/97395e727a0776a7cb1335a3f92d36710b60295f))
* **screen:** own and verify transient capture files ([#117](https://github.com/JINGBANZ/jarvis/issues/117)) ([017d6d9](https://github.com/JINGBANZ/jarvis/commit/017d6d9668e99e41e62f5eaa3ecb88f8a7eb8e5a))
* **settings:** open window without blocking ([#103](https://github.com/JINGBANZ/jarvis/issues/103)) ([b89bbf0](https://github.com/JINGBANZ/jarvis/commit/b89bbf0da8e4de65f34b067bb8973635e76117cf))
* **transcription:** clarify realtime recovery diagnostics ([#137](https://github.com/JINGBANZ/jarvis/issues/137)) ([0f31259](https://github.com/JINGBANZ/jarvis/commit/0f312592e61800a7279dd979fa49a18831211cec))
* **transcription:** harden Jarvis-managed turns for GPT Live ([#129](https://github.com/JINGBANZ/jarvis/issues/129)) ([6594510](https://github.com/JINGBANZ/jarvis/commit/6594510ebdf3cd996786071290066ccd96b6138a))
* **transcription:** surface terminal failures in activity ([#100](https://github.com/JINGBANZ/jarvis/issues/100)) ([9dae7e9](https://github.com/JINGBANZ/jarvis/commit/9dae7e90c286fcc50c1629ff3791a983d4f9bacb))
* **triggers:** normalize filler set so "cool" / "I see" gate as filler ([#57](https://github.com/JINGBANZ/jarvis/issues/57)) ([1f7e9a9](https://github.com/JINGBANZ/jarvis/commit/1f7e9a986cf227d72e157413b06e571fe834b844))


### Performance Improvements

* **brain:** bound history compaction consistently across providers ([#122](https://github.com/JINGBANZ/jarvis/issues/122)) ([f4ae574](https://github.com/JINGBANZ/jarvis/commit/f4ae574905571eaae585c7119a94968d9efacf9d))
* **brain:** bound local coaching latency ([#120](https://github.com/JINGBANZ/jarvis/issues/120)) ([2dda64d](https://github.com/JINGBANZ/jarvis/commit/2dda64dcde84bfbb38fda62ecc9163d797f55135))
* **brain:** keep local agent runtimes warm ([#115](https://github.com/JINGBANZ/jarvis/issues/115)) ([828ee0c](https://github.com/JINGBANZ/jarvis/commit/828ee0cf5d5f13b449af437e544abbb4208f162d))
* **brain:** prewarm the first Codex thread ([#118](https://github.com/JINGBANZ/jarvis/issues/118)) ([609de84](https://github.com/JINGBANZ/jarvis/commit/609de84554d94bad5039e8204df9a08317ed97ec))
* **brain:** record phase-level latency for local CLI turns ([#112](https://github.com/JINGBANZ/jarvis/issues/112)) ([4665556](https://github.com/JINGBANZ/jarvis/commit/4665556ccd92cfd61c09dddd065ed9a8d027653d))

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
