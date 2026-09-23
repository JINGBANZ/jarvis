# Changelog

## [0.5.1](https://github.com/JINGBANZ/jarvis/compare/v0.5.0...v0.5.1) (2026-09-23)


### Features

* **coach:** keep one declared tool list per session ([#406](https://github.com/JINGBANZ/jarvis/issues/406)) ([6fbeaa3](https://github.com/JINGBANZ/jarvis/commit/6fbeaa3890d5fc36b0e5bb4c7841d173bea410fe))


### Bug Fixes

* **overlay:** stop test runs from exiting 0 partway through ([#401](https://github.com/JINGBANZ/jarvis/issues/401)) ([364ab53](https://github.com/JINGBANZ/jarvis/commit/364ab53d1676417262e6bb5f44d46cb60f983971)), closes [#399](https://github.com/JINGBANZ/jarvis/issues/399)

## [0.5.0](https://github.com/JINGBANZ/jarvis/compare/v0.4.0...v0.5.0) (2026-09-23)


### ⚠ BREAKING CHANGES

* **brain:** a saved primary model that is no longer listed falls back to the provider's default, and a saved fallback target naming one is dropped.

### Features

* **benchmark:** report the spoken-start offset per repetition ([#392](https://github.com/JINGBANZ/jarvis/issues/392)) ([434bccb](https://github.com/JINGBANZ/jarvis/commit/434bccb79f22c354beb8f11126c49a2349be3632))
* **brain:** list only the newest release of each OpenAI and Claude model line ([#400](https://github.com/JINGBANZ/jarvis/issues/400)) ([305a4a1](https://github.com/JINGBANZ/jarvis/commit/305a4a1ee324119a7c1740af8966943bcaeb7702))
* **transcription:** report Apple pending speech start times ([#389](https://github.com/JINGBANZ/jarvis/issues/389)) ([09329de](https://github.com/JINGBANZ/jarvis/commit/09329dec35afc629ba7b457f18a58a069406c9b0))
* **transcription:** report Gemini pending speech start times ([#390](https://github.com/JINGBANZ/jarvis/issues/390)) ([5e6adc9](https://github.com/JINGBANZ/jarvis/commit/5e6adc92d1bb86e00f701da5fe6b63663fe9a2ee))
* **transcription:** time more pending speech and filter benchmark arms ([#398](https://github.com/JINGBANZ/jarvis/issues/398)) ([7172541](https://github.com/JINGBANZ/jarvis/commit/71725419e7c1630af0677147b38032ed86a7ba03))

## [0.4.0](https://github.com/JINGBANZ/jarvis/compare/v0.3.3...v0.4.0) (2026-09-21)


### ⚠ BREAKING CHANGES

* **overlay:** keep the overlay box on for every session ([#395](https://github.com/JINGBANZ/jarvis/issues/395))
* **overlay:** remove the overlay caption ([#391](https://github.com/JINGBANZ/jarvis/issues/391))

### Features

* **activity:** pick the agent CLI from an Evaluate menu ([#394](https://github.com/JINGBANZ/jarvis/issues/394)) ([396c064](https://github.com/JINGBANZ/jarvis/commit/396c0649ed0fb3ab9f87237d40450a0c4be98485))
* **overlay:** keep the overlay box on for every session ([#395](https://github.com/JINGBANZ/jarvis/issues/395)) ([acd607d](https://github.com/JINGBANZ/jarvis/commit/acd607d06a6b229d24e9dd06de247ce4b263edc3))
* **overlay:** remove the overlay caption ([#391](https://github.com/JINGBANZ/jarvis/issues/391)) ([656d9da](https://github.com/JINGBANZ/jarvis/commit/656d9da360b0f9163b9488c144c814d6063ea187))


### Bug Fixes

* **coach:** preserve evidence in session memory briefings ([#379](https://github.com/JINGBANZ/jarvis/issues/379)) ([a5098c5](https://github.com/JINGBANZ/jarvis/commit/a5098c5e2d448924be2b84109e0ef40d368b4564))
* **coach:** require a clear gap before admitting later pending speech ([#388](https://github.com/JINGBANZ/jarvis/issues/388)) ([3a06ce2](https://github.com/JINGBANZ/jarvis/commit/3a06ce2b940669562336aadb193092c934c285d3))
* **overlay:** accent ask ai prompt labels ([#386](https://github.com/JINGBANZ/jarvis/issues/386)) ([a8757f4](https://github.com/JINGBANZ/jarvis/commit/a8757f4fb452f386e66341c5dd9a16e52c9ffa06))

## [0.3.3](https://github.com/JINGBANZ/jarvis/compare/v0.3.2...v0.3.3) (2026-09-20)


### Features

* **brain:** move Claude Code to Anthropic's Messages format through the helper ([#372](https://github.com/JINGBANZ/jarvis/issues/372)) ([fb81683](https://github.com/JINGBANZ/jarvis/commit/fb81683374a373f312fd0ffa4fab3793c8cf88f5))
* **shortcuts:** add mouse bindings alongside keyboard shortcuts ([#378](https://github.com/JINGBANZ/jarvis/issues/378)) ([f76a20c](https://github.com/JINGBANZ/jarvis/commit/f76a20cd338123d338bd37620c17fb98e8e0c708))


### Bug Fixes

* **brain:** keep the authored tool-schema key order in encoded requests ([#370](https://github.com/JINGBANZ/jarvis/issues/370)) ([34a37bd](https://github.com/JINGBANZ/jarvis/commit/34a37bd0ad3efdadd4a601212ac04b66e70b7674))
* **coach:** ground coding guidance in evidence ([#381](https://github.com/JINGBANZ/jarvis/issues/381)) ([364f0c7](https://github.com/JINGBANZ/jarvis/commit/364f0c74210bfd567684a3c0d7e230122b40852e))
* **coach:** ground interview hints in configured prep notes ([#365](https://github.com/JINGBANZ/jarvis/issues/365)) ([4d0eab8](https://github.com/JINGBANZ/jarvis/commit/4d0eab81c4cc64a0392e042c91b2c46b56179cea))
* **coaching:** prioritize design intent and keep diagrams readable ([#364](https://github.com/JINGBANZ/jarvis/issues/364)) ([951e1ca](https://github.com/JINGBANZ/jarvis/commit/951e1ca8d2744c3882af7736d38da5adf19ef5b9))
* **coach:** refresh speech context before coaching ([#383](https://github.com/JINGBANZ/jarvis/issues/383)) ([02326ac](https://github.com/JINGBANZ/jarvis/commit/02326ac85973e06fb1bf8e81668b01726cd7e9a7))
* **coach:** restore placement headers above code hints ([#360](https://github.com/JINGBANZ/jarvis/issues/360)) ([500103a](https://github.com/JINGBANZ/jarvis/commit/500103a40ac29d19bf74a299256901c95e2a7179))

## [0.3.2](https://github.com/JINGBANZ/jarvis/compare/v0.3.1...v0.3.2) (2026-09-19)


### Features

* **brain:** add Gemini as a coaching brain over the Interactions API ([#359](https://github.com/JINGBANZ/jarvis/issues/359)) ([3a4f0b0](https://github.com/JINGBANZ/jarvis/commit/3a4f0b03ba62feb3bd35a2e4f48554b6c9a58f75))
* **coaching:** improve code with ai guidance and regression coverage ([#362](https://github.com/JINGBANZ/jarvis/issues/362)) ([24c485c](https://github.com/JINGBANZ/jarvis/commit/24c485c8cdf0f9081fab95ed6c434ef9418cfe17))
* **onboarding:** ask for an API key before the permissions, once per install ([#371](https://github.com/JINGBANZ/jarvis/issues/371)) ([6b6decb](https://github.com/JINGBANZ/jarvis/commit/6b6decbc74ec7196852ab68a1b87e5eb164305c0))
* **overlay:** render a reply's detail in document order ([#366](https://github.com/JINGBANZ/jarvis/issues/366)) ([9794433](https://github.com/JINGBANZ/jarvis/commit/9794433062ae87115a259437c1b5d586bf7fdaee))
* **settings:** let the window buttons sit on the backdrop ([#373](https://github.com/JINGBANZ/jarvis/issues/373)) ([d0c584f](https://github.com/JINGBANZ/jarvis/commit/d0c584f197962e281f5a18d187b503d146d3dc00))


### Bug Fixes

* **proxy:** fail the start when the helper exits during its readiness probe ([#357](https://github.com/JINGBANZ/jarvis/issues/357)) ([eb373d9](https://github.com/JINGBANZ/jarvis/commit/eb373d90e7e476aab656b7dddb8593ed2879a3d7))
* resolve concurrency, naming, and copy findings from the comment trim ([#352](https://github.com/JINGBANZ/jarvis/issues/352)) ([4a6c25c](https://github.com/JINGBANZ/jarvis/commit/4a6c25c41c13440ba28f51848f9f5151c5da1bd3))

## [0.3.1](https://github.com/JINGBANZ/jarvis/compare/v0.3.0...v0.3.1) (2026-09-17)


### Features

* **coach:** check on a quiet candidate after 45 seconds, then back off fourfold ([#342](https://github.com/JINGBANZ/jarvis/issues/342)) ([60ae964](https://github.com/JINGBANZ/jarvis/commit/60ae9641e45ecde10fe28eb53653e991655e1084))
* **overlay:** add detail navigation hotkeys ([#350](https://github.com/JINGBANZ/jarvis/issues/350)) ([5bf7eed](https://github.com/JINGBANZ/jarvis/commit/5bf7eed31db3f10e0d31cb7c0e71ff3822436ca9))
* **settings:** redesign Settings as a robot hub with Tools and Skills pages ([#347](https://github.com/JINGBANZ/jarvis/issues/347)) ([40fec24](https://github.com/JINGBANZ/jarvis/commit/40fec24e0749562895542cc6bd5399bcbc84c065))


### Bug Fixes

* **coach:** restore code alongside actionable hints ([#349](https://github.com/JINGBANZ/jarvis/issues/349)) ([16815be](https://github.com/JINGBANZ/jarvis/commit/16815bea3efdd430f613bd830604ef45089ed53a))

## [0.3.0](https://github.com/JINGBANZ/jarvis/compare/v0.2.4...v0.3.0) (2026-09-16)


### ⚠ BREAKING CHANGES

* **coach:** `speak.mermaid`, `speak.explanation`, and `speak.codeSnippet` are gone, and the three switches with them. Activity rows written before this change still decode and still render their own sections.
* **brain:** saved brain routes that name claude-code or codex-cli fall back to the default primary and drop those fallback rows; pick the subscription targets in Settings → Brain.

### Features

* **brain:** serve Codex and Claude subscriptions through a bundled CLIProxyAPI and remove the CLI coaching providers ([#335](https://github.com/JINGBANZ/jarvis/issues/335)) ([a913f6d](https://github.com/JINGBANZ/jarvis/commit/a913f6de7614ace6a7b9520f65408a06f6a32039))
* **coach:** redesign the coaching prompt around a generic core and a two-box overlay ([#338](https://github.com/JINGBANZ/jarvis/issues/338)) ([926d752](https://github.com/JINGBANZ/jarvis/commit/926d752b2cf09dbe789172cf2f47885205c20f38))

## [0.2.4](https://github.com/JINGBANZ/jarvis/compare/v0.2.3...v0.2.4) (2026-09-15)


### Features

* **brain:** add latest gpt and claude models ([#315](https://github.com/JINGBANZ/jarvis/issues/315)) ([bde57f8](https://github.com/JINGBANZ/jarvis/commit/bde57f87a2391726d06682f3983276b04f31be16))
* **coach:** add coding with ai guidance ([#329](https://github.com/JINGBANZ/jarvis/issues/329)) ([0f0fd07](https://github.com/JINGBANZ/jarvis/commit/0f0fd0714ddcc30b99dd1c0a003b8dd8a6e976e9))
* **coach:** let the coaching shortcuts load skills and tools before speaking ([#318](https://github.com/JINGBANZ/jarvis/issues/318)) ([d4f64b2](https://github.com/JINGBANZ/jarvis/commit/d4f64b272b6c5ccb5797eae6355e8c2ee67bb5eb))
* **coach:** load coaching skills on demand and retire the interview format ([#305](https://github.com/JINGBANZ/jarvis/issues/305)) ([04552c8](https://github.com/JINGBANZ/jarvis/commit/04552c899bd7f7ead0e2c6905afa8372a9b6a9ef))
* **coach:** load coaching tools on demand and let the user switch them off ([#301](https://github.com/JINGBANZ/jarvis/issues/301)) ([a455688](https://github.com/JINGBANZ/jarvis/commit/a455688a1a76aa1ba89db30d373e0db789976d6a))
* **coach:** retain bounded screen context across scrolling ([#290](https://github.com/JINGBANZ/jarvis/issues/290)) ([0e45558](https://github.com/JINGBANZ/jarvis/commit/0e4555885d7c94d46292d3d39b61f2df6a61ccb9))
* **overlay:** make the code and hint divider draggable ([#313](https://github.com/JINGBANZ/jarvis/issues/313)) ([5575e03](https://github.com/JINGBANZ/jarvis/commit/5575e03951323a9770305c107eb7a9768b86af15))


### Bug Fixes

* **brain:** reset the signal mask and dispositions when spawning a runtime cli ([#326](https://github.com/JINGBANZ/jarvis/issues/326)) ([42d6e49](https://github.com/JINGBANZ/jarvis/commit/42d6e49bb8f53ad93cc2a5a1fdcd6f3d2acc2baa)), closes [#325](https://github.com/JINGBANZ/jarvis/issues/325)
* **coach:** enforce the turn's tool choice and recover bad replies in the attempt runner ([#330](https://github.com/JINGBANZ/jarvis/issues/330)) ([8684d29](https://github.com/JINGBANZ/jarvis/commit/8684d292502801a8372a1c2b87505187cc0a156e))
* **coach:** favor readable interview code hints ([#316](https://github.com/JINGBANZ/jarvis/issues/316)) ([b0f3057](https://github.com/JINGBANZ/jarvis/commit/b0f3057ec4d22e749999b9a5f496a683b475b11b))
* **coach:** follow up the provider recovery review from [#283](https://github.com/JINGBANZ/jarvis/issues/283) ([#307](https://github.com/JINGBANZ/jarvis/issues/307)) ([6d75b2c](https://github.com/JINGBANZ/jarvis/commit/6d75b2c1158920876c25eef25baeb56013ef7de4))
* **coach:** ground behavioral hints in prepared evidence ([#324](https://github.com/JINGBANZ/jarvis/issues/324)) ([0c1c794](https://github.com/JINGBANZ/jarvis/commit/0c1c7941ce0c9a34452422b3ac8563144291c868))
* **connections:** discover nvm and bundled agent clis ([#314](https://github.com/JINGBANZ/jarvis/issues/314)) ([aaa1c34](https://github.com/JINGBANZ/jarvis/commit/aaa1c345e5bb4b79be935ef7665f798d723493ea))
* **overlay:** retain code across hints without snippets ([#317](https://github.com/JINGBANZ/jarvis/issues/317)) ([740ac07](https://github.com/JINGBANZ/jarvis/commit/740ac07fef2cf25537dca2034b40c0aa593b9dc6))

## [0.2.3](https://github.com/JINGBANZ/jarvis/compare/v0.2.2...v0.2.3) (2026-09-13)


### Features

* **overlay:** configure automatic code display and appearance ([#289](https://github.com/JINGBANZ/jarvis/issues/289)) ([a343988](https://github.com/JINGBANZ/jarvis/commit/a34398853e3eccc30bd0d67ff5898fd233f9c391))
* **overlay:** pin system design diagrams for the session ([#291](https://github.com/JINGBANZ/jarvis/issues/291)) ([b7cade6](https://github.com/JINGBANZ/jarvis/commit/b7cade6ad5f8595f82e7285a7a9b9f52aecf2cd5))
* **providers:** consolidate provider failure handling and surface the cause in Activity ([#284](https://github.com/JINGBANZ/jarvis/issues/284)) ([cf503f5](https://github.com/JINGBANZ/jarvis/commit/cf503f55a5a39763250385db5e5110436eed5e61))


### Bug Fixes

* **coach:** bound failed coaching cycles without stopping recoverable sessions ([#283](https://github.com/JINGBANZ/jarvis/issues/283)) ([5057848](https://github.com/JINGBANZ/jarvis/commit/505784867944cfa78154f740bc8cfc856ca5029b))
* **coach:** code snippets drop valid payloads, miscolor directives, and re-lex on resize ([#295](https://github.com/JINGBANZ/jarvis/issues/295)) ([199accd](https://github.com/JINGBANZ/jarvis/commit/199accda539fcac4be96f6a35438e0911ef2e913))
* **coach:** resolve one fixed tool set per session ([#274](https://github.com/JINGBANZ/jarvis/issues/274)) ([39715e5](https://github.com/JINGBANZ/jarvis/commit/39715e59d23d8c6ed1795f343d716c8a6bed5eed))
* **evaluation:** use session version identity with disclosed source fallback ([#293](https://github.com/JINGBANZ/jarvis/issues/293)) ([6fe8726](https://github.com/JINGBANZ/jarvis/commit/6fe872680663864ead657040090d64cf45e6383d))

## [0.2.2](https://github.com/JINGBANZ/jarvis/compare/v0.2.1...v0.2.2) (2026-09-10)


### Features

* **coach:** add behavioral interview skill ([#262](https://github.com/JINGBANZ/jarvis/issues/262)) ([5f0c260](https://github.com/JINGBANZ/jarvis/commit/5f0c260a93b35001326cad0cf1533a113ffd912e))
* **coach:** add coding and opt-in general technical skills ([#261](https://github.com/JINGBANZ/jarvis/issues/261)) ([b6f1ff8](https://github.com/JINGBANZ/jarvis/commit/b6f1ff8f7ed9408eefe162f0babe5a8a64e1dc83))
* **coach:** explain confusion proactively and on shortcut ([#270](https://github.com/JINGBANZ/jarvis/issues/270)) ([c221510](https://github.com/JINGBANZ/jarvis/commit/c22151035bcfd8390f3cf086e3e38c68a7f70c68))
* **coach:** give question meaning before strategy when the user hasn't engaged ([#257](https://github.com/JINGBANZ/jarvis/issues/257)) ([e4d7098](https://github.com/JINGBANZ/jarvis/commit/e4d70983864dc2be9c11e7546de9f87e22f028a0))
* **coach:** show contextual code snippets with hints ([#272](https://github.com/JINGBANZ/jarvis/issues/272)) ([df34152](https://github.com/JINGBANZ/jarvis/commit/df3415208609fd1d1c4402ecfad78de0c1b9dfc4))
* **coach:** show private system-design diagram hints ([#267](https://github.com/JINGBANZ/jarvis/issues/267)) ([b1272b4](https://github.com/JINGBANZ/jarvis/commit/b1272b4f5b6b2fd925f44903fadf9e11a0a6a61b))
* **overlay:** add a header to the Overlay Box and draw its resize affordance ([#269](https://github.com/JINGBANZ/jarvis/issues/269)) ([8a83228](https://github.com/JINGBANZ/jarvis/commit/8a83228eac1c5397956f79c01d1f52e6796fd51f))
* **overlay:** show the session interview format above history ([#281](https://github.com/JINGBANZ/jarvis/issues/281)) ([23b978b](https://github.com/JINGBANZ/jarvis/commit/23b978bb3825f384ed038db235a83f1bf68ee0ea))
* **transcription:** add Gemini as a third transcription provider ([#268](https://github.com/JINGBANZ/jarvis/issues/268)) ([dc3d02c](https://github.com/JINGBANZ/jarvis/commit/dc3d02c35b5a37be7843b2718be952f02090d19d))


### Bug Fixes

* **activity:** separate hint explanation and code sections ([#286](https://github.com/JINGBANZ/jarvis/issues/286)) ([2147360](https://github.com/JINGBANZ/jarvis/commit/2147360e40999da653f960a0cb0fcbf21267cd53))
* **coach:** clarify explanation policy ([#285](https://github.com/JINGBANZ/jarvis/issues/285)) ([f08b9ba](https://github.com/JINGBANZ/jarvis/commit/f08b9bab99c37e0f7555b322d835a543aad4ed2d))
* **overlay:** wrap and fit code snippets within the panel ([#287](https://github.com/JINGBANZ/jarvis/issues/287)) ([0316d7f](https://github.com/JINGBANZ/jarvis/commit/0316d7f515018c97a07de80e520a3bfb86c8116b))
* **settings:** keep shortcut cards at full width ([#282](https://github.com/JINGBANZ/jarvis/issues/282)) ([3a3fb21](https://github.com/JINGBANZ/jarvis/commit/3a3fb21a99df83ed72aea77d2ba924944f080dbd))

## [0.2.1](https://github.com/JINGBANZ/jarvis/compare/v0.2.0...v0.2.1) (2026-09-05)


### Features

* **coach:** sequence core entities before API design in the system-design skill ([#258](https://github.com/JINGBANZ/jarvis/issues/258)) ([af71940](https://github.com/JINGBANZ/jarvis/commit/af71940d2af8ac99a5357173d4860ce80e32c173))
* **menubar:** adopt boxless closed-to-open eye ([#264](https://github.com/JINGBANZ/jarvis/issues/264)) ([4783811](https://github.com/JINGBANZ/jarvis/commit/478381138127940e8ff9ba953c8be19dcdf80ab1))
* **overlay:** show the Overlay Box on Start and hide it on Stop ([#255](https://github.com/JINGBANZ/jarvis/issues/255)) ([aef9837](https://github.com/JINGBANZ/jarvis/commit/aef983729b36381b817bfb8d2fffc69dbe8d3d9e))


### Bug Fixes

* **viewer:** tighten export sheet spacing, add export naming/image options ([#265](https://github.com/JINGBANZ/jarvis/issues/265)) ([401025f](https://github.com/JINGBANZ/jarvis/commit/401025f38106aa57485731dc2be82e771671fc96))

## [0.2.0](https://github.com/JINGBANZ/jarvis/compare/v0.1.12...v0.2.0) (2026-09-03)


### ⚠ BREAKING CHANGES

* **permissions:** Jarvis will not run without all three grants. The Permissions tab in Settings is removed; the launch gate is the only path.

### Features

* **activity:** export session history to Markdown, plain text, or HTML ([#230](https://github.com/JINGBANZ/jarvis/issues/230)) ([eb71f2c](https://github.com/JINGBANZ/jarvis/commit/eb71f2c0588932cd6e2c7bee9ee027acdce87af4))
* **capture:** replace classic WebRTC VAD with Silero for local turn detection ([#238](https://github.com/JINGBANZ/jarvis/issues/238)) ([b512e0c](https://github.com/JINGBANZ/jarvis/commit/b512e0c3d1148501a65dd0c50e452b9168a9121e))
* **coach:** add an interview-format picker with a system-design vocabulary addendum ([#252](https://github.com/JINGBANZ/jarvis/issues/252)) ([26b31c3](https://github.com/JINGBANZ/jarvis/commit/26b31c3fac3f6f0ff1d5b780e31c53f8156ccd09))
* **coach:** scope prep-notes search queries to the current sub-topic ([#251](https://github.com/JINGBANZ/jarvis/issues/251)) ([2205ede](https://github.com/JINGBANZ/jarvis/commit/2205edec861f0cabc75dd9dd85842064a2ff536f))
* **menu:** add a Clear Overlay menu item ([#243](https://github.com/JINGBANZ/jarvis/issues/243)) ([d888980](https://github.com/JINGBANZ/jarvis/commit/d888980883cd55af61fcdb9cfea6c8b01e265b30))
* **menubar:** mark a local build with a red "Dev" caption ([#223](https://github.com/JINGBANZ/jarvis/issues/223)) ([55fa248](https://github.com/JINGBANZ/jarvis/commit/55fa2482d76a33fbc4da241b59a3c2bdadb2ab6d))
* **permissions:** gate Jarvis behind every grant, proved live ([#233](https://github.com/JINGBANZ/jarvis/issues/233)) ([cab1196](https://github.com/JINGBANZ/jarvis/commit/cab1196e9bd723b5cdbd98f5c8a72a8b11e9643c))
* **prep:** add local prep-material source configuration to Settings ([#220](https://github.com/JINGBANZ/jarvis/issues/220)) ([5b10338](https://github.com/JINGBANZ/jarvis/commit/5b10338e5eb354a57589ecc81eccb3bfb134b744))
* **prep:** add prep-notes retrieval to the coaching tool loop ([#226](https://github.com/JINGBANZ/jarvis/issues/226)) ([5e66681](https://github.com/JINGBANZ/jarvis/commit/5e6668102a602ce56e0b6d75edf6306395454b13))
* **shortcuts:** make the manual hint hotkey configurable ([#235](https://github.com/JINGBANZ/jarvis/issues/235)) ([a8e86d6](https://github.com/JINGBANZ/jarvis/commit/a8e86d63e3bc2ce92d42c659aea8f33f4b396d7d))
* **transcription:** add vocabulary keyword hints for GPT Transcribe/Live ([#242](https://github.com/JINGBANZ/jarvis/issues/242)) ([42ce409](https://github.com/JINGBANZ/jarvis/commit/42ce4091128cf3684b2ff72aa4f3c05bfdb4ceed))


### Bug Fixes

* **brain:** stop a codex prewarm from trading evictions with an attempt's open ([#250](https://github.com/JINGBANZ/jarvis/issues/250)) ([04c5104](https://github.com/JINGBANZ/jarvis/commit/04c51047a237cbec59127b3c72f4fe7c61c08c22))
* **capture:** make LocalTurnDetector Sendable so the build is warning-free ([#245](https://github.com/JINGBANZ/jarvis/issues/245)) ([2343dbb](https://github.com/JINGBANZ/jarvis/commit/2343dbb7faf70838bd721cad825d8e819b6c28ae))
* **diagnostics:** account for Codex one-shot exec token usage ([#193](https://github.com/JINGBANZ/jarvis/issues/193)) ([be98777](https://github.com/JINGBANZ/jarvis/commit/be98777d4271c641f55333ad57ddfbd0ace87b5f))

## [0.1.12](https://github.com/JINGBANZ/jarvis/compare/v0.1.11...v0.1.12) (2026-08-24)


### Features

* **app:** light the menu-bar icon while a session is live ([#189](https://github.com/JINGBANZ/jarvis/issues/189)) ([725e1bc](https://github.com/JINGBANZ/jarvis/commit/725e1bcc54269a8fcbfd70e258dff9fc43e76ed1))


### Bug Fixes

* make coaching turns diagnosable and history compaction actually work ([#187](https://github.com/JINGBANZ/jarvis/issues/187)) ([7fdb6a4](https://github.com/JINGBANZ/jarvis/commit/7fdb6a4bf2af72c8b5d3516559f7824a074aab7d))

## [0.1.11](https://github.com/JINGBANZ/jarvis/compare/v0.1.10...v0.1.11) (2026-08-22)


### Bug Fixes

* **coach:** ground tip vocabulary in what the user can already see ([#186](https://github.com/JINGBANZ/jarvis/issues/186)) ([fdc3714](https://github.com/JINGBANZ/jarvis/commit/fdc3714f5d6f13cfba75cdf580ab73f406d0dbc5))

## [0.1.10](https://github.com/JINGBANZ/jarvis/compare/v0.1.9...v0.1.10) (2026-08-18)


### Bug Fixes

* **release:** remove sparkle's top-level xpc services alias ([#181](https://github.com/JINGBANZ/jarvis/issues/181)) ([f81758e](https://github.com/JINGBANZ/jarvis/commit/f81758eb8a2e3a45fe460b5ce54c31ccb6a32775))

## [0.1.9](https://github.com/JINGBANZ/jarvis/compare/v0.1.8...v0.1.9) (2026-08-18)


### Bug Fixes

* **release:** allow framework symlinks when cleaning dmg staging ([#179](https://github.com/JINGBANZ/jarvis/issues/179)) ([4c0dae1](https://github.com/JINGBANZ/jarvis/commit/4c0dae155973ad2e96c7122b49353bf2cd517b86))

## [0.1.8](https://github.com/JINGBANZ/jarvis/compare/v0.1.7...v0.1.8) (2026-08-18)


### Features

* **menubar:** add check for updates via sparkle ([#177](https://github.com/JINGBANZ/jarvis/issues/177)) ([5d5fd34](https://github.com/JINGBANZ/jarvis/commit/5d5fd344e7b8080efa65ae9311ebd6f23f31102b))
* **menubar:** show the build version in the menu ([#175](https://github.com/JINGBANZ/jarvis/issues/175)) ([28815cb](https://github.com/JINGBANZ/jarvis/commit/28815cbc11021ac95437186e8dac760c1628841f))

## [0.1.7](https://github.com/JINGBANZ/jarvis/compare/v0.1.6...v0.1.7) (2026-08-17)


### Bug Fixes

* **release:** preserve signed app integrity ([#173](https://github.com/JINGBANZ/jarvis/issues/173)) ([c95c240](https://github.com/JINGBANZ/jarvis/commit/c95c2405962f3e808ee0413d45bca37da631a427))

## [0.1.6](https://github.com/JINGBANZ/jarvis/compare/v0.1.5...v0.1.6) (2026-08-17)


### Features

* **release:** add guided DMG installer layout ([#169](https://github.com/JINGBANZ/jarvis/issues/169)) ([d1da170](https://github.com/JINGBANZ/jarvis/commit/d1da170c4786e4992a321d5a0a34756af5981f3c))
* **settings:** separate shared connections from brain ([#170](https://github.com/JINGBANZ/jarvis/issues/170)) ([2a9ff0f](https://github.com/JINGBANZ/jarvis/commit/2a9ff0f698d34a7ac0d3ae76e3a7a716e42f2c56))

## [0.1.5](https://github.com/JINGBANZ/jarvis/compare/v0.1.4...v0.1.5) (2026-08-17)


### Bug Fixes

* **release:** staple app before packaging dmg ([#166](https://github.com/JINGBANZ/jarvis/issues/166)) ([1eca91f](https://github.com/JINGBANZ/jarvis/commit/1eca91f10351dd54530efd5d904dcdc017917158))

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
