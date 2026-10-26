# Build Versus Fork

Jarvis is a native Swift macOS application built directly around the
[voice-only coaching contract](./architecture.md#1-vision). A fork would need to preserve that
contract across audio capture, proactive scheduling, model tools, overlay delivery, and evidence
privacy. Borrowing a capture or overlay implementation alone does not supply the coaching loop.

## Why native Swift

The product targets macOS, so a shared Windows/web application layer does not meet an additional
platform requirement. AppKit, Core Audio, Vision, and the system capture helper expose the OS
capabilities through thin adapters. Foundation-only policy and injected ports let most behavior be
verified independently of permissions, devices, and providers; see
[the library boundaries](./build-and-run.md#toolchain).

The model owns coaching decisions, while Jarvis owns deterministic scheduling, bounded tool
execution, client-managed history, and safe delivery. Building that small harness keeps those
boundaries explicit rather than adapting another application's interaction and persistence model.
The [lean coaching core](./lean-coaching-core.md) defines the dependency rule for that harness.

## What can be borrowed

An external implementation can inform native capture, nonactivating windows, and proactive trigger
patterns. Before adopting code, inspect its exact revision, license, platform assumptions, and
failure behavior. A framework's content-protection flag does not establish that auxiliary windows
or a receiving meeting application are protected; use the
[capture validation contract](./overlay-invisibility.md#validation-layers).

The [landscape criteria](./landscape-survey.md) define what a new comparison must demonstrate.
Current dependencies and pins live in [Package.swift](../Package.swift) and the packaging scripts,
with provenance described in [build-and-run.md](./build-and-run.md#packaging--signing--why-permission-grants-persist).
