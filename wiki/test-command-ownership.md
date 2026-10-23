# Test command ownership

Local test commands share one fixed virtual-display identity per physical Mac. Each command owns
its live display until its exact apps and helpers exit and display teardown succeeds. Its ICC
profile and ColorSync registration are deliberately retained for reuse. The acceptance target is
exactly one approved Jarvis profile and one registration with the same persistent identity.
The runner does not install, rename, delete, or unregister either resource.

This subsystem covers cooperating updated runners under one designated development account.
It serializes complete commands across worktrees, including builds and teardown. Private preference
suites and workspace-local evidence isolate test data; TCC grants, signing identities, OS caches,
and the retained display state remain shared. Physical screens and unrelated applications retain
their settings and processes.

## Identity and admission

[`descriptor.json`](../scripts/test-display/descriptor.json) pins the descriptor, including its name
`Jarvis Tests` and serial `0x4a560001`. The stable diagnostic label is **`jarvis-test-4a560001`**.
It adds no suffix or registration and does not rename an ICC file. macOS supplies the persistent UUID
and profile filename. The supervisor records the observed UUID and the reviewed profile identity
when known. The worker's constructed `expected_profile` pathname is an expectation, never evidence
that a profile exists or matches its metadata. An approved baseline and an existing journal must
agree before desktop work; unknown identity may be initialized from the reviewed baseline.

The selected serial belongs to the known legacy inventory. There is no alternate identity,
random/PID serial, pool, or fallback. Descriptor/protocol changes require explicit reconciliation.
An unexpectedly occupied identity stops the command. Stable descriptor inputs alone cannot promise
that macOS never creates extra state or hangs.

[`supervisor.py`](../scripts/test-display/supervisor.py) is an ordinary-user external supervisor.
It acquires a permanent file lock in the fixed `/Users/Shared/JarvisTestDisplay` namespace. The
parent must be root-owned and sticky; the atomically created lease directory is developer-owned
`0700`, with regular single-link `0600` state and lock files. Symlinks, wrong owners/modes, hard
links, missing existing state, and malformed state stop admission. Another account receives an
ownership error before desktop access. A waiter uses only lock operations, has a bounded deadline,
and can cancel without disturbing the owner. There is no FIFO or fairness promise.

Exclusive bootstrap creates the initial journal; bootstrap is not permission to start a live
campaign. Under the lock, the supervisor persists unfinished intent before OS-facing preflight.
The journal holds descriptor, persistent identity, boot and process birth identities, run token,
command/worktree, separate test and lifecycle status, and exact owned-process/pending-launch receipts.
An independently flushed unfinished marker precedes journal replacement. Completion requires
flushed journal replacement and marker removal; a failed write or directory flush leaves admission
blocked even if a visible journal already says `completed`. A dead PID, unlocked file, or reboot
does not prove completion. Normal execution never removes the lock or repairs unfinished state.

The process-only preflight compares kernel executable paths, not command arguments, against the
development app pathname. Inspection runs in a bounded isolated Python worker and makes no display
queries. A proven existing-app conflict before GUI work records `not-started` completion and refuses
without signalling that app; quitting it permits another attempt. Inspection errors remain uncertain.
Campaign consumption starts only after this clean conflict check.

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
Independent edits/builds are safe only when they cannot replace an active command's binaries,
bundle, or artifacts. Direct legacy binaries do not cooperate with this lock.

The external supervisor alone owns the lease and journal. It launches the admitted root shell in
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

Helper scope derives from its owning parent. The OS-bound
[`TestCommandOwnership`](../Sources/JarvisTestSupport/TestCommandOwnership.swift) launch wrapper
obtains a durable pending receipt **before** `Process.run()`, then registers the observed child.
Its dependency-free `JarvisTestSupport` target is shared by the app, native helper, provider/capture
adapters, and live test controller. The coaching kernel has no dependency on this process boundary.
The host helper fixtures use the same handshake through
[`test-command-ownership.py`](../scripts/lib/test-command-ownership.py). A parent dying between spawn
and registration leaves uncertainty, even if a result already exists. Pending app-scope launches
also prevent the next app phase. Control processes remain observed at final teardown without
waiting for themselves during app-phase RPCs.

Ownership reporters use the supervisor-selected absolute Python interpreter with `-I`. Restricted
helper environments receive only explicit ownership context; hostile PATH, PYTHONPATH, PYTHONHOME,
credential, and proxy test inputs retain their original meaning. Reporter/client processes do not
gain test-command admission by holding context.

## Blocking calls and terminal failure

The Swift worker contains AppKit and private display interfaces, adapted from the pinned
MIT-licensed [DeskPad implementation](../scripts/test-display/DeskPad/README.md). The Python owner
does not import AppKit or ColorSync. It records intent before compiling/starting the worker and
enforces monotonic deadlines from outside the process making synchronous OS calls. Worker, lease,
command, and exit budgets live in `supervisor.py`; changing a campaign's budgets requires source and
manifest review. There are no automatic create retries or alternate descriptors.

The worker takes one bounded online-display snapshot before creation and one after release. It
creates once, verifies original physical-screen layout/main screen and nonoverlap, and releases
once after owned clients exit. A successful teardown reply requires the original online set/layout
and worker exit. The profile and registration remain. Capture privacy explicitly selects the
admitted screen instead of assuming the main screen is isolated.

Timeout, unknown launch, worker crash, admitted-root signal death, inspection error, or persistence
failure leaves unfinished state. Lifecycle uncertainty is sticky: an ignored RPC error, late reply,
eventual child death, or zero test exit cannot clear it. Error cleanup can signal exact known clients
and stop the worker, but that is not verified teardown and does not reopen admission. An ordinary
assertion exit can complete verified teardown and admit the next command while preserving its test
status. Zero exit requires successful tests and lifecycle completion.

## CI and display-free checks

Hosted workflows explicitly invoke [`run-ci-tests.sh`](../scripts/run-ci-tests.sh). The hosted
runner account still takes the same lease and runs ownership checks, with no virtual display.
An inherited `GITHUB_ACTIONS` value or display ID cannot select that policy. Local hosted-mode
requests and nested supervisors are rejected. Hosted CI proves neither display reuse nor ColorSync
persistence and preserves the workflow's ordinary draft-PR behavior.

[`test-test-display.py`](../scripts/test-test-display.py) runs only copied-checkout, display-free
fixtures. Its fake backend cannot be enabled in the production supervisor by an environment flag.
The script/workflow and cancellation fixtures also use non-GUI stand-ins. Fixture environments
strip all inherited `JARVIS_TEST_*` context before adding deliberate inputs, including when Gate
itself runs them under a real supervisor. No fixture can contact the outer owner.

The accepted independent design reviews cover three sets of requirements:

| Review | Required dispositions |
| --- | --- |
| Ownership | Durable preflight intent; exclusive bootstrap and fail-closed writes; one validated command chain; separate test/lifecycle results. |
| Isolation | All six entrypoints; explicit CI policy; exact app/helper exit between phases; environment context never grants admission. |
| Validation | Finite passive health checks; exactly-one complete evidence; update/pause old runners; serialize whole commands without a daemon, queue, or concurrent GUI clients. |

These are design dispositions. Source review and display-free fixtures cannot establish live reuse,
cancellation/restart/reboot safety, or the cause of an Apple subsystem stall.

## Acceptance and recovery

Before any live rollout, inventory every worktree used for testing and its runner version. Update
or pause every old entrypoint and account for directly invoked legacy binaries. Finish the
display-free admission checks and review the concrete source and finite campaign manifest. The
machine's owner-only `approval.json` records that review and baseline reconciliation; it is never
generated from inherited environment or an automatic repair. See `approval()` in `supervisor.py`
for ticket fields. Baseline profile/registry references and pass receipts represent reviewed,
complete evidence; a pathname expectation or a partial snapshot cannot supply them.

The manifest fixes worktree/commit/source hashes, exact supported commands, per-stage call limits,
deadlines, passive observation schedule, settling interval, health thresholds, and abort criteria
before execution. It permits one A and one successive B in a second updated worktree, with one
create/release each. Each `(manifest hash, campaign stage)` ticket is durably consumed before GUI
preflight independently of the latest command; artifact or accepted runs cannot enable its reuse.
The supervisor offers no campaign runner, retry, or repair command.

The finite observation sequence is baseline → A → settling and complete post-A checks → B →
settling and complete post-B checks. B requires a reviewed A pass receipt. At baseline and after
each run, obtain complete profile and registration snapshots and inspect finite passive log/CPU/file
activity and desktop responsiveness. Prefer planned direct read-only registry copies parsed
offline. A single-device lookup, profile count, or current display ID cannot establish absence of
other registrations. No concurrent creation, stress loop, repeated registry enumeration, daemon
restart, or parked privileged-helper experiment belongs in this campaign.

Pass requires exactly one approved Jarvis ICC and registration with the same persistent UUID and
validated profile metadata, no surviving live display/owned processes, unchanged physical-display
configuration and unrelated records, and healthy passive observations. Persistent profile requests
or rewrites, an unresponsive app, timeout, unexpected state growth, missing evidence, or any anomaly
stops the campaign immediately. Non-growth with legacy extras is partial. Missing complete registry
evidence is partial. Neither result authorizes the updated Gate. Only the complete accepted A/B
campaign permits the updated wrappers and full Gate through normal admission. Cancellation,
process restart, and reboot need separate evidence; two successful reuse runs are no lifetime
guarantee.

Recovery is explicit inspection and reconciliation. Deleting the journal/marker/lock and retrying
does not prove safety. Legacy extra records/profiles require separate exact maintenance, with
backups and complete identity evidence. Any such maintenance snapshots online displays once,
builds its entire plan before applying changes, and preserves receipts for each successful action
and partial failure. Routine runners provide no profile or registration removal operation. Ordinary
runs need no administrator prompt, installed privileged helper, or separate test Mac. Validation-only
audit assistance does not become a runtime dependency. Registration-removal recovery implicates
accumulated Jarvis records; the precise Apple defect and responsibility of issue #468 remain unproven.
