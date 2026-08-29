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
            executable: executable)

        switch runner.capture(arguments: []) {
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
            executable: executable)

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
        // The selection is frozen by the attempt's plan revision, so the adapter is handed it
        // rather than reading a preference store at capture time.
        let selection = ScreenCaptureSelection(scope: .entireDisplay, explicitDisplay: 2)
        let runner = ScreenCaptureRunner(
            captureDirectory: captureDirectory,
            executable: executable)
        let screen = ScreenCaptureCLI(runner: runner)

        #expect(screen.capture(selection) == nil)
        #expect(try transientJPEGs(in: captureDirectory).count == 1)

        // Restoring permissions must not let this session-local runner forget an unaccounted-for
        // screen file and start another helper.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: captureDirectory.path)
        switch runner.capture(arguments: []) {
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
                while :; do sleep 1; done
                """)
        let runner = ScreenCaptureRunner(
            captureDirectory: directory,
            executable: executable)
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

    /// Regression: a cancellation that loses the race with the helper's exit must be answered by the
    /// capture it was issued against, never held over. `Command.cancel()` used to report "already
    /// finished" as "still pending", so a request landing in the window between the helper exiting
    /// and `capture(arguments:)` deregistering — the transient JPEG's read and deletion sit in it —
    /// silently cancelled the *next* screenshot instead.
    ///
    /// Landing inside that window depends on how long the read and delete happen to take, so this
    /// asserts only what holds either way: the capture answers its own request and nothing survives
    /// to reach the next one. That the request counts at all once the helper is gone is pinned by
    /// `aCancellationArrivingAfterTheHelperExitedStillMarksItsOwnCommand`.
    @Test func cancellationLosingTheRaceWithTheHelperCancelsOnlyItsOwnCapture() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exitedFile = directory.appendingPathComponent("exited")
        // A payload big enough that reading and deleting it keeps `capture(arguments:)` busy well
        // after the helper is gone, so the request below lands in that window rather than after the
        // call has already returned.
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
            executable: executable)

        let capture = captureOffPool(runner)
        try await waitForFile(exitedFile, pollNanoseconds: 500_000)
        // Repeat across the window: with no pending-request latch, a request that arrives once the
        // call has returned is a no-op, so over-asking cannot itself poison the runner.
        for _ in 0..<200 {
            runner.cancelCapture()
            try await Task.sleep(nanoseconds: 500_000)
        }
        switch await capture.value {
        case .cancelled, .captured:
            // Both are correct, and which one happens comes down to how fast the read and delete
            // were: the request either landed inside the window and was answered here, or arrived
            // after the call had already returned and was a no-op. What has to hold either way is
            // that it did not survive — that is the assertion below.
            break
        case .failed, .cleanupFailed:
            Issue.record("the raced capture must not fail outright")
        }

        // The request belonged to that capture. An unrelated later one must still shoot.
        switch runner.capture(arguments: []) {
        case .captured:
            break
        case .failed, .cleanupFailed, .cancelled:
            Issue.record("a later capture must not inherit a spent cancellation request")
        }
        #expect(try transientJPEGs(in: directory).isEmpty)
    }

    /// The half of the regression a capture-level test can only aim at: once the helper has exited,
    /// a cancellation still belongs to the command it was issued against. Marking it is what makes
    /// `capture(arguments:)` report `.cancelled` on its way out rather than leaving the request to
    /// be answered by the next screenshot.
    @Test func aCancellationArrivingAfterTheHelperExitedStillMarksItsOwnCommand() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, script: "#!/bin/sh\nexit 0\n")
        let command = ScreenCaptureRunner.Command(
            executable: executable,
            arguments: [],
            output: directory.appendingPathComponent("capture.jpg"))

        // Run to completion first: the helper is already gone when the request arrives, which is
        // the state the capture call is in while it reads and deletes the transient JPEG.
        _ = command.run()
        command.cancel()

        #expect(command.wasCancelled)
    }

    /// Regression: `cancelCapture()` with nothing in flight must be a no-op. `CoachDriver`'s
    /// `onCancel` fires whenever a cancelled attempt is sitting in `captureScreen`, including when
    /// its detached producer short-circuits and never calls `capture()` — that used to arm a request
    /// no one would consume, so the next attempt's first screenshot silently returned `.cancelled`.
    @Test func cancellingWithNothingInFlightDoesNotCancelALaterCapture() throws {
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
            executable: executable)

        runner.cancelCapture()

        switch runner.capture(arguments: []) {
        case .captured(let data):
            #expect(data == Data("jpeg".utf8))
        case .failed, .cleanupFailed, .cancelled:
            Issue.record("a capture that was never cancelled must not report `.cancelled`")
        }
        #expect(try transientJPEGs(in: directory).isEmpty)
    }

    /// The helper must create the transient JPEG owner-only from its first write, not only once
    /// cleanup chmods it — a crash mid-capture must not leave a readable screenshot behind.
    @Test func transientJPEGIsOwnerOnlyWhileTheHelperIsStillRunning() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(
            in: directory,
            script: """
                #!/bin/sh
                for output in "$@"; do :; done
                printf 'jpeg' > "$output"
                while :; do sleep 1; done
                """)
        let runner = ScreenCaptureRunner(
            captureDirectory: directory,
            executable: executable)
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

    /// `capture(arguments:)` blocks its calling thread in `waitUntilExit` until the helper dies,
    /// and these tests park the helper on purpose. That wait must never hold a cooperative-executor
    /// thread: the test body that observes the park and then requests cancellation runs on the same
    /// width-limited pool, so on a small runner enough simultaneously parked captures leave no
    /// thread for any release path and the whole test process deadlocks at 0% CPU (the CI hang the
    /// 10-minute backstop kept cancelling). Park a GCD thread instead and keep the pool free.
    private func captureOffPool(
        _ runner: ScreenCaptureRunner
    ) -> Task<ScreenCaptureRunner.Outcome, Never> {
        Task {
            guard !Task.isCancelled else { return .cancelled }
            return await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: runner.capture(arguments: []))
                }
            }
        }
    }

    /// A capture task cancelled before `ScreenCaptureRunner` registers its command still needs a
    /// cancellation request after registration. Keep requesting until the task is joined so no
    /// failure path can return with the infinite fixture or a transient JPEG still alive.
    private func cancelAndAwait(
        _ capture: Task<ScreenCaptureRunner.Outcome, Never>,
        runner: ScreenCaptureRunner
    ) async {
        capture.cancel()
        let cancellationPump = Task {
            while !Task.isCancelled {
                runner.cancelCapture()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        _ = await capture.value
        cancellationPump.cancel()
        _ = await cancellationPump.value
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenCaptureRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        return directory
    }

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
