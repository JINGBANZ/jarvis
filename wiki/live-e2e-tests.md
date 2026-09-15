# Live E2E Tests

> One command drives the real signed app through scripted interview scenarios while the developer
> keeps using the Mac, then asserts every case on the session folders the app leaves behind. This page holds the why
> and the case index; the steps live in the scenario files and the predicates in the checker.

## What the run is and is not

`./scripts/run-live-tests.sh` launches `Jarvis Dev.app` once per scenario in an explicit live e2e
mode. Interviewer and candidate lines are synthesized at run time and fed as audio into real OpenAI
transcription. The real coach loads skills and tools on demand, switches between all three brains,
views a fixture screenshot when it asks for the screen, delivers to the real overlay panels, and
writes a normal session directory. A test target then reads that directory and records one result per case ID.

The mode is a sibling of the [transcription benchmark](./transcription-benchmark.md) and follows its
conventions: `--live-e2e` in `Sources/JarvisApp/App/main.swift` selects `LiveE2EAppDelegate`
(`Sources/JarvisApp/LiveE2E/`), a hidden `.prohibited` process like the benchmark's. It is an app
mode rather than a test process calling the libraries because the run has to exercise the signed
app's TCC identity, capture edge, and composition, which only the bundle has.

`LiveE2ERunner` hosts the brain composition and drives one scenario through `SessionComposition`,
the object a production Start uses ([architecture.md → Components](./architecture.md#3-components)).
Two ports are substituted: the audio source, `FixtureAudioSource` in place of
`AggregateEchoCapture`, and the screen capture, `FixtureScreenCapture` in place of
`WindowScopedScreenCapture`. The composition also takes an optional attempt-auditing factory;
production records straight into the session evidence, and the runner wraps it to watch attempts
start and finish. The Foundation-only scenario model, launch options, and audio timeline live in
`Sources/JarvisCore/LiveE2E/`.

The run is not:

- **Part of the Gate or CI.** It reaches real providers and needs TCC grants and signed-in CLIs. The
  Gate compiles the `JarvisLiveTests` target but never runs it
  ([build-and-run.md → Toolchain](./build-and-run.md#toolchain)). Unit targets never reach a
  provider; anything that does lives under `Tests/JarvisLiveTests/`, so there is one mechanism for
  live verification rather than environment-gated tests hidden inside unit targets.
- **A timing test.** Press-to-tip and question-to-tip times are printed as `time` lines and never
  asserted, because provider latency varies between runs.
- **A transcription comparison.** It uses one transcription model as configured. The benchmark owns
  model comparison, Apple Speech, and reconnect.
- **A UI test.** Nothing asserts on Settings, the menu, or overlay rendering. Overlay rendering and
  capture exclusion are covered by the overlay tests in the Gate.
- **A way to force rare paths.** A real model cannot be made to hit the response cap, load inside a
  failed attempt, trigger compaction, or call an unknown name on purpose, and the recovery cooldown
  and ceiling need a clock the run does not control. Those stay in scripted-brain tests in the Gate.

## Prerequisites and standing conditions

The toolchain is the one [build-and-run.md → Toolchain](./build-and-run.md#toolchain) describes.
Set up once per machine:

- **Microphone, System Audio Recording, and Screen Recording**, granted to the development identity.
  The grants survive rebuilds because `build-app.sh` signs with a stable identity
  ([build-and-run.md → Packaging & signing](./build-and-run.md#packaging--signing--why-permission-grants-persist)).
  Screen Recording is part of the readiness a Start checks, though no scenario shoots the screen.
  Nothing needs Accessibility or Automation: the runner requests shortcuts through the composition.
- **An OpenAI key** saved in Settings, which writes the owner-only secrets file. Every scenario
  transcribes through OpenAI. `OPENAI_API_KEY` does not serve the run: the app is launched through
  `open`, and LaunchServices does not pass the shell's environment.
- **Claude Code and Codex CLIs**, installed and signed in. The launcher's preflight checks the key and
  both CLIs before the first launch, so a missing login stops the run in seconds instead of surfacing
  as a failed scenario.

During a run:

- **The Mac stays usable.** Nothing reads the screen and no window opens, so the developer keeps
  working. The overlay panels do appear over that work while a scenario coaches.
- **Scenario R hears the room.** It records the real microphone and system audio for the few seconds
  from Start to coaching ready, so keep calls and media off while it runs.
- **No other Jarvis Dev.app runs.** Two instances would contend for the capture device and the session
  base, so the script refuses to start beside one.

## Running it

```sh
./scripts/run-live-tests.sh [A|B|R|F01|F02|F04|all] [--evaluate] [--keep-going]
```

The script refuses while a Jarvis Dev.app runs, re-executes itself under `caffeinate -d -i`, builds
with `./scripts/build-app.sh debug`, creates the run directory, and runs the `JarvisLiveTests` target
filtered to the chosen scenarios. `F01` selects both F01 scenario files. Each test launches the app
with its scenario, waits for the app to exit, and asserts on the session folder.
`Tests/JarvisLiveTests/LiveE2ELauncher.swift` holds the preflight and the launch.

- `--keep-going` runs every chosen scenario. Without it the run stops after the first scenario that
  writes a `fail` line, since later scenarios spend model calls and a failure deserves a look first.
- `--evaluate` runs [`scripts/eval-session.sh`](../scripts/eval-session.sh) on Scenario A's session
  and adds a G09 line. It is off by default because evaluation is an agentic run of its own, not part
  of coaching.

Scenario A's one OpenAI turn holds the only metered coaching requests; every other brain response
runs on a CLI subscription.

## Run directory and results

```text
.jarvis/live-e2e/<run>/     owner-only (0700); the newest ten runs are kept
  results.txt               one line per case ID, plus time lines
  <id>/                     one per launch, named by the scenario file
    scenario.json
    steps.jsonl             each step and the attempt it waited on
    session/dev-…/          a normal session directory
    live-e2e-finished       or live-e2e-error.json
```

A result line is `<case> pass`, `fail`, `note`, or `skipped`. `pass` and `fail` come from assertions.
`note` records a model's choice and never affects the exit code (see
[Notes and the rerun rule](#notes-and-the-rerun-rule)). The `skipped` lines are fixed: G07 (offline),
G10 (dropped), C21 (optional), and F03, R01, R02, S01 (manual). The exit code counts only `fail`
lines, missing finished markers, and a failed test process, so a launch that dies mid-scenario fails
the run even when no assertion ran.

Each session directory is an ordinary one, so `scripts/eval-session.sh` or an agent reads it like any
other. Run directories hold screenshots and finalized speech, which is why they stay owner-only under
`.jarvis/` with the same bounded retention as benchmark runs. Synthesized speech is deleted right
after decoding, and no audio is archived.

## Scenarios

Capabilities are fixed at Start, so each switch configuration is its own scenario; brain switches
happen inside a scenario, applied the way a Settings edit applies them. Steps live in
`Tests/JarvisLiveTests/Scenarios/`; fixtures in `Tests/JarvisLiveTests/Fixtures/` are the coding
screenshot `coding-problem.jpg` and fictional `prep-notes.md`.

| Scenario | Brain | What it drives |
|---|---|---|
| A | Claude Code, then OpenAI, then Codex | Every capability on, prep notes from the fixture. Presses and spoken turns across coding, behavioral, and design questions. The OpenAI turn is the interviewer's spoken design question, which states the agreed requirements and asks for the high-level architecture, the stage where the system-design skill attaches a diagram, so the switch runs in both directions and the metered requests stay on one turn. |
| B | Codex | Behavioral, system design, and prep search off. A fresh-session press on the coding screen, then a behavioral question. |
| R | Codex | The real capture device with no speech: Start, coaching ready, Stop. |
| F01 | Codex | Two launches, `F01-system` and `F01-microphone`: a fixture source that delivers no system frames, then one that delivers no microphone frames. |
| F02 | Codex | Transcription with a run-local invalid OpenAI key. |
| F04 | Claude Code alone | A stub executable in place of the CLI; see [F04 and the stub](#f04-and-the-stub). |

## How a scenario runs

- **Isolated preferences.** Brain route and capability switches go to the private defaults suite
  `com.jarvis.coach.dev.live-e2e`, cleared per scenario, so a run never reads or changes the
  developer's own settings. Each brain provider uses its default model, and transcription is pinned
  to `gpt-4o-transcribe`.
- **Synthesized speech.** `FixtureSpeech` renders each line with `/usr/bin/say` to 24 kHz PCM16 at
  run time and deletes the file right after decoding. `FixtureAudioSource` feeds both transcription
  streams as audio frames; nothing plays through the speakers.
- **Waits on attempts, never timers.** A spoken step waits for the next `turn_end` attempt to finish,
  a press for its manual attempt. Pacing follows the app's own state, which is what lets the
  chronology and in-flight cases land where they are meant to whatever the provider latency.
- **An injected screen.** A `screen` step hands a JPEG fixture to `FixtureScreenCapture`, and every
  later capture returns that image with its on-device recognized text, the snapshot shape the window
  path produces. Only coding needs one: an interviewer states behavioral and design questions aloud,
  so Scenario A speaks its design question rather than showing it.

## Evidence rules

- **Order and count, never wording or duration.** Model phrasing and latency vary between runs, so
  every assertion is an ordering or a count, labeled with its case ID so a failure names the case.
- **Stored order is not spoken order.** Activity rows and attempt transcripts keep insertion order,
  and `ConversationChronology` orders them by speech time for the viewer and the model, so a
  chronology case compares speech times rather than positions in a file.
- **Activity rows belong to attempts by time and file order.** An Activity row carries no attempt id,
  and attempt records stamp whole seconds. The checker assigns a row to the attempt whose start and
  finish bracket its second and breaks ties by file order, which is safe because attempts are strictly
  serialized. `LiveSessionEvidence` in `Sources/JarvisEvaluation/` implements the rule and is tested
  offline in the Gate.
- **Load counts run over committed attempts.** A capability load inside a failed attempt is discarded
  by design ([architecture.md → Capabilities](./architecture.md#capabilities)), so uniqueness and
  count checks on loads ignore attempts that did not commit a turn.
- **Steps map to attempts through `steps.jsonl`.** The automatic silence check is armed at Start and
  can add attempts between steps, so the Nth attempt is not the Nth step. The runner records which
  attempt each step waited on, and the checker reads that map instead of counting.

## Notes and the rerun rule

Some cases depend on what the model chose rather than on what the app did, and those write a `note`
line instead of failing: C02 and G05 (staying silent on small talk), C03 (which skill the model
picks), the second request in C11, the Codex diagram in C12, C13, how Scenario B's behavioral
question ends in C16, C20, and C17 together with C01 and C09 on Scenario B's Codex press. Failing them would fail a correct app on a model's judgment call.

An asserted case that fails because of a model choice gets one rerun of its scenario alone; a second
failure is real. No assertion is loosened to make a run pass.

## Three accepted constraints

- **Both speech streams are injected.** `FixtureAudioSource` hands frames straight to the two real
  transcription sessions, so the run is silent. Everything downstream of the audio source is
  production code, which is all the coaching cases need. Playing the interviewer into a private
  process tap, the way the benchmark does, would add a Core Audio edge the benchmark already covers
  and no coaching coverage in return.
- **Only Scenario R touches the real audio device.** The physical microphone, the aggregate device,
  echo cancellation, and the system-wide tap run only in R, which starts the production capture and
  waits for readiness on real frames. The [transcription benchmark](./transcription-benchmark.md)
  covers the tap with known audio, and the permission gate walk stays manual.
- **The screen is injected.** No scenario shoots the Mac's screen, so the front-window pick, the
  `screencapture` helper, and its cleanup run only in their Gate tests (`FrontWindowSelectorTests`,
  `ScreenCaptureRunnerTests`) and in everyday use. A real front window would need an idle, unlocked
  Mac for the whole run, and a click during it would send whatever window came forward to a
  provider, where the checker cannot tell it from the fixture.

## F04 and the stub

F04 proves that a failed coaching cycle keeps listening and that new speech opens a fresh budget on
the same target without Start ([architecture.md → Ordered provider route](./architecture.md#ordered-provider-route)).
Claude Code is the only brain, pointed at a stub executable that exits at once. Every local-agent
process failure is temporary by design
([`LocalAgentFailureClassifier`](../Sources/JarvisCore/Providers/LocalAgent/LocalAgentFailureClassifier.swift)),
so each of three questions is its own cycle: its turn-end attempt and two pending-work retries fail
on the same target, one "coaching failed; listening continues" row follows, and no request is made
until the next question opens a fresh budget. A marker file then makes the stub hand over to the real CLI,
and the next question gets a tip on the same target.

An invalid key cannot stand in for the stub. A 401 is a permanent failure: it exhausts a lone target
on the first attempt, excludes it for the rest of the session, and ends the session, so there is no
cycle left to recover. The recovery cooldown and the ten-minute ceiling stay unit-tested, since the
first failed cycle's cooldown is zero and the run has no clock to advance.

## Case index

Where names the scenario and, when it helps, the moment in it. The steps are in the scenario files;
each case's predicate is in `Tests/JarvisLiveTests/LiveE2ETests.swift`, labeled with its ID.

### On-demand tools and skills

| ID | Case | Where |
|---|---|---|
| C01 | A press loads what its screen needs and still ends in one clean tip | A: the Claude Code press; B: the Codex press |
| C02 | Small talk loads nothing | A: the interviewer's logistics line |
| C03 | The first behavioral question picks the behavioral skill | A: the first behavioral question |
| C04 | An already-loaded kind never reloads | A: every turn on Codex |
| C05 | Prep search loads on demand and stays callable on every brain | A: the first behavioral question and the OpenAI design question |
| C06 | The behavioral skill loads before the first behavioral tip | A: the first behavioral question |
| C07 | The longest realistic chains stay inside one attempt | A: the first behavioral question and the OpenAI design question |
| C08 | A second prepared question searches without loading, on another brain | A: the second behavioral question, on Codex |
| C09 | The coding skill loads on the coding screen | A: the first press; B: the Codex press |
| C10 | The whole session shows four load rows, each once | A, after Stop |
| C11 | A press after the load is one round trip | A: the two Codex presses |
| C12 | A diagram arrives at the architecture stage, on OpenAI and on a CLI brain | A: the OpenAI design question and the Codex follow-up |
| C13 | No diagram outside that stage | A: the coding and behavioral turns |
| C14 | A brain switch keeps loaded state, in both directions | A: Claude Code to OpenAI, then OpenAI to Codex |
| C15 | Coaching continues after loads on Claude Code and on Codex | A |
| C16 | A switched-off skill is never loaded, and its question gets generic coaching | B: the behavioral question |
| C17 | The remaining skill still loads when others are off | B: the Codex press |
| C18 | Prep search off leaves no tool and no catalog line | B: the Codex instructions |
| C19 | Switched-off capabilities apply as configured | B: the Codex instructions list only coding |
| C20 | Text-protocol fallbacks are reported | A and B: the debug log |
| C21 | Loaded guidance survives compaction | Not scheduled; unit-tested |

### General coaching flow

| ID | Case | Where |
|---|---|---|
| G01 | Start reaches coaching ready on real frames, and both sides are heard | R; A: the first "them" and "me" lines |
| G02 | Overlapping speech keeps chronology | A: the reply that starts inside the design question |
| G03 | Speech during an in-flight attempt waits its turn | A: the cache question |
| G04 | The screen gate captures once, only when needed, and passes the recognized text | A: the first press and the "solve this in one pass" line; none on stated questions |
| G05 | A deliberate no-op is visible | A: the interviewer's logistics line |
| G06 | The hint shortcut works, and a second hint advances | A: the presses |
| G07 | Overlays are excluded from screenshots | Offline, in the Gate |
| G08 | Stop ends cleanly and leaves no CLI child or Codex home | Every scenario |
| G09 | Evaluate works on the stopped session | `--evaluate`, on A's session |
| G10 | The development menu has no update item | Dropped; `build-app.sh` strips the feed |

### Faults and change-triggered checks

| ID | Case | Where |
|---|---|---|
| F01 | Frames never arrive | F01: no system frames degrades to microphone-only; no microphone frames ends the session |
| F02 | The transcription provider refuses the key | F02: the session ends naming the rejection and `invalid_api_key` |
| F03 | The permission gate walk | Manual |
| F04 | A failed coaching cycle keeps listening, and a fresh budget follows without Start | F04 |
| S01 | Realtime reconnect recovery | `./scripts/transcription-benchmark.sh reconnect` |
| R01 | Check for Updates in a signed build | Manual, when update code changes |
| R02 | Evaluate picks the right release source | Manual, when evaluation source selection changes |

## What stays outside the command

These checks need the host network, a second provider, a person at Settings, a signed release, a real
device change, or macOS's own dialogs, so the run cannot perform them. Each names when to run it and
what to confirm; the ones still pending are also tracked in [status.md → Next action](./status.md#next-action).

- **Permission gate walk (F03),** when the gate or its permission probes change, because macOS does not
  let automation click its own permission dialogs. Reset the three services and the one persisted
  marker as [build-and-run.md → Packaging & signing](./build-and-run.md#packaging--signing--why-permission-grants-persist)
  describes, then walk the gate against [architecture.md → Permissions](./architecture.md#permissions).
- **Check for Updates (R01),** when the updater or feed code changes. In a signed release build, confirm
  the item is greyed out while a session runs, enabled once stopped, and reports the app up to date
  against the current release. Releases themselves are verified by the release workflow.
- **Release evaluation source (R02),** when evaluation source selection changes. In an installed
  release, evaluate a stopped session and confirm the button shows **Fetching source…** then
  **Evaluating…**, the recorded version is used after an update, a second evaluation fetches the
  source again, the offline dialog names the session's recorded version, cancelling during the fetch
  leaves no source tree, and Quit ends the run immediately. The contract is in
  [build-and-run.md → The live activity viewer](./build-and-run.md#the-live-activity-viewer).
- **Realtime reconnect (S01),** after changing WebSocket failure handling, generations, the recovery
  buffer, or replay. Run `./scripts/transcription-benchmark.sh reconnect` and confirm both
  scoped-interruption phrases return exactly once; never disable the Mac's network instead.
- **Standard transcription benchmark,** after changing transcription models, capture delivery, or
  finalization. Run `./scripts/transcription-benchmark.sh standard` and read the summary as
  [transcription-benchmark.md](./transcription-benchmark.md) describes.
- **Provider failure with Wi-Fi off,** because the run never touches host networking. With a valid key
  and Wi-Fi off, confirm Start ends the session within about fifteen seconds naming the network cause,
  with no system-audio degradation row before it.
- **Gemini,** because it needs a second provider key. Confirm that selecting Gemini with no Gemini key
  saved refuses Start and names the missing credential, and that switching back to OpenAI starts
  cleanly. Leave a Gemini session past ten minutes and confirm the `goAway` rotation replaces the
  socket with no user-visible notice.
- **Explain more and shortcut bindings,** because the run requests shortcuts without the global
  hotkeys. Press both shortcuts from another app and confirm distinct requests, rebind them
  independently and try a collision, and confirm an explanation after clear confusion and silence
  during healthy progress.
- **Mixed practice,** because it judges coaching on a screen a person changes. With the OpenAI brain,
  work through demonstrated understanding, a local block, a visible bug, completion without tests, and
  valid progress; confirm the overlay stays at most three short lines and healthy progress stays
  silent.
- **Settings route walk,** because it needs Settings and faults on several targets. Check the first-open
  Brain state and the Connections **Add API key** state; with multiple fallbacks, force a temporary
  budget transition, a permanent one-attempt transition, an unavailable-target skip, and final route
  exhaustion; exercise a failed replacement with a pending conversation and Stop during a retry; and
  confirm a successful fallback stays active without changing preferences.
- **Audio-route switch,** because it needs a real device change. Switch devices mid-session and confirm
  Activity says listening continues, the next turn includes any unsent speech, and capture recovers
  without rotating the session.
- **Overlay toggles,** because they live in Settings and persist across launches. Toggle each overlay,
  confirm its controls and preview follow the toggle, and confirm the choice survives relaunch.
- **Session lifecycle in the app,** because the live e2e mode has no menu, Settings, or Activity window.
  Start, Stop, and restart immediately; apply a Settings change to a running session and trigger a
  failed preflight; browse a finished session in Activity.
