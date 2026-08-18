# Menu-bar update via Sparkle

> Design agreed 2026-08-18. Scope contract for the PR that adds a "Check for Updates…" item to the
> Jarvis menu bar.

## Goal

A menu-bar item that updates an installed Jarvis to the latest published release, without the user
downloading and dragging a DMG by hand.

## Approach

[Sparkle 2](https://sparkle-project.org) (2.9.6), the standard updater for Developer ID-distributed
Mac apps. It performs the check, download, signature verification, atomic install, and relaunch.
The alternatives — a hand-rolled GitHub Releases downloader, or a menu item that merely opens the
release page — were rejected: the first would require reimplementing two independent signature
checks plus self-replacement, and the second is not an update.

### Feasibility, verified before committing to the approach

A throwaway package outside the repo confirmed, on this Command Line Tools-only machine:

- `swift build` resolves Sparkle's **remote** `binaryTarget` and links it; no Xcode required.
- SwiftPM copies `Sparkle.framework` next to the built executable, ready to embed.
- `@executable_path/../Frameworks` injects cleanly through `linkerSettings`.
- The framework's nested code is `Autoupdate`, `Updater.app`, and `XPCServices/{Downloader,Installer}.xpc`.
- Sparkle's tools (`generate_keys`, `sign_update`, `generate_appcast`) ship in
  `.build/artifacts/sparkle/Sparkle/bin/`, so CI gets them from the same `swift build`.

Sparkle's sandboxing guide states the XPC services are only needed by sandboxed apps. Jarvis is not
App-Sandboxed, so they are deleted at embed time and never signed or notarized.

## How an update runs

1. The user picks **Check for Updates…**. Nothing before this point touches the network.
2. Sparkle GETs `SUFeedURL` — `https://github.com/JINGBANZ/jarvis/releases/latest/download/appcast.xml`.
   GitHub resolves `/releases/latest/` to the newest non-draft, non-prerelease release.
3. Sparkle compares the appcast's `sparkle:version` with the running `CFBundleVersion`. Equal or
   older ends the flow with "You're up to date"; nothing downloads.
4. Newer shows the update dialog with release notes. The download starts only on the user's confirmation.
5. Sparkle downloads `Jarvis.dmg` from the **tag-pinned** enclosure URL — the same bytes a human
   would download.
6. It verifies both the EdDSA signature over the downloaded bytes (against `SUPublicEDKey`) and that
   the new app's Developer ID signature matches the running app's. Either failing aborts the install.
7. `Autoupdate` quits Jarvis, replaces the bundle in place, and relaunches it.

TCC grants for Microphone and Screen Recording survive, because macOS keys them to the code
signature and the Developer ID identity is stable across releases.

## Behavior contract

| Situation | Behavior |
|---|---|
| Release build, no session running | Item enabled; check runs on click |
| Release build, session live or a turn draining | Item **disabled** |
| Development build (`build-app.sh`) | Item **absent** |
| Already on the newest version | "You're up to date"; no download |
| Signature or notarization mismatch | Install refused by Sparkle |
| Appcast unreachable | Sparkle reports the error; the app is otherwise unaffected |

The disabled-while-running rule follows the runtime safety boundary in `AGENTS.md`: during the live
pipeline the only permitted presentation paths are the two capture-excluded overlays, explicitly
opened Settings/Activity, and unavoidable macOS privacy UI. An update dialog is none of those, and
installing would quit and relaunch the app mid-session.

`SUEnableAutomaticChecks=false` is set explicitly so Sparkle never shows its first-launch "check
automatically?" prompt, which would itself be an autonomous presentation.

## Changes

### Application

- `Package.swift` — Sparkle dependency on the `JarvisApp` target, plus the Frameworks rpath.
- `Sources/JarvisApp/Updates/UpdateController.swift` — new. A thin adapter over
  `SPUStandardUpdaterController`. Its initializer fails when `SUFeedURL` is absent, which is how
  development builds end up with no updater rather than a build-time flag.
- `Sources/JarvisApp/MenuBar/MenuBarController.swift` — a "Check for Updates…" item between
  Settings… and Quit, built with the existing `.standard(...)` helper. Omitted when there is no
  updater; disabled while the session is active.
- `Sources/JarvisApp/App/AppDelegate.swift` — owns the controller, wires the callback.
- `Resources/Info.plist` — `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks=false`.

### Packaging

- `scripts/build-app.sh` — removes `SUFeedURL` from the development bundle's `Info.plist`, beside
  the three identity rewrites it already performs.
- `scripts/package-app.sh` — copies `Sparkle.framework` into `Contents/Frameworks/`, deletes its
  `XPCServices`, and signs inside-out (`Autoupdate`, `Updater.app`, the framework, then the app),
  each with `--options runtime --timestamp`. The comment asserting the bundle has no nested code is
  no longer true and is rewritten.
- `scripts/verify-release.sh` — asserts the mounted app carries a valid embedded `Sparkle.framework`
  with no XPC services.

### Release

- `.github/workflows/release.yml` — after `verify-release.sh`, sign the final **stapled** DMG with
  `sign_update` (stapling changes the bytes, so the signature must come after it), render a
  single-item `appcast.xml`, and upload it beside `Jarvis.dmg`. The existing guard that rejects any
  asset other than `Jarvis.dmg` widens to the two-asset set.
- `scripts/check-release-config.sh`, `scripts/check-app-identities.sh` — extended to hold the new
  packaging and release contract, the way they already hold the DMG layout and identity contracts.

### Appcast contents

One `<item>` per release carrying `sparkle:version` (`CFBundleVersion`), `sparkle:shortVersionString`,
a tag-pinned `<enclosure>` with `length` and `sparkle:edSignature`, `pubDate`, and
`sparkle:minimumSystemVersion` of `14.2`. Release notes are the GitHub release body rendered to HTML
through `gh api /markdown` and embedded in the item.

## Key management

The EdDSA keypair is generated by the owner, not by this change:

1. Run Sparkle's `generate_keys`, which stores the private key in the login Keychain and prints the
   public key.
2. The public key goes into `Resources/Info.plist` as `SUPublicEDKey`.
3. `generate_keys -x` exports the private key; it becomes the `SPARKLE_ED_PRIVATE_KEY` secret in the
   repository's existing `release` environment, alongside the signing and notarization secrets.

The private key never enters the repository.

## Verification

- The gate: `swift build && ./scripts/run-tests.sh`, including the extended guard scripts. Those
  guards are how this repository encodes packaging contracts; `JarvisApp` itself is smoke-checked
  rather than unit-tested, per `AGENTS.md`.
- Live smoke: a development build shows no update item; a signed release build shows it; checking at
  the current version reports up to date; the item greys out while a session runs.
- End-to-end update can only be proven by cutting a real release. The first release carrying this
  code is the first one that can be updated *from*.

## Non-goals

Background or scheduled checks. A menu-bar badge for an available update. Delta updates. Beta or
multi-channel feeds. Any Settings UI for update preferences. Updating development builds.
