import Foundation
import JarvisCore
import os
#if canImport(Darwin)
import Darwin
#endif

/// Signs the user in to one subscription through the bundled helper's own login command.
///
/// The command prints the OAuth page and waits for the provider's redirect on the helper's fixed
/// callback port (1455 for Codex, 54545 for Claude), then writes the credential into the auth
/// directory the running helper watches, which picks it up without a restart. Jarvis passes
/// `-no-browser` and opens the page itself, so the one browser open stays in Jarvis code behind
/// the user's Sign in click. In that mode the command also asks public IP services for this Mac's
/// address to print SSH tunnel hints, which Jarvis ignores.
public struct LocalProxySignIn: Sendable {
    public enum Event: Sendable, Equatable {
        /// The OAuth page to open; the caller opens it.
        case openURL(URL)
        case finished(accountFiles: [LocalProxyAccountFile])
        case failed(message: String)
    }

    private static let deadline: Duration = .seconds(10 * 60)

    private let executable: URL
    private let configURL: URL
    private let authDirectory: URL
    /// Where every running login publishes its process id, so Quit can end them from outside. Codex
    /// and Claude can be signing in at the same time, so this is a set rather than one slot.
    private let signInPIDs: OSAllocatedUnfairLock<Set<Int32>>

    public init(executable: URL, configURL: URL, authDirectory: URL,
                signInPIDs: OSAllocatedUnfairLock<Set<Int32>> = .init(initialState: [])) {
        self.executable = executable
        self.configURL = configURL
        self.authDirectory = authDirectory
        self.signInPIDs = signInPIDs
    }

    /// Runs the login for `provider`. Cancelling the consuming task, or dropping the stream,
    /// terminates the command.
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
        // After 15 seconds the command offers to read a pasted callback URL. End of input keeps it
        // waiting for the browser's redirect, which is the only path Jarvis uses.
        process.standardInput = FileHandle.nullDevice
        // The login inherits none of Jarvis's credentials, the rule every launcher here follows.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "GEMINI_API_KEY")
        process.environment = environment
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

    /// The helper writes credentials with its own mode; they hold tokens, so they get the API key
    /// file's owner-only mode.
    private func protectCredentials() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: authDirectory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for url in urls where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
