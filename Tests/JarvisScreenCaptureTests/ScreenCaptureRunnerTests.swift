import JarvisTestSupport
import Darwin
import Foundation
import JarvisCore
import Testing
@testable import JarvisScreenCapture

@Suite(.serialized) struct ScreenCaptureRunnerTests {
    @Test func successfulCaptureDeletesItsTransientJPEGBeforeReturning() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(
            in: directory,
            script: """
                #!/bin/sh
                for output in "$@"; do :; done
                printf 'jpeg' > "$output"
                """)
        let runner = ScreenCaptureRunner(
            captureDirectory: directory,
            executable: executable,
            launcher: TestCommandOwnership.makeLauncher())

        switch runner.makeAttemptRunner().capture(arguments: []) {
        case .captured(let data):
            #expect(data == Data("jpeg".utf8))
        case .failed, .cleanupFailed, .cancelled:
            Issue.record("expected a successful capture")
        }
        #expect(try transientJPEGs(in: directory).isEmpty)
    }

    @Test func failedCaptureDeletesItsTransientJPEGBeforeReturning() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(
            in: directory,
            script: """
                #!/bin/sh
                for output in "$@"; do :; done
                printf 'partial jpeg' > "$output"
                exit 1
                """)
        let runner = ScreenCaptureRunner(
            captureDirectory: directory,
            executable: executable,
            launcher: TestCommandOwnership.makeLauncher())

        switch runner.capture(arguments: []) {
        case .failed:
            break
        case .captured, .cleanupFailed, .cancelled:
            Issue.record("expected a failed capture")
        }
        #expect(try transientJPEGs(in: directory).isEmpty)
    }

    @Test func cleanupFailurePoisonsRunnerAndPreventsDisplayFallback() throws {
        let directory = try makeDirectory()
        let captureDirectory = directory.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: captureDirectory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let callsFile = directory.appendingPathComponent("calls")
        let executable = try makeExecutable(
            in: directory,
            script: """
                #!/bin/sh
                for output in "$@"; do :; done
                printf 'call\\n' >> '\(shellQuoted(callsFile.path))'
                printf 'undeleted jpeg' > "$output"
                chmod 500 '\(shellQuoted(captureDirectory.path))'
                exit 1
                """)
        let selection = ScreenCaptureSelection(
            scope: .entireDisplay, explicitDisplay: 2, browserTextEnabled: false)
        let runner = ScreenCaptureRunner(
            captureDirectory: captureDirectory,
            executable: executable,
            launcher: TestCommandOwnership.makeLauncher())
        let screen = ScreenCaptureCLI(runner: runner)

        #expect(screen.capture(selection) == nil)
        #expect(try transientJPEGs(in: captureDirectory).count == 1)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: captureDirectory.path)
        switch runner.makeAttemptRunner().capture(arguments: []) {
        case .cleanupFailed:
            break
        case .captured, .failed, .cancelled:
            Issue.record("expected a poisoned runner to remain cleanup-failed")
        }
        let calls = try String(contentsOf: callsFile, encoding: .utf8)
            .split(separator: "\n")
        #expect(calls.count == 1)
    }

    @Test func cancellationEscalatesAndDeletesJPEGBeforeReturning() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let executable = try makeExecutable(
            in: directory,
            script: """
                #!/bin/sh
                for output in "$@"; do :; done
                printf 'jpeg' > "$output"
                printf '%s\\n' "$$" > '\(shellQuoted(pidFile.path))'
                trap '' TERM
                while kill -0 "$PPID" 2>/dev/null; do sleep 1; done
                """)
        let runner = ScreenCaptureRunner(
            captureDirectory: directory,
            executable: executable,
            launcher: TestCommandOwnership.makeLauncher())
        let capture = captureOffPool(runner)
        let pid: pid_t
        do {
            try await waitForFile(pidFile)
            try await waitForTransientJPEG(in: directory)
            pid = try #require(
                pid_t(String(contentsOf: pidFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch {
            await cancelAndAwait(capture, runner: runner)
            throw error
        }

        let cancelledAt = Date()
        runner.cancelCapture()
        switch await capture.value {
        case .cancelled:
            break
        case .captured, .failed, .cleanupFailed:
            Issue.record("expected a cancelled capture")
        }

        #expect(Date().timeIntervalSince(cancelledAt) < 2)
        #expect(try transientJPEGs(in: directory).isEmpty)
        #expect(kill(pid, 0) == -1)
    }

    /// Whether a request lands between the helper's exit and deregistration depends on how long the
    /// JPEG read and delete take, so this asserts only what holds either way.
    @Test func cancellationLosingTheRaceWithTheHelperCancelsOnlyItsOwnCapture() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exitedFile = directory.appendingPathComponent("exited")
        // 64 MB keeps the read and delete busy after the helper exits, widening that window.
        let executable = try makeExecutable(
            in: directory,
            script: """
                #!/bin/sh
                for output in "$@"; do :; done
                dd if=/dev/zero of="$output" bs=1048576 count=64 2>/dev/null
                printf 'exited\\n' > '\(shellQuoted(exitedFile.path))'
                """)
        let runner = ScreenCaptureRunner(
            captureDirectory: directory,
            executable: executable,
            launcher: TestCommandOwnership.makeLauncher())

        let capture = captureOffPool(runner)
        try await waitForFile(exitedFile, pollNanoseconds: 500_000)
        // Repeated cancellation stays attached to the retired attempt.
        for _ in 0..<200 {
            runner.cancelCapture()
            try await Task.sleep(nanoseconds: 500_000)
        }
        switch await capture.value {
        case .cancelled, .captured:
            // Either is correct, depending on whether the request landed before the call returned.
            break
        case .failed, .cleanupFailed:
            Issue.record("the raced capture must not fail outright")
        }

        switch runner.makeAttemptRunner().capture(arguments: []) {
        case .captured:
            break
        case .failed, .cleanupFailed, .cancelled:
            Issue.record("a later capture must not inherit a spent cancellation request")
        }
        #expect(try transientJPEGs(in: directory).isEmpty)
    }

    @Test func aCancellationArrivingAfterTheHelperExitedStillMarksItsOwnCommand() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, script: "#!/bin/sh\nexit 0\n")
        let command = ScreenCaptureRunner.Command(
            executable: executable,
            arguments: [],
            output: directory.appendingPathComponent("capture.jpg"),
            launcher: TestCommandOwnership.makeLauncher())

        _ = command.run()
        command.cancel()

        #expect(command.wasCancelled)
    }

    @Test func cancellationBeforeLaunchIsLatchedOnlyForItsOwnAttempt() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(
            in: directory,
            script: """
                #!/bin/sh
                for output in "$@"; do :; done
                printf 'jpeg' > "$output"
                """)
        let runner = ScreenCaptureRunner(
            captureDirectory: directory,
            executable: executable,
            launcher: TestCommandOwnership.makeLauncher())

        let cancelled = runner.makeAttemptRunner()
        cancelled.cancelCapture()
        if case .cancelled = cancelled.capture(arguments: []) {} else {
            Issue.record("a cancelled attempt must not launch its capture")
        }

        switch runner.makeAttemptRunner().capture(arguments: []) {
        case .captured(let data):
            #expect(data == Data("jpeg".utf8))
        case .failed, .cleanupFailed, .cancelled:
            Issue.record("a capture that was never cancelled must not report `.cancelled`")
        }
        #expect(try transientJPEGs(in: directory).isEmpty)
    }

    @Test func overlappingAttemptsKeepCancellationAndCleanupIndependent() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldPID = directory.appendingPathComponent("old-pid")
        let newPID = directory.appendingPathComponent("new-pid")
        let release = directory.appendingPathComponent("release")
        let executable = try makeExecutable(in: directory, script: """
            #!/bin/sh
            kind="$1"
            for output in "$@"; do :; done
            printf 'jpeg' > "$output"
            if [ "$kind" = old ]; then
                trap '' TERM
                printf '%s\\n' "$$" > '\(shellQuoted(oldPID.path))'
                while kill -0 "$PPID" 2>/dev/null; do sleep 0.05; done
            else
                printf '%s\\n' "$$" > '\(shellQuoted(newPID.path))'
                while [ ! -f '\(shellQuoted(release.path))' ] && kill -0 "$PPID" 2>/dev/null; do sleep 0.05; done
            fi
            """)
        let factory = ScreenCaptureRunner(captureDirectory: directory, executable: executable,
            launcher: TestCommandOwnership.makeLauncher())
        let old = factory.makeAttemptRunner()
        let replacement = factory.makeAttemptRunner()
        let first = captureOffPool(old, arguments: ["old"])
        let second = captureOffPool(replacement, arguments: ["new"])
        do {
            try await waitForFile(oldPID)
            try await waitForFile(newPID)
            old.cancelCapture()
            if case .cancelled = await first.value {} else { Issue.record("old capture must cancel") }
            old.cancelCapture()
            let pid = try #require(pid_t(String(contentsOf: newPID, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(kill(pid, 0) == 0, "old cancellation cannot terminate the replacement helper")
            try Data().write(to: release)
            if case .captured(let data) = await second.value {
                #expect(data == Data("jpeg".utf8))
            } else { Issue.record("replacement capture must succeed") }
            #expect(try transientJPEGs(in: directory).isEmpty)
        } catch {
            await cancelAndAwait(first, runner: old)
            await cancelAndAwait(second, runner: replacement)
            throw error
        }
    }

    /// A crash mid-capture must not leave a readable screenshot behind.
    @Test func transientJPEGIsOwnerOnlyWhileTheHelperIsStillRunning() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(
            in: directory,
            script: """
                #!/bin/sh
                for output in "$@"; do :; done
                printf 'jpeg' > "$output"
                while kill -0 "$PPID" 2>/dev/null; do sleep 1; done
                """)
        let runner = ScreenCaptureRunner(
            captureDirectory: directory,
            executable: executable,
            launcher: TestCommandOwnership.makeLauncher())
        let capture = captureOffPool(runner)
        do {
            try await waitForTransientJPEG(in: directory)
            let jpeg = try #require(try transientJPEGs(in: directory).first)
            let mode = try #require(
                FileManager.default.attributesOfItem(atPath: jpeg.path)[.posixPermissions]
                    as? NSNumber)
            #expect(mode.int16Value == 0o600)
        } catch {
            await cancelAndAwait(capture, runner: runner)
            throw error
        }

        runner.cancelCapture()
        _ = await capture.value
    }

    /// `capture(arguments:)` blocks in `waitUntilExit`. Parked captures on the width-limited
    /// cooperative pool deadlock a small runner, so block a GCD thread instead.
    private func captureOffPool(
        _ runner: ScreenCaptureRunner, arguments: [String] = []
    ) -> Task<ScreenCaptureRunner.Outcome, Never> {
        Task {
            guard !Task.isCancelled else { return .cancelled }
            return await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: runner.capture(arguments: arguments))
                }
            }
        }
    }

    private func cancelAndAwait(
        _ capture: Task<ScreenCaptureRunner.Outcome, Never>,
        runner: ScreenCaptureRunner
    ) async {
        capture.cancel()
        runner.cancelCapture()
        _ = await capture.value
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenCaptureRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        return directory
    }

    /// A script that loops must stop once `$PPID`, the test process, is gone: a run that dies
    /// mid-test must not leave a stub looping forever.
    private func makeExecutable(in directory: URL, script: String) throws -> URL {
        let executable = directory.appendingPathComponent("fake-screencapture")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path)
        return executable
    }

    private func waitForFile(_ file: URL, pollNanoseconds: UInt64 = 20_000_000) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        _ = try #require(
            FileManager.default.fileExists(atPath: file.path),
            "timed out waiting for \(file.lastPathComponent)")
    }

    private func waitForTransientJPEG(in directory: URL) async throws {
        let deadline = Date().addingTimeInterval(10)
        while try transientJPEGs(in: directory).isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = try #require(
            try !transientJPEGs(in: directory).isEmpty,
            "timed out waiting for the transient JPEG")
    }

    private func transientJPEGs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
            .filter {
                $0.lastPathComponent.hasPrefix("capture-")
                    && $0.pathExtension == "jpg"
            }
    }

    private func shellQuoted(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "'\\''")
    }
}
