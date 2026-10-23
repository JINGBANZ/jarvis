import Darwin
import Foundation
import JarvisCore
import JarvisTestSupport
import os
@testable import JarvisBrainProviders

@main enum LaunchFixture {
    static func main() async throws {
        let mode = CommandLine.arguments[1]
        if mode == "timing" {
            let timings = AgentCLIPhaseTimings()
            let output = try await AgentCLIProcessRunner.run(AgentCLIRun(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 0.2; echo ready; sleep 0.2; exit 0"], stdin: "hi",
                workingDirectory: FileManager.default.temporaryDirectory, timeout: 10), timings: timings)
            guard let entered = timings.instant(.runnerEntered),
                  let launched = timings.instant(.processLaunched),
                  let stdin = timings.instant(.stdinDelivered),
                  let first = timings.instant(.firstStdoutByte),
                  let exited = timings.instant(.processExited) else {
                print("Missing required timing phase")
                exit(1)
            }
            let checks = [output.stdout.contains("ready"), entered <= launched, launched <= stdin,
                          stdin <= first, first <= exited, first - launched >= 150_000_000,
                          exited - first >= 150_000_000, timings.instant(.replyParsed) == nil]
            print("All original timing assertions: \(checks); firstOut-launched=\(first - launched); exited-firstOut=\(exited - first)")
            exit(checks.allSatisfy { $0 } ? 0 : 1)
        } else if mode == "timeout" || mode == "cancel" {
            let timings = AgentCLIPhaseTimings()
            let task = Task {
                try await AgentCLIProcessRunner.run(AgentCLIRun(
                    executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], stdin: nil,
                    workingDirectory: FileManager.default.temporaryDirectory,
                    timeout: mode == "timeout" ? 0.05 : 10), timings: timings)
            }
            if mode == "cancel" {
                let deadline = ContinuousClock.now + .seconds(3)
                while timings.instant(.processLaunched) == nil && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard timings.instant(.processLaunched) != nil else { exit(1) }
                task.cancel()
            }
            do { _ = try await task.value; exit(1) }
            catch {
                let expected = mode == "cancel" ? error is CancellationError
                    : (error as NSError).domain == AgentCLIProcessRunner.errorDomain
                print("\(mode) preserved: \(expected)")
                exit(expected ? 0 : 1)
            }
        } else if mode == "sign-in" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let pids = OSAllocatedUnfairLock<Set<Int32>>(initialState: [])
            let login = LocalProxySignIn(executable: directory.appendingPathComponent("login"),
                configURL: directory.appendingPathComponent("config"), authDirectory: directory,
                signInPIDs: pids)
            let first = Task { for await _ in login.run(.codexSubscription) {} }
            let second = Task { for await _ in login.run(.claudeSubscription) {} }
            var children: [Int32] = []
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                children = ["-codex-login", "-claude-login"].compactMap {
                    guard let text = try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) else { return nil }
                    return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if children.count == 2 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let known = pids.withLock { $0 }
            let published = children.count == 2 && children.allSatisfy { known.contains($0) }
            print("PID files=\(children.count); published before registration reply=\(known.count)")
            // Same registry read/signal as LocalProxySupervisor.terminateNow().
            for pid in known { kill(pid, SIGTERM) }
            for pid in children { kill(pid, SIGTERM) }
            first.cancel(); second.cancel()
            await first.value; await second.value
            // A cancelled stream consumer can finish before its producer's registration/defer.
            let cleanupDeadline = ContinuousClock.now + .seconds(3)
            while !pids.withLock({ $0.isEmpty }) && ContinuousClock.now < cleanupDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let cleaned = pids.withLock { $0.isEmpty }
            print("Sign-in producer cleanup completed: \(cleaned)")
            exit(published && cleaned ? 0 : 1)
        } else if mode == "no-spawn" || mode == "registration-error" {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: mode == "no-spawn"
                ? "/jarvis-fixture-does-not-exist" : "/bin/sleep")
            child.arguments = mode == "no-spawn" ? [] : ["5"]
            do { try TestCommandOwnership.launchChild(child); exit(1) }
            catch {
                print("Launch failed: pid=\(child.processIdentifier); running=\(child.isRunning)")
                if mode == "no-spawn" && (child.processIdentifier != 0 || child.isRunning) { exit(1) }
                if child.processIdentifier > 0 { child.waitUntilExit() }
            }
        } else { exit(2) }
    }
}
