import AppKit

@main
@MainActor
final class TestDisplayRunner {
    private var signalSources: [any DispatchSourceSignal] = []
    private var interrupted: (signal: Int32, deadline: Date)?

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let runner = TestDisplayRunner()
        Task { await runner.run() }
        // AppKit must process display-change events to refresh NSScreen's cached list.
        NSApplication.shared.run()
    }

    private func run() async {
        let command = Array(CommandLine.arguments.dropFirst())
        guard command.first == "--", command.count > 1 else {
            fail("usage: test-display -- command [arguments]")
        }
        let originalScreens = NSScreen.screens.map { (id: displayID($0), frame: $0.frame) }
        let mainDisplay = CGMainDisplayID()
        guard !originalScreens.isEmpty else {
            fail("No macOS desktop is accessible. Run tests from a logged-in desktop with WindowServer access.")
        }
        do {
            let display = try TestDisplay()
            defer { display.close() }
            var screen: NSScreen?
            for _ in 0..<100 {
                screen = NSScreen.screens.first { displayID($0) == display.id }
                if screen != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let screen,
                  CGMainDisplayID() == mainDisplay,
                  CGDisplayIsInMirrorSet(display.id) == 0,
                  originalScreens.allSatisfy({ original in
                      NSScreen.screens.first(where: { displayID($0) == original.id })?.frame == original.frame
                          && !original.frame.intersects(screen.frame)
                  }) else {
                throw TestDisplay.Failure("Could not isolate the test display without changing the desktop. No tests started.")
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = Array(command.dropFirst())
            var environment = ProcessInfo.processInfo.environment
            environment["JARVIS_TEST_DISPLAY_ID"] = String(display.id)
            process.environment = environment
            try process.run()
            // Foundation starts a separate process group on macOS. Keep the display alive
            // until that group's script has handled cancellation, including live-app teardown.
            for number in [SIGINT, SIGTERM, SIGHUP] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { [weak self] in
                    self?.interrupt(process, signal: number)
                }
                source.resume()
                signalSources.append(source)
            }
            FileHandle.standardOutput.write(Data("▶ test windows isolated on Jarvis Tests (display \(display.id))\n".utf8))
            while process.isRunning {
                if CGDisplayIsOnline(display.id) == 0 {
                    interrupt(process, signal: SIGTERM)
                }
                if let interrupted, Date() >= interrupted.deadline {
                    kill(-process.processIdentifier, SIGKILL)
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            // Any subprocess left behind by the command must not outlive its display.
            kill(-process.processIdentifier, SIGKILL)
            let status = interrupted.map { 128 + $0.signal }
                ?? (process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus)
            display.close()
            exit(status)
        } catch {
            fail("Test display: \(error)")
        }
    }

    private func interrupt(_ process: Process, signal number: Int32) {
        guard interrupted == nil else { return }
        interrupted = (number, Date().addingTimeInterval(15))
        kill(-process.processIdentifier, number)
    }

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
