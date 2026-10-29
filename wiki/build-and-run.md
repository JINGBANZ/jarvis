# Build, Run & the Activity Viewer

> How Jarvis is built, signed, tested, and run on macOS, plus the activity viewer. This is
> the operational *how*; the design *why* lives in [architecture.md](./architecture.md), the security
> posture in [sandbox.md](./sandbox.md). Anything here that's a plain value or wiring lives in code —
> this page captures the non-obvious mechanics and the decisions behind them.

## Toolchain

The Command Line Tools SDK (`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`) ships
ScreenCaptureKit, AVFoundation, AppKit, SwiftUI, Vision, CoreAudio, and Security — everything Jarvis
needs — so a SwiftUI + ScreenCaptureKit binary builds with plain `swift build`.

The Gate and the [live e2e tests](./live-e2e-tests.md) need only the Command Line Tools;
no Xcode project exists. CI uses the hosted runners' selected Xcode toolchains. Developer desktops
also have full Xcode and the Xcode MCP,
whose macOS workflow builds, launches, stops, and reads logs, so an agent may drive the app that way;
the scripts use `open`. The [live-test prerequisites](./live-e2e-tests.md#prerequisites-and-standing-conditions) depend on
the selected scenarios and coaching provider.

Pull-request CI covers multiple macOS environments because AppKit and toolchain behavior can differ
across them; see [`ci.yml`](../.github/workflows/ci.yml) for the matrix, required-check wiring, and
failure artifacts. Pixel assertions also need a consistent color space and scale because AppKit's
offscreen images inherit the display's color profile. The normalization and diagnostic evidence live
in [`coloredDashedArrowsRenderTheirStyle`](../Tests/JarvisOverlayTests/DiagramHintRenderingTests.swift).

- **Library/executable split (load-bearing for testability):** `JarvisCore` holds the pure,
  deterministic logic behind protocols (config, transcript, the coach loop, …) and is unit-tested
  with mocks on **any** machine — no Mac UI, key, or permissions needed.
  `JarvisOverlay` is a small library holding just the `NSPanel` overlay, split out so
  `JarvisOverlayTests` can import it to verify screen-capture invisibility headlessly.
  `JarvisScreenCapture` is the OS-bound `screencapture` process/file adapter behind Core's
  `ScreenCapturing` port, split out so `JarvisScreenCaptureTests` can drive its cancellation,
  cleanup-verification, and latch contract headlessly. `JarvisBrainProviders` is the
  Foundation-only concrete brain-provider library (the brain transport every target uses, its
  per-API wire formats, and the client factory,
  the bundled subscription helper's supervisor and sign-in, and the agent CLI detector and runner
  the session evaluator uses), composed by the app at Start. `JarvisEvaluation` is the
  Foundation-only sealed-session evaluation library shared by the app and `EvalPrep`.
  `JarvisApp` is the thin executable that wires the libraries to the side-effectful macOS
  frameworks (mic, ScreenCaptureKit, the realtime websocket, the menu bar). `JarvisReferenceHelper`
  is the native document parsing and SQLite process boundary, composed through Core's
  `DocumentSession` port. That split is what
  lets most of the system be verified headless. `JarvisLiveTests` is the test target of the
  [live e2e tests](./live-e2e-tests.md): it drives the signed app, and it is the only test target
  that reaches real providers.
- **Tests use swift-testing, not XCTest.** `import XCTest` fails with "no such module" under
  CLT-only. Run the suite via **`./scripts/run-tests.sh`**, which adds the swift-testing framework
  search/rpath flags that plain `swift test` lacks CLT-only and passes `--skip JarvisLiveTests`, so
  the Gate compiles the live target but never runs it. Both commands use
  `scripts/lib/swift-test-flags.sh` to apply the toolchain flags and require a completed, nonempty
  passing swift-testing summary. An empty filter exits 0, and stopping the main run loop (such as
  `NSButton.performClick`) can end the runner early with success, so exit status alone is insufficient.
  (One sharp edge: a direct
  `@MainActor async @Test` miscompiles on the CLT swift-testing — async UI tests use a `nonisolated`
  `@Test` that `await`s a `@MainActor` helper; see `OverlayInvisibilityTests`.)
- **Stub executables are slow to start the first time.** On a desktop Mac, macOS checks each newly
  written executable (it carries `com.apple.provenance`) on its first launch, one at a time, at
  about 0.5 s each, so a burst of stubs queues for seconds. A test that launches a stub it just
  wrote uses its deadline as a hang guard, never as a speed check. A stub that waits must also end
  once `$PPID`, the test process, is gone, so a run that dies mid-test leaves nothing running; see
  `proxyStubExecutable`.

## Packaging & signing — why permission grants persist

`scripts/build-app.sh` assembles the executable into a hand-built `Jarvis Dev.app`. The production
identity remains the source in `Resources/Info.plist`; the development script edits only the assembled
copy, rewriting its name and bundle id, dropping its update feed, and stamping it as a development
build so the menu's footer caption reads a red `Dev` rather than the release version the plist carries.
Both bundle commands use [`assemble_app`](../scripts/lib/app-bundle.sh) for resources, frameworks,
and helper placement. Development identity creation and release signing/notarization stay in their
respective commands so a headless release build cannot enter the development keychain setup.

Both `build-app.sh` and `package-app.sh` build the subscription helper,
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), from the same pinned upstream source and
[`local-only.patch`](../scripts/cliproxyapi/local-only.patch). The patch omits unused public-IP/SSH
instructions and the Antigravity and Grok version updaters; configuration switches do not disable
those upstream paths. The version, source checksum, and Go toolchain checksum live in
[`scripts/lib/cliproxyapi.sh`](../scripts/lib/cliproxyapi.sh). The script downloads the pinned Go
compiler automatically, so a global Go installation is unnecessary. First-time app builds need
network access for the source, toolchain, and checksum-verified Go modules. The offline Swift Gate
does not build the helper.

Build inputs and outputs live under `.build/cliproxyapi/`; the source and toolchain archives are
checksum-verified before use, and cached binaries are keyed by the build recipe and patch and checked
against their recorded digest. A checksum mismatch, rejected patch, or compiler failure stops the
build. There is no upstream-binary fallback. Both bundle scripts install the result at
`Contents/MacOS/cliproxyapi` and the upstream MIT license under `Contents/Resources/Licenses/`.
Bumping the helper requires reviewing the patch and passing `./scripts/test-proxy-privacy.sh`, which
runs the real binary with empty credentials behind a recording loopback HTTP proxy. It checks
startup and Codex/Claude no-browser OAuth initiation, without opening a browser or authenticating.
CI and the release workflow run this check. Provider inference and token refresh still need the
appropriate [live e2e validation](./live-e2e-tests.md).

### References helper packaging and integration checks

Both bundle scripts copy the SwiftPM `JarvisReferenceHelper` executable through
[`scripts/lib/reference-helper.sh`](../scripts/lib/reference-helper.sh) and sign it before the outer
app. It links system SQLite FTS5 and PDFKit; DOCX uses the exact pinned ZIPFoundation dependency
with Foundation XML parsing. ZIPFoundation's privacy resource is copied beside the app's other
resources, and its license is in `THIRD_PARTY_NOTICES.md`. No interpreter, model, dictionary,
package installation, or runtime download is needed on the user's machine. The dedicated target is
the process boundary; shared domain values and admission policy remain Foundation-only in Core.

Production coaching uses `ReferenceRuntime` to connect Settings and filesystem changes to
`ReferenceLibrary`, the helper-backed `DocumentSession`, and the app's Start/Stop/Quit ownership.
The immutable context and admission behavior are defined in
[architecture.md → References](./architecture.md#references); Settings source controls are in
[settings-window.md → Tools](./settings-window.md#tools).

The explicit development harness, `./scripts/run-reference-tests.sh`, launches the signed app
through Launch Services on the shared temporary test display and exercises the production library,
adapter, and reference tool handlers. Synthetic TXT, Markdown, PDF, and DOCX fixtures cover document
access and admission; debug-only process faults cover transport and teardown. Results are owner-only
files in the checkout's `.jarvis/reference-harness/` directory. It contacts no provider and needs no
capture grants. The ordinary `./scripts/run-tests.sh` also runs Core contracts and native helper
process/resource checks; host Python drives those checks and is absent from the installed app.
[`run-tests.py`](../scripts/reference-helper/run-tests.py) discovers the helper contract suites with
an explicit executable, and [`support.py`](../scripts/reference-helper/support.py) owns their shared
framed client and fixtures. Importing a test suite does not consume command-line arguments.
Without an argument, the signed harness runs its complete suite, including REF01–REF07. A selector
runs one References integration case plus app/helper Quit validation; `--quit-only` focuses on Quit.
The case predicates live in
[`ReferenceHarnessAppDelegate+PhaseFour.swift`](../Sources/JarvisApp/References/ReferenceHarnessAppDelegate+PhaseFour.swift).
These deterministic checks cover admission, frozen access across Settings changes, watcher events,
source deletion, independent read/search readiness, compaction, and cancellation.
The separate spoken [H, P, and CACHE scenarios](./live-e2e-tests.md#scenarios) exercise real provider
requests rather than substituting deterministic helper evidence for model behavior.

The helper accepts the extensions declared in `ReferenceSourceCapture.supportedFormats`. Unsupported
files inside a directory, escaping or broken links, and non-regular entries are excluded from its
catalog. A directly selected unsupported file fails that metadata generation with
`unsupported_format`; a missing or inaccessible selected root or enumeration failure also fails the
generation. Discovery limits in `ReferenceDiscovery` bound both the number of selected sources and
the total entries visited across overlapping roots, including unsupported entries; exceeding them
reports a resource failure instead of silently truncating membership. Settings exposes selected-source
feedback on the [Tools page](./settings-window.md#tools).

`ReferenceLibrary` owns configuration generations and each pending or accepted session. The caller
explicitly accepts ownership only after its larger Start succeeds; abandoned admissions and uncertain
release acknowledgments are reconciled against the library's owned session set after helper
reconnection. `ReferenceSourceWatcher` filters selected files and supported changes within selected
directories, excludes the helper cache, and requests a full reconciliation after dropped events.
Explicit Start also reconciles independently of watcher delivery.

The supervisor coalesces startup and bounds hello, requests, cancellation, and shutdown. Search
transport allows headroom after the helper's search budget so partial results can return. The library
permits bounded helper recovery without replaying uncertain content calls; committed pins survive a
helper restart for the same app instance. A fresh instance closes orphaned sessions after obtaining
exclusive store ownership. The helper and reader workers receive a minimal environment without
provider credentials, proxy variables, or loader overrides. This is process and environment hygiene;
it is not OS-enforced filesystem or network confinement.

The private SQLite store separates persistent document identity, complete metadata generations,
immutable extracted revisions, and session membership/pins. Metadata discovery does not parse text.
Catalog serialization is bounded while paginated listing retains every admitted member. Text is
published in bounded transactions independently of search readiness. Source capture hashes the exact
authorized snapshot passed to a reader, checks source changes, and reuses a validated revision when
its hash, captured format and processor version match. Passage parsing uses that captured format,
independent of frozen catalog metadata, so a same-byte TXT/Markdown rename has a distinct revision
while existing pins keep their original interpretation. A successful first read, including an empty document or valid
end-of-document page, commits a durable pin; invalid reads do not. The first emitted search evidence
also pins its revision. Search validates candidates before one transaction commits every finalized
result pin; any conflicting pin or index generation rolls back that entire transaction before
reranking. Discarded candidates never acquire pins. Later pages use the pinned text after an edit,
deletion, or helper restart. Unpinned access revalidates the source
and cannot fall back to stale cached contents. Read pages use Unicode-scalar offsets; the protocol
and result types are in `Sources/JarvisCore/References/`.

Reliable renames preserve the opaque document ID. An observed deletion and later re-addition creates
a new ID. Without filesystem event history, a replacement at the same path between scans is treated
as an update, whether caused by an editor's atomic save or an unobserved delete/recreate. Pinned
sessions keep their original text; unpinned sessions use current content. Ambiguous cross-path
identity matches never merge documents.

TXT and Markdown decode directly on a bounded background lane. PDFKit and DOCX conversion run in
killable workers with bounded concurrency, source/expanded-output sizes, wall time, and sampled RSS;
the limits and processor version live in `ReferenceConversionPool`, `ReferenceSourceCapture`, and
`ReferenceTextOutput`. DOCX preserves text traversal through paragraphs and interleaved tables; it
does not reproduce Word layout. Image-only PDFs need OCR, which this reader does not implement.
RSS sampling can overshoot its threshold and is not a hard OS memory limit. Workers exit when their
owning helper disappears. Private staging is reclaimed after use or exclusive-owner restart.
Disk accounting includes SQLite/WAL and staging. `ReferenceStorageBudget` serializes conversion
reservations with each bounded index write so indexing cannot spend reserved capacity. Cleanup
preserves active pins and reports capacity failure rather than deleting them. Logical deletion and
checkpointing do not promise secure erasure.
Completed conversion removes its staging snapshot and releases its reservation before indexing;
other active conversions keep their reservations.

Ranked retrieval uses complete, versioned passages from the authoritative text. The range-producing
`ReferenceChunker.passages` preserves original Unicode-scalar offsets, CRLF, Markdown sections,
code fences and table rows, omits heading-only Markdown ranges, and bounds passage allocation.
`ReferenceSearchTokenizer` emits
canonical Unicode case-folded word terms, CJK scalar/bigram terms, and punctuation-bearing identifiers.
It encodes those terms for SQLite's ASCII tokenizer, so punctuation is never interpreted as FTS
syntax and tokenization does not depend on the installed OS's language dictionaries. Ordinary topic
terms use BM25 disjunction; explicit identifiers require their exact encoded terms, distinguishing
`C++`, `C#`, `账单-42`, and `账单_42`. Topic words outside identifier spans influence BM25 ranking
without relaxing required identifiers; excerpts keep their identifier anchors. Indexing and queries
normalize trailing sentence delimiters consistently. `ReferenceSearchNameScope` recognizes complete
frozen filenames longest-first within the requested document subset, with the same canonical Unicode
case folding. Duplicate-name qualifiers select their frozen document IDs. Remaining topic terms rank
passages within that scope; a named document without topic matches supplies its first passage.
Exact-name evidence includes empty readable revisions and uses the same durable pin contract.
This is lexical retrieval; semantically similar paraphrases without shared terms are not guaranteed.
BM25 corpus statistics can change while pinned document text stays immutable.

`ReferenceSearchCandidate` joins frozen session membership and the selected pinned/current revision
before ordering or limiting hits. Optional document filters use a bound JSON relation; an empty
filter stays empty. Ranking and typed readiness coverage share one SQLite read snapshot. If the first
query exhausts its budget, coverage retains the frozen filtered membership count and metadata
generation, with deadline omissions instead of an empty scope. Evidence-page scanning and hashing
check the same absolute search deadline; expiry returns partial coverage without first-use pins.
These checks do not impose a hard timeout on synchronous source filesystem metadata calls; a slow
volume can outlast the helper's retrieval budget. Start metadata admission has its separate deadline
described in [architecture.md](./architecture.md#references).
Ordinary reads keep their separate read contract. Results
carry display names, sections, original offsets and bounded original text; readiness omissions are
separate from top-three truncation. Only candidate sources are checked before first-use pinning,
including a final check after all evidence pages load, without hashing the whole corpus on each query.
Unreadable or known-changed candidates are excluded and remaining eligible evidence is reranked,
without pinning discarded evidence. A concurrent successful read's matching immutable pin remains
valid if source validation fails; page-integrity failures still reject the evidence.

A separate indexing lane prepares tokens outside transactions, commits each passage with its FTS
posting, and publishes readiness only for a complete matching generation. Unpublished batches stay
ineligible. Authoritative reads and metadata admission remain available while indexing is held.
Index configuration and interrupted-generation recovery affect only derived data. Startup verifies
posting/passages counts and FTS integrity; rebuilding preserves text, IDs and durable pins. Cleanup
rechecks retention in the same transaction as deletion. Failed unpublished postings are reclaimable
while preparing generations and authoritative pinned text remain retained; failure coverage stays explicit.
Limits and publication details live in
`ReferenceSearchIndex` and `ReferenceDocumentStore+Index`.

Core and helper contracts cover retrieval, publication, and races, including a seeded 10,000-member
cache with full-length revision keys and retained historical revisions. The signed app harness also
prepares actual TXT files and measures complete `DocumentSession.search` calls through the Swift
adapter and process transport. These synthetic checks contact no provider. Provider context and
cache validation use the [live e2e scenarios](./live-e2e-tests.md). Reconnection restores committed
text and index generations. Never-converted
files count as incomplete search coverage until a read or configuration preparation converts them.
Search reports that incomplete coverage without retrying conversion. Retained text without captured
parser metadata remains readable and pinned, with unavailable search coverage rather than a guessed parser.

**Permission persistence is a signing problem.** macOS TCC keys Screen-Recording, Microphone, and
System Audio Recording grants to **code signature + bundle id + bundle path**. An ad-hoc signature
changes every build, so macOS
forgets the grant and re-prompts on each rebuild. So `build-app.sh` always signs with a **stable
self-signed identity (`Jarvis Dev`**, created automatically on first build) — there is **no ad-hoc
fallback**. It produces `Jarvis Dev.app` with bundle id `com.jarvis.coach.dev`; the downloaded
`Jarvis.app` keeps `com.jarvis.coach` and its Developer ID signature. These intentionally incompatible
identities give each variant its own TCC grants, Launch Services registration, and bundle-id-backed
preferences, so both can be installed and run on one Mac without one variant impersonating the
other. With the development identity, bundle id, and checkout path fixed, its grants persist across
rebuilds and relaunches. On the first build macOS prompts once to let `codesign` use the new key —
click **"Always Allow"** — and the first launch requests the development app's own capture grants.

The identity split is not a second data sandbox. Both variants intentionally share the established
owner-only API-key storage; session histories are separated by the
[session-folder rule](#the-live-activity-viewer). If a checkout still contains a generated `Jarvis.app` from before the split, move only
that checkout-local bundle to the Trash so it cannot be launched accidentally; leave
`/Applications/Jarvis.app` in place.

- Recover a stale *denied* state (which macOS won't re-prompt for) with
  `tccutil reset Microphone com.jarvis.coach.dev` (or `ScreenCapture`) plus
  `defaults delete com.jarvis.coach.dev onboarding.completed`, because onboarding asks only while it
  hasn't completed; then relaunch `Jarvis Dev` and Allow. Use `com.jarvis.coach` only when
  intentionally resetting the production release.
- All three grants come from **TCC prompts during first-run onboarding**, not an App-Sandbox
  entitlement file. `OnboardingGate` asks for an API key when none is saved, then walks Microphone,
  System Audio Recording, and Screen Recording one dialog at a time, and keeps Jarvis closed until it
  has all of them. Onboarding runs once per install; to see it again,
  `defaults delete com.jarvis.coach.dev onboarding.completed`. To see the permissions step, also
  `tccutil reset AudioCapture com.jarvis.coach.dev` (or `Microphone` / `ScreenCapture`). To see the
  key step, also move `~/Library/Application Support/Jarvis/openai-api-key` and `gemini-api-key`
  aside (both builds share them) and unset `OPENAI_API_KEY` / `GEMINI_API_KEY`; put the files back
  afterwards. For a true first run, also
  `defaults delete com.jarvis.coach.dev permissions.screenRecordingAsked`, the one marker that
  records that Jarvis asked, not that it was granted. See
  [architecture.md → Onboarding](./architecture.md#onboarding).

## Distribution — signed, notarized releases from CI

The `Jarvis Dev` identity above is a **local-dev** device: on any other Mac it's untrusted and
Gatekeeper blocks the app. Distributable builds go through `scripts/package-app.sh`, which builds and
signs the bundle once with a **Developer ID Application** certificate — hardened runtime + secure
timestamp (both notarization requirements) — with the `audio-input` entitlement that hardened runtime
requires for microphone capture. Nested code is sealed inner to outer, Sparkle's pieces and then the
subscription helper and native References helper under the same hardened runtime and timestamp before the app, because
notarization rejects any executable in the bundle that lacks them. It submits a temporary zip of that app to Apple's notary service,
staples and validates the app's ticket, then uses the hash-pinned release-only `dmgbuild` tool to
place the stapled app beside an `Applications` shortcut in `Jarvis.dmg`. The mounted Finder window is
a fixed icon view: Jarvis on the left, Applications on the right, and a large arrow between them,
with the window chrome hidden. `dmgbuild` writes that layout metadata directly rather than automating
Finder, so the hosted runner does not need a GUI session. It deliberately leaves the signed app free
of FinderInfo extended attributes, which strict code-signature verification rejects. The script signs
and notarizes the outer disk image separately, then staples the container's ticket to the exact file
users download. Both layers therefore remain verifiable offline. The install stays an explicit drag:
Jarvis never relocates itself to `/Applications` on first launch (a downloaded app can be running
translocated and read-only, and an app should not move itself), and there is no installer package,
because a single bundle needs no elevated install semantics.

The script passes that final DMG to `scripts/verify-release.sh`, which verifies the disk image and its
ticket, mounts it read-only, and requires exactly the two visible install targets plus the hidden
Finder metadata and arrow background. `scripts/verify-dmg-layout.py` reads the final `.DS_Store` and
checks the icon view, window size, chrome, icon size and positions, background link and digest, and
Applications target position. Release verification also checks the Applications target, mounted app
version, arm64 architecture, the arm64 subscription helper and its license, native References helper with debug fault mode excluded, linked macOS 26-or-newer
SDK, notices, strict code signature, and
Gatekeeper policy result before detaching the image. The same SDK guard runs immediately after the
release build, before signing or notarization; the pre-container app is not accepted as a proxy for
the downloaded artifact.

Releases are cut by `.github/workflows/release.yml`, not by hand: on every push to `main`,
**release-please** maintains a standing Release PR from the conventional-commit history (bumping both
version keys in `Resources/Info.plist` via `x-release-please-version` annotations, plus the
CHANGELOG — config in `release-please-config.json`). Merging that PR is the manual release approval:
it creates the GitHub Release **as a draft**, with no second deployment approval. `force-tag-creation`
tags that draft immediately: GitHub otherwise defers tagging a draft until publish, and an untagged
draft makes the next release-please run miss the previous release and garble the changelog. An Apple-silicon
`macos-26` job then runs the test gate, installs only the hash-pinned pure-Python wheels in
`scripts/requirements-release.txt` into an ephemeral environment, and signs/notarizes with secrets
scoped to the main-only `release` environment (the base64 `.p12` certificate and an App Store Connect
API key — names in the workflow). It attaches `Jarvis.dmg` and the `appcast.xml` update feed described
below, rejects any other asset, then publishes the Release. The
stable installation block in
`.github/release-header.md` links directly to that tag's DMG and explains the in-window drag to
Applications; GitHub still supplies its automatic source archives. A failed sign, notarization, or
final-image verification therefore never leaves a public Release without a validated app. The exact
runner label and binary guard keep downloaded
AppKit controls on the same macOS 26 design as local development builds instead of inheriting the
compatibility appearance of an older linked SDK. The publish job lives in the same workflow because
tags created with `GITHUB_TOKEN` never trigger other workflows.

`package-app.sh` also runs locally for packaging without CI. Create a virtual environment, install
`scripts/requirements-release.txt` with `--require-hashes`, and pass its interpreter through
`DMGBUILD_PYTHON`; notarization also needs the one-time
`xcrun notarytool store-credentials jarvis-notary …` setup. Distributed builds require macOS 14.2 or
later and run on Apple silicon only because `libjarvis-aec.a` is arm64-only. The README owns the user
installation steps; provider credentials remain user-supplied in Settings.

## In-app updates — Sparkle over the release feed

The menu bar's **Check for Updates** item runs [Sparkle](https://sparkle-project.org) against the
`appcast.xml` asset published beside each release, so an installed Jarvis can replace itself with the
newest signed disk image instead of the user re-downloading by hand. `SUFeedURL` points at
`/releases/latest/download/appcast.xml`, which GitHub resolves to the newest published Release;
`scripts/generate-appcast.sh` renders the feed after packaging, pinning the enclosure to the release's
own tag so a signed item keeps naming the exact bytes it covers once "latest" moves on. Sparkle rather
than a hand-written downloader over the Releases API: the parts a custom updater would reimplement,
signature verification and replacing the running bundle, are exactly the ones most costly to get
subtly wrong.

Sparkle resolves under Command Line Tools alone: it is a remote binary target carrying a prebuilt
XCFramework, so no `.xcodeproj` is needed to consume it. SwiftPM leaves `Sparkle.framework` beside the
executable and both bundle scripts embed it at `Contents/Frameworks`, which is what the `JarvisApp`
target's rpath names. Sparkle's XPC services exist only to install updates from inside an App Sandbox;
Jarvis is not sandboxed (see [sandbox.md](./sandbox.md)), so they are deleted at embed time rather
than notarized as unreachable code. The framework and bundled helpers contain nested code, so
`package-app.sh` seals it inside-out — the update helpers, the framework, then the app — and release
verification requires every nested signature to hold in the mounted artifact.

Two independent signatures gate an install: the EdDSA signature the feed records over the disk image,
checked against `SUPublicEDKey`, and the Developer ID signature, which Sparkle requires to match the
running app. That second check is also why TCC grants survive an update — macOS keys them to a code
signature that does not change between releases. The EdDSA private key is held as the
`SPARKLE_ED_PRIVATE_KEY` secret in the same `release` environment as the signing and notarization
credentials, and `generate-appcast.sh` reads it on standard input so it never reaches a process list.
Losing it would strand every installed copy on its current version. Before signing, the script derives
the key's public half and requires it to equal `SUPublicEDKey`: signing and verifying with one private
key proves only that the key is well-formed, so without this a rotated or mistyped secret would
publish a feed that every installed copy silently rejects until the next release.

Checks are user-initiated only. `SUEnableAutomaticChecks` is false, which stops both scheduled
background checks and Sparkle's first-launch prompt offering to enable them — either would present UI
on an autonomous path. The item is also disabled while a session is live, because an update dialog is
not one of the presentation paths the [runtime safety boundary](../AGENTS.md) permits during the live
pipeline, and installing quits and relaunches the app. Development bundles have no updater at all:
`build-app.sh` strips `SUFeedURL`, `UpdateController` fails to initialize without it, and the menu
omits the item rather than offering an action that a self-signed build could never complete.

## Running

| Command | What it does |
|---|---|
| `./scripts/run-tests.sh` | Build + run the unit/offline-pipeline tests (no key, no permissions). |
| `./scripts/build-app.sh [release\|debug]` | Build, bundle, sign `Jarvis Dev.app` (default `release`). Creates the `Jarvis Dev` signing identity on first run. |
| `./scripts/build-app.sh --run` | Same development build, then launch it. Per-session logs land in the workspace `.jarvis/` (see below). |
| `./scripts/run-capture-privacy-tests.sh [hold-seconds]` | Check real signed-app windows in a continuous stream; see [capture validation](./overlay-invisibility.md#validation-layers). |
| `./scripts/test-proxy-privacy.sh` | Build the bundled helper and check unrelated startup/sign-in HTTP requests with empty accounts. |
| `./scripts/run-reference-tests.sh [REF01\|REF02\|REF03\|REF04\|REF05\|REF06\|REF07\|--quit-only]` | Build the debug app and run signed deterministic References integration checks; no provider calls or capture grants. |
| `./scripts/run-live-tests.sh [scenario] [--evaluate] [--keep-going]` | Build the debug app and run spoken scenarios against real providers; explicit REF selectors delegate to the deterministic References harness ([live-e2e-tests.md](./live-e2e-tests.md)). |

- **Always launch with `open "./Jarvis Dev.app"`**, never the bare binary — running it from a shell makes
  TCC attribute the grant to the *terminal*, so the app reports Microphone, System Audio Recording,
  or Screen Recording as "denied" even when granted. Pass flags with
  `open "./Jarvis Dev.app" --args …`.
- Production and development can stay open together, but the fixed global ⌥⌘J shortcut can belong
  to only one running process. The second app logs that the shortcut is unavailable; use its menu-bar
  controls directly or quit the other variant when testing the shortcut.
- Jarvis does **not** auto-start: choose transcription and Primary brain providers in Settings, meet
  their credential or local sign-in requirements, then **Start / Stop** from the menu. API keys are
  saved to owner-only files; `OPENAI_API_KEY` and `GEMINI_API_KEY` are headless fallbacks. The menu icon and readiness states follow
  [the MenuBar component contract](./architecture.md#3-components).

The signed harnesses share [`scripts/lib/harness.sh`](../scripts/lib/harness.sh) for fresh owner-only
run directories under the checkout's `.jarvis/` tree and bounded waits for result files. Each harness
owns its launch arguments, completion checks, timeouts, and app teardown. The transcription benchmark
requests abort and waits for its detached app on hangup, interrupt, and termination.

The Gate also runs [`scripts/test-script-workflows.py`](../scripts/test-script-workflows.py). Synthetic
executables exercise bundle assembly, independent development identity, empty-run rejection,
cancellation, private directories, source-scan failures, and AEC setup failures without using signing
keys, capture grants, or providers. Source guards share [`guard_scan`](../scripts/lib/guard.sh), which
allows an empty match set but rejects scan errors.

### Automatic test display

The local test commands share one fixed descriptor named `Jarvis Tests`, with the diagnostic label
`jarvis-test-4a560001`. One ordinary-user external supervisor owns the complete command across
worktrees. It reuses the live display or creates it when absent within the
[per-boot creation bound](./test-command-ownership.md#identity-and-admission), observes exact app/helper exit, and
verifies that the admitted display layout remains intact. The live display, ICC profile, and ColorSync
registration stay available between commands. Test cleanup never destroys the display.

[Test command ownership](./test-command-ownership.md) defines the machine-visible lease, durable
unfinished state, process roles, six entrypoints, explicit hosted CI policy, and failure behavior.
The runner initializes machine state on first use and records the fixed display identity for reuse.
Developers need no approval file or A/B campaign; [developer setup](../CONTRIBUTING.md#developer-setup)
leads directly to the local Gate. The ownership page also defines maintainer acceptance checks for
changes to the display framework. Display-free fixtures do not call the native worker; hosted CI
does not establish local persistence.

Normal admitted commands require no display app, physical monitor, privileged helper, or administrator prompt.
Virtual displays use private macOS interfaces confined to the display worker and require a
responsive logged-in macOS GUI session. Creation starts an idle background owner to retain the native
display object; it has no polling loop or login installation. Commands that reuse the display use a
short-lived validation worker. On headless Macs the test display serves as the main screen;
physical-display layouts remain protected when present. Failure stops the run and
leaves uncertain state blocked for explicit
recovery. The contract preserves physical-display configuration and unrelated applications, without
promising that macOS can never create extra state or stall.

## The live activity viewer

Settings → **Activity** opens an **in-app `WKWebView`** into which `ActivityLog` pushes the typed,
human-facing coaching exchange: finalized interviewer/user speech, manual hint requests, and every
brain action — a successful or failed `capture_screen`, a displayed `speak` tip, or a deliberate
`stay_silent`. It also shows one reason whenever a live session ends — including user Stop, app quit,
replacement by a new Start, and terminal runtime failures — plus notices for failures that degrade
coaching, a settings preflight that was not applied, and a failed live brain switch falling back to
the previous provider. A failure notice keeps a fixed frame and quotes what the provider actually
said inside it: its status or close code, its error code, and its message after redaction, so a
screenshot of Activity is enough to diagnose a cause nobody has classified yet (see
[architecture.md → Failure surfacing](./architecture.md#failure-surfacing--startup-loud-runtime-ghost)).
Lifecycle sequencing, retries, and timing remain in `jarvis-debug.log`. Successful
screen-view events carry their thumbnails as in-memory `data:` URIs. Chosen over a local HTTP server +
SSE: for an app that already holds the entries in memory, pushing into an embedded WebView is less
code, has zero network surface, and is the most testable (the production runtime *is* the test
runtime). It also sidesteps the `file://` `fetch()` restriction that forced the original viewer's
`<meta refresh>` reload.

- New events stream in live (no reload, no flicker); thumbnails open in an in-page lightbox. Rows use
  event occurrence time, with stable insertion order only for ties, so a slower earlier transcript
  final is inserted before a faster later reply.
- Each Start opens a fresh session (a Stop→Start gets a new log, never resuming the previous run),
  persisted as owner-only `jarvis-activity.jsonl` + `shot-N.jpg`; the same directory contains
  `coaching-attempts.jsonl` for evaluator-only trigger/delta/outcome provenance and
  `brain-traffic.jsonl` for redacted wire evidence. Past runs can be browsed and the history cleared
  from the viewer. Retention runs asynchronously after Start and protects current and still-closing sessions;
  `SessionArtifacts` owns the retained count.
- [`SessionDirectoryID`](../Sources/JarvisCore/Diagnostics/SessionDirectoryID.swift) puts the release
  version or development identity in the session directory name, beside its timestamp and random
  suffix. Start only constructs that name in memory and creates its usual session directory; there
  is no separate version-file write or version-dependent failure gate. Timestamp-only historical
  sessions remain readable with unknown version identity. Activity, retention, and the terminal
  evaluator order by the timestamp portion, so a version prefix cannot reorder history.
- **Session evidence is always enabled.** On every Start, producers submit Activity and diagnostics
  through the [shared evidence worker](./session-audit.md), which owns persistence and Console
  emission. `ActivityLog` is the in-memory projection, and `jlog` is diagnostic admission. Files
  use the base selected by
  [`SessionStore.baseDirectory`](../Sources/JarvisCore/Diagnostics/SessionStore.swift): development
  history belongs to the checkout containing the running bundle, while releases use per-user app
  storage. The bundle location gives each worktree its own history and evaluation source, independent
  of the working directory or whether launch comes from the build script, Finder, Dock, or `open`.
  Existing histories stay where they are; there is no automatic migration or cross-variant browsing.
  Folder selection only constructs a URL; Start creates and protects its usual session directory.
  The full privacy posture is in [sandbox.md](./sandbox.md).
- Activity JSONL stays append-only for durable writes, but each new row carries numeric occurrence,
  insertion, and record times. Live and reopened views apply the shared Core chronology rule rather
  than treating file append order as speech order. Historical files without complete chronology
  metadata keep their original file order; second-resolution display strings are not precise enough
  to reconstruct it safely. The in-memory/live-page backstop remains 10,000 rows: Core reports the
  exact discarded insertion identities and the page removes those DOM rows before applying the next
  Core-computed insertion index.
- The viewer's rendering logic (`htmlShell`/`rowScript`) and history reader (`SessionStore`) live in
  `JarvisCore` so they're unit/WebKit-tested; `ActivityViewer` in `JarvisApp` is the thin window.
- Session evaluation is agentic only. After Stop, select a session, click **Evaluate**, and pick an
  agent from the menu it opens. The menu lists each installed agent CLI, Codex then Claude Code, with
  a signed-out one shown but disabled so the user sees why it can't run; with none installed, a dialog
  says to install one. The chosen CLI is never swapped for another, and nothing remembers the choice.
  The read-only agent receives the source checkout plus the complete session
  directory, reads the full `jarvis-activity.jsonl` itself, and correlates first-class attempt
  provenance with raw brain traffic and screenshots. Its compact input opens with a neutral evidence
  index—artifact health, categorical distributions, and correlation-field coverage—followed by
  normalized provider-call telemetry. These tables describe recorded facts without declaring a
  defect; missing or partial values stay unavailable instead of becoming zero. The prompt carries no
  checklist of past incidents: one grows without bound and biases the auditor toward known failures
  while still missing the next shape. Growing request
  history is common-prefix elided with an explicit pointer back to untouched traffic. The agent uses
  read-only file and source-search tools to follow the evidence, then writes a generic Summary /
  Findings / Evidence gaps / Recommendations report to owner-only `eval-report.md`. A saved session
  shows **Open report** instead, avoiding another agent run. Development builds use the live checkout
  containing `Jarvis Dev.app`, including when opened directly. The development bundle is expected to
  remain in its checkout; resolving it does not probe for or discover a relocated checkout. Release
  builds read the selected session's version from its directory name and ask
  [`ReleaseSourceStore`](../Sources/JarvisEvaluation/ReleaseSourceStore.swift) for that public tagged
  source, downloaded fresh for that one evaluation and discarded when the run ends. Nothing is cached
  between runs: the agent CLI needs the network anyway, so a cache could never rescue an offline
  evaluation. The store falls back to the running release only when the session records no version or
  its tag no longer exists. A download failure is reported against the recorded version instead of
  being retried against another one, which would fail the same way while naming a version the user
  never selected. It never searches through historical tags, and cancellation never triggers fallback.
  If no source can be obtained, evaluation reports a source-availability failure. The button shows
  **Fetching source…**, then **Evaluating…**. Source is
  required because without the prompt files a coding agent cannot distinguish a bad hint caused by
  the model from one caused by the harness. The evaluator prompt identifies release source as the
  session's exact code only when the versions match, and warns that a development checkout may have
  drifted, including uncommitted edits. Fallback prompts identify both the recorded version (or its
  absence) and the actual source used, and require source-based findings to acknowledge the mismatch.
  The saved report also carries this provenance directly, independently of the agent's output.
  Codex accepts the release workspace without requiring `.git`. Unrecoverable source failures give
  next steps in the dialog; raw download errors stay in debug logs. A failed agent CLI run shows the
  CLI's own last error line, redacted, with its exit status, because a screenshot of that dialog is
  often the only evidence a user sends. Cancellation reaches both the download and
  subprocess, and failures preserve any saved report. Quit remains immediate: a run abandoned
  mid-download leaves only a per-user temporary directory the OS reclaims, so there is no staging,
  publication, or retention bookkeeping. Activity admits one evaluation at a time; the terminal
  evaluator uses a local checkout. Each evaluation owns its own source tree, so concurrent runs
  cannot disturb one another.
  See [sandbox.md](./sandbox.md) for source storage and permissions. `./scripts/eval-session.sh
  [session-dir]` is the terminal launcher for the same `JarvisEvaluation` evaluator.

## System-audio transcription benchmark

The benchmark is an explicit hidden mode of the signed app. Standard mode runs fixed synthetic audio
through every selectable transcription path; reconnect mode interrupts only Jarvis's active
transcription WebSocket and exercises the real buffer/replay path. Neither mode opens the microphone,
changes host networking, or runs in the normal build/test gate.

See [transcription-benchmark.md](./transcription-benchmark.md) for commands, architecture, scoring,
acceptance, privacy, result interpretation, and when each mode should be run.

## Browser screen-text validation

Focused tests in `JarvisScreenCaptureTests` cover dual Accessibility/OCR routing, secure-subtree
exclusion, bounded Unicode-safe extraction, repeated lines, inline text blocks, editor priority, and
selection among same-sized Chrome windows and multiple web areas. Fixture trees do not validate real
Chrome behavior, Vision OCR fidelity, or macOS permission transitions.

The capture behavior and source limitations are canonical in
[`settings-window.md#capture-scope`](./settings-window.md#capture-scope). Local artifacts and
provider-retention boundaries are canonical in [`sandbox.md`](./sandbox.md).

For the signed-app smoke, use Active window capture and Chrome with **Read Chrome page text** enabled:

- On a long ordinary article or problem page, capture while scrolled near the bottom and confirm the
  Accessibility block contains useful off-screen text while the OCR block matches the viewport.
- Open a virtualized editor and confirm current visible code appears through OCR even when the
  Accessibility tree exposes only a small editor region.
- Dock DevTools, then capture the page and confirm semantic text comes from the page web area. Repeat
  with two same-sized Chrome windows and confirm the screenshot and text use the focused window.
- Show a diagram and confirm the screenshot supplies visual information absent from Accessibility.
  Put text in a password field and confirm it does not appear in model-facing traffic.
- Deny or revoke Accessibility and confirm the setting remains Off while active-window OCR continues.
  Enable it while stopped, start a session, then turn it Off and confirm the next attempt omits the
  Accessibility block without presenting privacy UI.
- Confirm capture does not focus, scroll, mutate, or otherwise change Chrome. Normal bounded session
  artifacts may include `shot-N.jpg` and `brain-traffic.jsonl`, whose existing wire-audit records can
  contain current browser text. Confirm Jarvis creates no rolling image archive or separate
  browser-text archive and never replays historical screenshots.

Accessibility is not complete HTML or a complete editor buffer. Lazy, virtualized, canvas, image, and
hidden content may be absent; OCR is limited to visible pixels and may misread tokens. Jarvis sends
both current sources when available and keeps no separate historical screen-text cache.

## Live e2e tests

Behavior that needs real grants, capture devices, providers, and subscription sign-ins is verified by
`./scripts/run-live-tests.sh`, which drives the development app through scripted interview scenarios
and asserts on the session folders they leave. [live-e2e-tests.md](./live-e2e-tests.md) holds the
prerequisites, the case index, and the manual checks that stay outside the command.
