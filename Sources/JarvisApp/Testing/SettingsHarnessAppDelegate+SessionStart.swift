#if JARVIS_LIVE_E2E
import Foundation
import JarvisCore

extension SettingsHarnessAppDelegate {
    func checkSessionStarts(output: URL, brain: BrainComposition) async throws {
        let launcher = AppProcessComposition.makeLauncher()
        let runtime = ReferenceRuntime(home: output.appendingPathComponent("start-references"), launcher: launcher)
        let readiness = JarvisReadiness()
        let start = SessionStart(readiness: readiness)
        func admission() -> PendingReferenceAdmission {
            PendingReferenceAdmission(library: runtime.library, deadline: .now + .seconds(2))
        }

        let stopped = readiness.begin(configuration: .init()).session
        let (requested, request) = AsyncStream<Void>.makeStream()
        var permission: CheckedContinuation<Bool, Never>?
        var installedStoppedStart = false
        let stoppedTask = start.prepare(stopped, references: admission()) {
            let granted = await withCheckedContinuation { continuation in
                permission = continuation
                request.yield(())
                request.finish()
            }
            installedStoppedStart = granted && start.finish(stopped)
        }
        for await _ in requested { break }
        let cancelled = start.cancel()
        readiness.stop(session: stopped)
        let idleAfterStop = !start.isPreparing && readiness.status == .stopped
        let live = readiness.begin(configuration: .init()).session
        var installedLiveStart = false
        let liveTask = start.prepare(live, references: admission()) {
            await stoppedTask.value
            installedLiveStart = start.finish(live)
        }
        permission?.resume(returning: true)
        await liveTask.value
        try require(cancelled == stopped && idleAfterStop && !installedStoppedStart && installedLiveStart,
                    "Stop retires a suspended Start before its permission result can affect the next Start")

        readiness.observe([
            .permissions(granted: Set(JarvisReadiness.Permission.allCases)),
            .brainPreparation(.ready),
            .transcriptionEndpoint(stream: .microphone, state: .ready),
            .transcriptionEndpoint(stream: .system, state: .ready),
            .capture(.ready),
        ], for: live)
        try require(readiness.status == .ready(.full), "synthetic active session is listening")
        let candidate = readiness.beginReplacement(configuration: .init()).session
        var rejectedCandidate = false
        let candidateTask = start.prepare(candidate, references: admission()) {
            guard start.isCurrent(candidate) else { return }
            rejectedCandidate = start.cancel() == candidate
            readiness.observe(.permissions(granted: []), for: candidate)
        }
        await candidateTask.value
        try require(rejectedCandidate && !start.isPreparing && readiness.activeSession == live
                    && readiness.status == .ready(.full), "rejected replacement preserves the listening session")

        let artifacts = SessionArtifacts(baseDirectory: output.appendingPathComponent("restart-sessions"))
        let composition = SessionComposition(
            brain: brain, referenceLibrary: runtime.library, artifacts: artifacts,
            overlayBox: OverlayComposition.makeBox(), readiness: readiness, errorReporter: ErrorReporter(),
            launcher: launcher, makeAudioSource: { _, _, _ in preconditionFailure("Synthetic drain only") })
        defer {
            ActivityLog.shared.disable()
            JarvisLog.detach()
        }
        let oldAudit = artifacts.beginNewSession()
        guard let oldDirectory = artifacts.currentSessionDir,
              let drain = composition.stop(reason: .stoppedByUser) else {
            throw CocoaError(.coderValueNotFound)
        }
        readiness.stop(session: live)
        let oldWasClosing = !artifacts.isAuditClosed(for: oldDirectory)
        let next = readiness.begin(configuration: .init()).session
        let nextAudit = artifacts.beginNewSession()
        let nextDirectory = artifacts.currentSessionDir
        await drain.value
        try require(oldWasClosing && artifacts.isAuditClosed(for: oldDirectory)
                    && nextDirectory != oldDirectory && artifacts.currentSessionDir == nextDirectory
                    && artifacts.sessionAudit?.sessionID == nextAudit.sessionID
                    && readiness.activeSession == next && readiness.status == .checking(.permissions),
                    "the old drain closes only its directory and preserves the new Start")
        oldAudit.record(.tip(hint: "retired session row"))
        nextAudit.record(.tip(hint: "current session row"))
        await composition.stop(reason: .stoppedByUser)?.value
        let rows = ActivityLog.shared.attach { _ in }.rows.joined()
        try require(rows.contains("current session row") && !rows.contains("retired session row"),
                    "Activity exposes only the new session's rows after the old drain completes")
    }
}
#endif
