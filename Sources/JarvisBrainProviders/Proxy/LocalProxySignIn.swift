import Foundation
import JarvisCore
import os
#if canImport(Darwin)
import Darwin
#endif

/// `-no-browser` keeps the one browser open in Jarvis code, behind the user's Sign in click.
/// That mode also queries public IP services for SSH tunnel hints, which Jarvis ignores.
public struct LocalProxySignIn: Sendable {
    public enum Event: Sendable, Equatable {
        /// The caller opens the OAuth page.
        case openURL(URL)
        case finished(accountFiles: [LocalProxyAccountFile])
        case failed(message: String)
    }

    private static let deadline: Duration = .seconds(10 * 60)

    /// The binary's authorize hosts; otherwise any line it prints could send the browser anywhere.
    private static let signInHosts: Set<String> = [
        "auth.openai.com", "claude.ai", "console.anthropic.com",
    ]

    private let executable: URL
    private let configURL: URL
    private let authDirectory: URL
    /// Lets Quit end every running login. A set because Codex and Claude can sign in at once.
    private let signInPIDs: OSAllocatedUnfairLock<Set<Int32>>

    public init(executable: URL, configURL: URL, authDirectory: URL,
                signInPIDs: OSAllocatedUnfairLock<Set<Int32>> = .init(initialState: [])) {
        self.executable = executable
        self.configURL = configURL
        self.authDirectory = authDirectory
        self.signInPIDs = signInPIDs
    }

    /// Cancelling the consuming task, or dropping the stream, terminates the command.
    public func run(_ provider: BrainProvider) -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        let task = Task { await perform(provider, continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func perform(_ provider: BrainProvider, _ events: AsyncStream<Event>.Continuation) async {
        defer { events.finish() }
        let flag: String
        switch provider {
        case .codexSubscription: flag = "-codex-login"
        case .claudeSubscription: flag = "-claude-login"
        case .openAI:
            events.yield(.failed(message: "\(provider.displayName) has no sign-in"))
            return
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = [flag, "-no-browser", "-config", configURL.path]
        // After 15 s the command offers to read a pasted callback URL; end of input keeps it
        // waiting for the browser's redirect.
        process.standardInput = FileHandle.nullDevice
        // An inherited `PGSTORE_DSN` or `OBJECTSTORE_*` would decide where the credential lands.
        process.environment = LocalProxySupervisor.helperEnvironment()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let (exits, exited) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { finished in
            exited.yield(finished.terminationStatus)
            exited.finish()
        }
        do {
            try process.run()
        } catch {
            events.yield(.failed(message: "the sign-in service couldn't start: \(error.localizedDescription)"))
            return
        }
        // The child holds its own copy; closing ours is what lets the read below end at its exit.
        try? output.fileHandleForWriting.close()
        let pid = process.processIdentifier
        signInPIDs.withLock { $0.insert(pid) }
        defer { signInPIDs.withLock { $0.remove(pid) } }
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task {
            try? await Task.sleep(for: Self.deadline)
            guard !Task.isCancelled else { return }
            timedOut.withLock { $0 = true }
            kill(pid, SIGTERM)
        }
        defer { watchdog.cancel() }

        await withTaskCancellationHandler {
            var opened = false
            var lastLine = ""
            do {
                for try await line in output.fileHandleForReading.bytes.lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !opened, trimmed.hasPrefix("https://"), let url = URL(string: trimmed) {
                        guard Self.signInHosts.contains(url.host()?.lowercased() ?? "") else {
                            // Otherwise it times out without saying why no page opened.
                            kill(pid, SIGTERM)
                            events.yield(.failed(
                                message: "the sign-in service printed an address Jarvis won't open"))
                            return
                        }
                        opened = true
                        events.yield(.openURL(url))
                    } else if !trimmed.isEmpty {
                        lastLine = trimmed
                    }
                }
            } catch {
                // The pipe ends with the command; its exit status below says how.
            }
            var status: Int32 = -1
            for await code in exits { status = code }
            guard !Task.isCancelled else { return }
            if status == 0 {
                protectCredentials()
                events.yield(.finished(accountFiles: LocalProxyAccountFile.all(
                    in: authDirectory, for: provider)))
            } else if timedOut.withLock({ $0 }) {
                events.yield(.failed(message: "the sign-in didn't finish within 10 minutes"))
            } else {
                events.yield(.failed(message: lastLine.isEmpty
                    ? "the sign-in ended with exit status \(status)" : lastLine))
            }
        } onCancel: {
            kill(pid, SIGTERM)
        }
    }

    /// The helper picks its own file mode, but these hold tokens, so force owner-only.
    private func protectCredentials() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: authDirectory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for url in urls where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
