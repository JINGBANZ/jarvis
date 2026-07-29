import Foundation
import Testing
@testable import JarvisCore

@Suite struct AgentRuntimeProcessTests {
    @Test func keepsOneProcessAliveAcrossMultipleJSONLines() async throws {
        let process = try AgentRuntimeProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf '{\"ready\":true}\\n'; while IFS= read -r line; do printf '%s\\n' \"$line\"; done",
            ],
            workingDirectory: FileManager.default.temporaryDirectory)
        defer { process.terminateNow() }

        let ready = try await process.nextLine(timeout: 2)
        #expect(ready.text == #"{"ready":true}"#)
        try await process.sendLine(#"{"turn":1}"#, timeout: 2)
        try await process.sendLine(#"{"turn":2}"#, timeout: 2)
        let first = try await process.nextLine(timeout: 2)
        let second = try await process.nextLine(timeout: 2)
        #expect(first.text == #"{"turn":1}"#)
        #expect(second.text == #"{"turn":2}"#)
        #expect(process.isRunning)
    }

    @Test func timeoutTerminatesThePersistentProcess() async throws {
        let process = try AgentRuntimeProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            workingDirectory: FileManager.default.temporaryDirectory)
        let started = Date()
        do {
            _ = try await process.nextLine(timeout: 0.2)
            Issue.record("expected timeout")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
        }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(!process.isRunning)
    }

    @Test func appliesExplicitEnvironmentOverrides() async throws {
        let process = try AgentRuntimeProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"printf '%s\n' "$JARVIS_RUNTIME_TEST""#],
            workingDirectory: FileManager.default.temporaryDirectory,
            environmentOverrides: ["JARVIS_RUNTIME_TEST": "isolated"])
        defer { process.terminateNow() }

        let line = try await process.nextLine(timeout: 2)
        #expect(line.text == "isolated")
    }

    @Test func cancellationTerminatesThePersistentProcess() async throws {
        let process = try AgentRuntimeProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            workingDirectory: FileManager.default.temporaryDirectory)
        let task = Task { try await process.nextLine(timeout: 60) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("expected cancellation")
            return
        }
        #expect(error is CancellationError)
        #expect(!process.isRunning)
    }

    @Test func stdinDeliveryIsBoundedAndTerminatesABlockedRuntime() async throws {
        let process = try AgentRuntimeProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            workingDirectory: FileManager.default.temporaryDirectory)
        let started = Date()
        do {
            try await process.sendLine(
                String(repeating: "x", count: 2_000_000),
                timeout: 0.2)
            Issue.record("expected blocked stdin delivery to fail")
        } catch {
            #expect(Date().timeIntervalSince(started) < 5)
        }
        #expect(!process.isRunning)
    }

    @Test func exitedParentDoesNotWaitForAHelperHeldStdoutPipe() async throws {
        let process = try AgentRuntimeProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & exit 7"],
            workingDirectory: FileManager.default.temporaryDirectory)
        defer { process.terminateNow() }

        let started = Date()
        do {
            _ = try await process.nextLine(timeout: 5)
            Issue.record("expected exited runtime")
        } catch {
            #expect(error.localizedDescription.contains("exit 7"))
        }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func oversizedUnterminatedStdoutTerminatesTheRuntime() async throws {
        let process = try AgentRuntimeProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "yes x | tr -d '\\n' | head -c 2000000; sleep 30",
            ],
            workingDirectory: FileManager.default.temporaryDirectory)
        defer { process.terminateNow() }

        try await Task.sleep(nanoseconds: 300_000_000)
        do {
            _ = try await process.nextLine(timeout: 2)
            Issue.record("expected stdout buffer overflow")
        } catch {
            #expect(error.localizedDescription.contains("stdout exceeded its buffer limit"))
        }
        #expect(!process.isRunning)
    }

    @Test func excessiveBufferedStdoutLinesTerminateTheRuntime() async throws {
        let process = try AgentRuntimeProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "i=0; while [ \"$i\" -lt 5000 ]; do printf '\\n'; i=$((i + 1)); done; sleep 30",
            ],
            workingDirectory: FileManager.default.temporaryDirectory)
        defer { process.terminateNow() }

        try await Task.sleep(nanoseconds: 300_000_000)
        do {
            _ = try await process.nextLine(timeout: 2)
            Issue.record("expected stdout line buffer overflow")
        } catch {
            #expect(error.localizedDescription.contains("stdout exceeded its buffer limit"))
        }
        #expect(!process.isRunning)
    }

    @Test func immediateStdoutOverflowTerminatesTheOriginalHelper() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRuntimeProcessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let childFile = directory.appendingPathComponent("child")
        let process = try AgentRuntimeProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                sh -c 'trap "" TERM; exec sleep 6' &
                child="$!"
                printf '%s\\n' "$child" > '\(childFile.path)'
                i=0
                while [ "$i" -lt 5000 ]; do printf '\\n'; i=$((i + 1)); done
                wait
                """,
            ],
            workingDirectory: directory)
        defer { process.terminateNow() }

        let childDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: childFile.path),
              Date() < childDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let child = try #require(pid_t(
            String(contentsOf: childFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))

        // Let the handler drain the already-buffered burst; reading immediately could consume one
        // empty line before the configured line-count limit is crossed.
        try await Task.sleep(nanoseconds: 300_000_000)
        do {
            _ = try await process.nextLine(timeout: 2)
            Issue.record("expected stdout line buffer overflow")
        } catch {
            #expect(error.localizedDescription.contains("stdout exceeded its buffer limit"))
        }
        let terminationDeadline = Date().addingTimeInterval(4)
        while processState(child) == "running", Date() < terminationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(processState(child) != "running")
    }

    @Test func terminationReachesDescendantHelpersInTheSpawnedProcessGroup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRuntimeProcessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = try AgentRuntimeProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                sleep 30 &
                child="$!"
                group=$(ps -o pgid= -p "$child" | tr -d ' ')
                printf '%s %s %s\\n' "$$" "$child" "$group"
                wait
                """,
            ],
            workingDirectory: directory)
        let identifiers = try await process.nextLine(timeout: 2).text
            .split(separator: " ")
            .map(String.init)
        #expect(identifiers.count == 3)
        let parent = try #require(pid_t(identifiers[0]))
        let child = try #require(pid_t(identifiers[1]))
        let group = try #require(pid_t(identifiers[2]))
        #expect(group == parent)

        process.terminateNow()
        let deadline = Date().addingTimeInterval(2)
        while processState(child) == "running", Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(processState(child) != "running")
    }

    @Test func terminationReachesAHelperAfterItsGroupLeaderExitsImmediately() async throws {
        let process = try AgentRuntimeProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                sh -c 'trap "" TERM; exec sleep 6' &
                child="$!"
                printf '%s\\n' "$child"
                exit 0
                """,
            ],
            workingDirectory: FileManager.default.temporaryDirectory)
        let child = try #require(pid_t(try await process.nextLine(timeout: 2).text))

        do {
            _ = try await process.nextLine(timeout: 2)
            Issue.record("expected group leader exit")
        } catch {
            #expect(error.localizedDescription.contains("exit 0"))
        }
        #expect(processState(child) == "running")
        process.terminateNow()

        let deadline = Date().addingTimeInterval(4)
        while processState(child) == "running", Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(processState(child) != "running")
    }

    @Test func escalationKillsAnOriginalHelperThatIgnoredTermination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRuntimeProcessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = try AgentRuntimeProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                sh -c 'trap "" TERM; while :; do sleep 1; done' &
                child="$!"
                printf '%s\\n' "$child"
                wait
                """,
            ],
            workingDirectory: directory)
        let child = try #require(pid_t(try await process.nextLine(timeout: 2).text))

        process.terminateNow()
        let deadline = Date().addingTimeInterval(4)
        while processState(child) == "running", Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(processState(child) != "running")
    }

    @Test func escalationReachesAHelperForkedDuringTermination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRuntimeProcessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let childFile = directory.appendingPathComponent("child")
        let ignoresTermination = directory.appendingPathComponent("ignores-termination")
        try Data("""
            #!/bin/sh
            trap '' TERM
            exec /bin/sleep 30
            """.utf8).write(to: ignoresTermination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: ignoresTermination.path)
        let process = try AgentRuntimeProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                (
                  trap '' TERM
                  sleep 0.2
                  \(ignoresTermination.path) &
                  printf '%s\\n' "$!" > '\(childFile.path)'
                ) &
                printf 'ready\\n'
                wait
                """,
            ],
            workingDirectory: directory)
        _ = try await process.nextLine(timeout: 2)

        process.terminateNow()
        let childDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: childFile.path),
              Date() < childDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let child = try #require(pid_t(
            String(contentsOf: childFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))

        let terminationDeadline = Date().addingTimeInterval(4)
        while processState(child) == "running", Date() < terminationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(processState(child) != "running")
    }

    private func processState(_ processIdentifier: pid_t) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "state=", "-p", String(processIdentifier)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "absent"
        }
        let state = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if state.isEmpty { return "absent" }
        return state.hasPrefix("Z") ? "zombie" : "running"
    }
}
