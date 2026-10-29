# Test command ownership

Local test commands share one live virtual display per physical Mac. Each command validates and
reuses `Jarvis Tests`, creating it only when absent. The display stays available after success,
assertion failure, cancellation, or setup failure. The runner never destroys it, including during
recovery. Exact test apps and helpers must still exit before the next command is admitted.
The ICC profile and ColorSync registration are also retained; the runner does not install, rename,
delete, or unregister either resource. The identity target is exactly one Jarvis profile and one
registration with the same persistent UUID.

This subsystem covers cooperating updated runners under one designated development account.
It serializes complete commands across worktrees, including builds and teardown. Private preference
suites and workspace-local evidence isolate test data; TCC grants, signing identities, OS caches,
and the retained display state remain shared. Physical screens and unrelated applications retain
their settings and processes.

## Identity and admission

[`descriptor.json`](../scripts/test-display/descriptor.json) pins the descriptor, including its name
`Jarvis Tests` and serial `0x4a560001`. The stable diagnostic label is **`jarvis-test-4a560001`**.
It adds no suffix or registration and does not rename an ICC file. macOS supplies the persistent UUID
and profile filename. The first ordinary display command records the worker's observed UUID and
expected profile path in the journal; subsequent commands require the same identity. A previously
recorded profile identity also remains binding. The worker's constructed `expected_profile`
pathname is an expectation, never evidence that a profile exists or matches its metadata.
Developers run the supported test entrypoints directly: no per-machine approval file or A/B
campaign is required. [Framework acceptance](#acceptance-and-recovery) belongs to changes to the
display framework, while every ordinary run still verifies ownership, isolation, and command cleanup.

The selected serial belongs to the known legacy inventory. There is no alternate identity,
random/PID serial, pool, or fallback. Descriptor/protocol changes require explicit reconciliation.
An existing display must match the fixed identity, geometry, and isolation checks; an invalid or
duplicate display stops the command without replacing it. Stable descriptor inputs alone cannot promise
that macOS never creates extra state or hangs.

[`TestDisplayLayout.swift`](../scripts/test-display/TestDisplayLayout.swift) distinguishes a
headless GUI session from a desktop with real displays. No online screens, or only WindowServer's
`virt` placeholder, permits the test display to become the main screen and remain there between
commands. With physical displays present, creation must preserve their identities, bounds,
mirroring, and main-screen selection. Both created and reused test displays must have the expected
logical and Retina pixel size, be visible to AppKit, and be disjoint from every other screen.
The complete admitted layout must remain unchanged through command completion. A connected display
appearing during that command fails validation; an existing valid Jarvis display is reusable on
both headless and physical desktops.

[`supervisor.py`](../scripts/test-display/supervisor.py) is an ordinary-user external supervisor.
It acquires a permanent file lock in the fixed `/Users/Shared/JarvisTestDisplay` namespace. The
parent must be root-owned and sticky; the atomically created lease directory is developer-owned
`0700`, with regular single-link `0600` state and lock files. Symlinks, wrong owners/modes, hard
links, missing existing state, and malformed state stop admission. Another account receives an
ownership error before desktop access. A waiter uses only lock operations, has a bounded deadline,
and can cancel without disturbing the owner. There is no FIFO or fairness promise.

Exclusive bootstrap creates the initial journal automatically. Under the lock, the supervisor
persists unfinished intent before OS-facing preflight.
The journal holds descriptor, persistent identity, boot and process birth identities, run token,
command/worktree, separate test and lifecycle status, and exact owned-process/pending-launch receipts.
An independently flushed unfinished marker precedes journal replacement. Completion requires
flushed journal replacement and marker removal; a failed write or directory flush leaves admission
blocked even if a visible journal already says `completed`. A dead PID, unlocked file, or reboot
does not prove completion. Normal execution never removes the lock or repairs unfinished state.

The process-only preflight selects possible development apps by the kernel's executable basename
(`pbsi_comm` from `PROC_PIDT_SHORTBSDINFO`), then compares their full kernel executable paths and
process birth identities against the development app pathname. The supported app executable is named `JarvisApp`; unrelated
executables need neither a path lookup nor full process metadata, so an unrelated process whose
executable file was removed or whose effective user differs cannot block admission. The short
snapshot's [kernel access policy](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c)
permits that candidate filter without the full snapshot's effective-user restriction.
Mutable process titles (`pbi_name`) and command arguments supply no identity proof.
Apple's [exec implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exec.c)
sets the executable basename; its
[process-name sysctl](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sysctl.c)
changes the separate process title. Missing kernel metadata, unknown candidate paths, or a changed
candidate birth identity stop admission. Inspection runs in a bounded isolated Python worker and
makes no display queries. A proven existing-app conflict before GUI work records `not-started`
completion and refuses without signalling that app; quitting it permits another attempt. Inspection
errors remain uncertain.

## Whole commands and process roles

All six entrypoints call [`test-display.sh`](../scripts/lib/test-display.sh) before desktop access:

| Entrypoint | Ownership boundary |
| --- | --- |
| `scripts/run-tests.sh` | Entire guard/helper/test command; fixed display locally. |
| `scripts/run-live-tests.sh` | Build, sequential scenarios, evaluation, app/helper exits; supervisor-owned keep-awake process. |
| `scripts/run-settings-tests.sh` | Each app exits before the relaunch phase. |
| `scripts/run-reference-tests.sh` | App and exact native helpers exit; hostile environment inputs remain intact. |
| `scripts/run-capture-privacy-tests.sh` | Same lease and explicitly validated test-display capture target. |
| `scripts/transcription-benchmark.sh` | Entire audio/app command under the same lease, without an unused display. |

`build-app.sh` also holds the lease to protect development bundles and artifacts. Its nested build
guard validates command ancestry; a standalone build takes the same machine lock. A user-requested
`--run` opens the development app, which must quit before another test command can pass preflight.
Only the admitted standalone build root may use `--run`; a nested build may build artifacts but
must use its caller's tracked debug harness to launch an app. The bundle's development plist label
does not select tracking: a standalone release development build runs the native production path.
Independent edits/builds are safe only when they cannot replace an active command's binaries,
bundle, or artifacts. Direct legacy binaries do not cooperate with this lock.

The external supervisor alone owns the lease and journal. A newly created display's native object
is retained by its worker, which stays alive in the AppKit event loop after the command finishes.
This owner starts on demand, has no polling loop, and is not a launch agent or login service. Its
process birth identity is recorded separately from test clients. Later commands use short-lived
validation workers and do not create another owner. The owner does not retain the lease or admit
commands; the supervisor never terminates it. Logout, reboot, or an external process termination can
remove the display; a later command creates it again only if absent. An unexpected owner death
during a command fails that command.

The supervisor launches the admitted root shell in
its own process group and verifies the exact process birth on re-entry. One validated live-to-REF
wrapper transition is allowed. Sibling or arbitrary nested test entrypoints are rejected, including
ones inheriting the same environment. The supervisor owns `caffeinate` directly, so keep-awake
behavior creates no second command admission.

LaunchServices apps can leave that shell's process group. `launch-app` durably prepares one app
launch before `open -W -n -g`; the app registers before AppKit initialization using its launch nonce
and actual executable. Result files and delivered signals are not exit evidence. The supervisor
observes kernel process birth identities, treating only proven absence as exit and rejecting
inspection/permission errors. It never signals a process merely because its name matches.

| Process role | App-phase waits | Final command teardown |
| --- | --- | --- |
| Admitted shell and its test runner | Own the command chain | Root exit and empty original process group required. |
| Registered launch controller descended from the test runner | Excluded, so it can request/wait for an app phase | Exact exit required. |
| Detached registered app and its helper descendants | Exact exit required before the next app phase | Exact exit required. |

Helper scope derives from its owning parent. Production OS adapters depend only on the immutable,
one-method [`ProcessLaunching`](../Sources/JarvisProcess/ProcessLaunching.swift) interface. Its native
default runs a normal process and ignores test ownership context. Provider, capture, evaluation,
and reference logic neither depend on the test runner nor parse its environment.

Development executable composition and test hosts explicitly inject
[`TrackedProcessLauncher`](../Sources/JarvisTestSupport/TrackedProcessLauncher.swift). It obtains a
durable pending receipt **before** the native spawn, adds ownership context to sanitized child
environments internally, then registers the observed child.
Immediate spawn bookkeeping (timing, stdin, cancellation PID and watchdog setup) runs before the
blocking registration round trip, so ownership reporting cannot delay the child's normal lifecycle.
Only a proven failed exec with no child resolves a receipt through authenticated `no-child`;
registration failure and ambiguous spawn errors remain unfinished.
If launch throws after a known spawn, the tracked launcher kills and reaps that exact child before returning
the error. Capture may therefore finish output cleanup without a surviving writer; this local
cleanup never clears a failed registration receipt. Blocking cleanup is still bounded by the
external supervisor's command deadline. The native production launcher preserves Foundation's
normal launch and error behavior without adding a blocking cleanup wait.

The entire `JarvisTestSupport` implementation is compiled only with `DEBUG`, including its context
parser and Python reporter. Release app and native-helper artifacts exclude reporting code.
App bootstrap, helper bootstrap, evaluator CLI, unit process tests and the live controller select
their launcher explicitly; there is no mutable global fallback. App composition forwards the
launcher through proxy sign-in, Activity detection/evaluation and session capture. Helper composition
forwards it through the document store and conversion pool, including `--test-conversion`.
The host helper fixtures use the same handshake through
[`test-command-ownership.py`](../scripts/lib/test-command-ownership.py), including exact child
kill/reap before propagating a registration failure. A parent dying between spawn
and registration leaves uncertainty, even if a result already exists. Pending app-scope launches
also prevent the next app phase. Control processes remain observed at final teardown without
waiting for themselves during app-phase RPCs.

Routine native-helper fixture cleanup requests protocol shutdown and waits for its conversion pool
to close before the owner exits. Intentional crash tests retain their crash behavior. A shutdown
failure fails the fixture; forced cleanup cannot certify a pending launch as completed.

Cancellation forwards the signal to the admitted command group while retaining the lease, socket
and display for a bounded natural-exit grace. Live and benchmark shells write their abort markers,
allow a bounded evidence drain, then request exact app shutdown before waiting for the launcher.
App waits progress in the supervisor's poll loop, so pending app/helper
registrations and proven no-child receipts can finish during that grace; a pending receipt alone
does not fail a wait before its deadline. New app phases are refused. Forced teardown then rejects
new helper preparations, signals each exact client once per force level, and applies the current
TERM/KILL policy to late registrations of already-prepared children. Observed command-group absence
is permanent for that run. Cancellation remains unfinished, including signals during final teardown.
Wait RPC client budgets cover the initial wait plus cancellation grace and forced exit; they do
not block the supervisor from serving other receipts.

Ownership reporters use the supervisor-selected absolute Python interpreter with `-I`. Restricted
helper environments receive only explicit ownership context; hostile PATH, PYTHONPATH, PYTHONHOME,
credential, and proxy test inputs retain their original meaning. Reporter/client processes do not
gain test-command admission by holding context.

## Blocking calls and terminal failure

The Swift worker contains AppKit and private display interfaces, adapted from the pinned
MIT-licensed [DeskPad implementation](../scripts/test-display/DeskPad/README.md). The Python owner
does not import AppKit or ColorSync. It records intent before compiling/starting the worker and
enforces monotonic deadlines from outside the process making synchronous OS calls. Worker, lease,
command, and exit budgets live in `supervisor.py`. There are no automatic create retries or alternate
descriptors.

The worker takes bounded online-display snapshots at admission, after creation when needed, and
after test clients exit. It retains a newly created native object before configuring it, so a later
setup failure cannot release it. Completion requires a validated unchanged layout. A worker that
only inspected an existing display exits; a worker that created it remains idle as its owner.
Supervisor pipe loss also preserves the owner. The worker's diagnostics go to the owner-only machine
log. Capture privacy explicitly selects the admitted screen instead of assuming the main screen is
isolated.

Timeout, unknown launch, worker crash, admitted-root signal death, inspection error, or persistence
failure leaves unfinished state. Lifecycle uncertainty is sticky: an ignored RPC error, late reply,
eventual child death, or zero test exit cannot clear it. Error cleanup can signal exact known clients
and stop a worker only when it has explicitly reported that it owns no display. A creator or worker
with unknown creation status remains alive; cleanup never destroys the display. Such cleanup does
not reopen admission. An ordinary assertion exit can complete verified command cleanup and admit
the next command while preserving its test
status. Zero exit requires successful tests and lifecycle completion.
Failure diagnostics report at most sixteen pending owner PIDs, parent PIDs, scopes and phases,
plus an omitted count, to stderr and `.build/test-ownership.json` for hosted failure artifacts.
Tokens and launch nonces are excluded; diagnostics do not clear uncertainty or authorize admission.

## CI and display-free checks

Hosted workflows explicitly invoke [`run-ci-tests.sh`](../scripts/run-ci-tests.sh). The hosted
runner account still takes the same lease and runs ownership checks, with no virtual display.
An inherited `GITHUB_ACTIONS` value or display ID cannot select that policy. Local hosted-mode
requests and nested supervisors are rejected. Hosted CI proves neither display reuse nor ColorSync
persistence. The local Gate remains required before opening a ready-for-review PR, as specified in
[`CONTRIBUTING.md`](../CONTRIBUTING.md#before-opening-a-pull-request).

[`check-process-launching.py`](../scripts/check-process-launching.py) enforces the production source
and transitive target dependency boundary; its negative fixtures reject ownership context, test
imports and indirect dependencies. Compiled release artifacts are inspected for reporter symbols
and context/protocol strings when validating changes to this boundary.

Both ordinary and hosted unit-test wrappers reject non-debug Swift test configurations before
supervisor or display preflight, including short and equals-form configuration arguments. A release
test host cannot silently use native launches inside a supervised command. Ordinary
`swift build -c release` and standalone `build-app.sh release` / `--run` remain supported. Signed
harness wrappers and native-helper fixture builds use debug configuration explicitly.

[`test-test-display.py`](../scripts/test-test-display.py) runs only copied-checkout, display-free
fixtures. Its fake backend cannot be enabled in the production supervisor by an environment flag.
The real Swift launch paths also run against fake subprocesses in
[`test-test-command-ownership.py`](../scripts/test-test-command-ownership.py), including delayed
registration, full timing order, cancellation, failed exec, helper shutdown during registration,
native defaults under foreign ownership context, and capture cleanup after failed registration of
a TERM-ignoring child. The latter permits a late write only after capture returns and first proves
that the child is absent; it never invokes real screen capture.
The script/workflow and cancellation fixtures also use non-GUI stand-ins. Coverage includes
outer-supervisor signals during an outstanding app wait, slow evidence drain, bounded
TERM-ignoring fallback, late registration, teardown interruption and process-disappearance races.
The display-free Swift layout fixture covers headless main-screen adoption, placeholder transitions,
physical-screen preservation, mirroring, and refusal of display disappearance at completion.
Supervisor fixtures cover automatic first use without approval, retained creator survival after
assertion failure, reuse by later commands, and preservation on setup failure or timeout.
The launch fixture links either Swift Build's combined target objects or the native backend's
per-source objects, with the module paths for both layouts.
Fixture environments strip all inherited `JARVIS_TEST_*` context before adding deliberate inputs, including when Gate
itself runs them under a real supervisor. No fixture can contact the outer owner.

The accepted independent design reviews cover three sets of requirements:

| Review | Required dispositions |
| --- | --- |
| Ownership | Durable preflight intent; exclusive bootstrap and fail-closed writes; one validated command chain; separate test/lifecycle results. |
| Isolation | All six entrypoints; explicit CI policy; exact app/helper exit between phases; environment context never grants admission. |
| Validation | Framework acceptance includes finite passive health checks and exactly-one complete evidence; ordinary commands serialize under one lease while an idle owner retains the shared display. |

These are design dispositions. Source review and display-free fixtures cannot establish live reuse,
cancellation/restart/reboot safety, or the cause of an Apple subsystem stall.

## Acceptance and recovery

Framework acceptance is maintainer validation for changes to display identity, creation, reuse, or
command cleanup. It is not developer onboarding or an admission ticket for each Mac. Ordinary
developers adopt the framework through the existing test commands;
the runner initializes machine state and records the fixed identity automatically. It never writes
an acceptance receipt or silently repairs uncertain state.

For framework validation, inventory the worktrees and runner versions, update or pause old
entrypoints, and account for directly invoked legacy binaries. Finish display-free checks and
review the source and a finite validation plan before desktop work. Fix the worktree/commit/source
hashes, exact commands, deadlines, observation schedule, settling interval, health thresholds, and
abort criteria. Successive commands must reuse the same live display without creation or destruction.
A creation check belongs on a Mac where the display is already absent; never destroy an existing
display to manufacture that condition. A new-Mac baseline documents absence of Jarvis profiles and registrations;
a reuse baseline records the existing identity. Validation evidence belongs with the framework PR.

Use a finite baseline → command → settling and complete checks sequence. At baseline and after
each run, obtain complete profile and registration snapshots and inspect finite passive log/CPU/file
activity and desktop responsiveness. Prefer planned direct read-only registry copies parsed
offline. A single-device lookup, profile count, or current display ID cannot establish absence of
other registrations. No concurrent creation, stress loop, repeated registry enumeration, daemon
restart, or parked privileged-helper experiment belongs in this campaign.

Pass requires exactly one Jarvis ICC and registration with the same persistent UUID and
validated profile metadata, the shared live display still available, no surviving test apps or
helpers, unchanged physical-display configuration and unrelated records, and healthy passive
observations. macOS may replace an ICC file during display creation with an updated creation date. Accept that replacement only
when complete byte comparison or exact hash reconstruction proves that only the ICC creation-date
field changed; profile paths, counts, identity and all other bytes must match. Preserve the raw
hashes and file metadata in the evidence. The replacement must fall within the bounded display
operation and stop before the complete settling observation. Persistent profile requests
or rewrites, an unresponsive app, timeout, unexpected state growth, missing evidence, or any anomaly
stops validation immediately. Non-growth with legacy extras or missing complete registry evidence
is partial and cannot establish framework acceptance. Cancellation, process restart, and reboot
need separate evidence; two successful reuse runs are no lifetime guarantee. Developers do not
repeat these framework experiments to run the Gate.

Recovery is explicit inspection and reconciliation. Deleting the journal/marker/lock and retrying
does not prove safety, and recovery never destroys the test display. Preserve the unfinished receipt,
prove exact prior test clients and commands have exited, and validate the existing display before
recording a reconciled lifecycle. A healthy retained display is expected and does not require a
logout or restart. Reconciliation does not turn an unrun or failed test into a pass. Legacy extra
records/profiles require separate exact maintenance, with
backups and complete identity evidence. Any such maintenance snapshots online displays once,
builds its entire plan before applying changes, and preserves receipts for each successful action
and partial failure. Routine runners provide no profile or registration removal operation. Ordinary
runs need no administrator prompt, installed privileged helper, or separate test Mac. Validation-only
audit assistance does not become a runtime dependency. Registration-removal recovery implicates
accumulated Jarvis records; the precise Apple defect and responsibility of issue #468 remain unproven.
