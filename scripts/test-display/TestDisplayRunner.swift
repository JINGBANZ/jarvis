import AppKit

@main
@MainActor
final class TestDisplayRunner {
    private static var retainedDisplay: TestDisplay?

    static func main() {
        // Losing the controller's pipe must not terminate the shared display owner.
        signal(SIGPIPE, SIG_IGN)
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { await run() }
        NSApplication.shared.run()
    }

    private static func run() async {
        do {
            let inspect = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--inspect"
            guard CommandLine.arguments.count == 2 || inspect else { throw TestDisplay.Failure("Supervisor worker only") }
            let descriptor = try JSONDecoder().decode(TestDisplayDescriptor.self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let original = try layout()
            let existing = original.screens.filter {
                CGDisplayVendorNumber($0.id) == descriptor.vendor && $0.model == descriptor.product
            }
            guard existing.count <= 1 else { throw TestDisplay.Failure("Multiple Jarvis displays are online; explicit recovery required") }
            let target: CGDirectDisplayID
            let admitted: TestDisplayLayout
            if let screen = existing.first {
                target = screen.id
                admitted = original
            } else {
                guard !inspect else { throw TestDisplay.Failure("Test display is absent") }
                let display = try TestDisplay(descriptor)
                retainedDisplay = display
                try display.configure(descriptor)
                // AppKit must process the display-change notification before clients can use it.
                // The external supervisor bounds synchronous WindowServer calls.
                try await Task.sleep(for: .seconds(1))
                admitted = try layout()
                target = display.id
                guard original.accepts(admitted, display: target) else {
                    let mode = original.isHeadless ? "headless" : "physical-desktop"
                    throw TestDisplay.Failure("Test display violated \(mode) layout; main display \(original.main) -> \(admitted.main); command not started")
                }
            }
            try validate(target, descriptor: descriptor, layout: admitted)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(target)?.takeRetainedValue() else {
                throw TestDisplay.Failure("Test display has no persistent identity; command not started")
            }
            let persistent = CFUUIDCreateString(nil, uuid) as String
            reply(["display": target, "uuid": persistent, "retained": retainedDisplay != nil,
                   "expected_profile": "/Library/ColorSync/Profiles/Displays/Jarvis Tests-\(persistent).icc"])
            if inspect { exit(0) }
            let input = await Task.detached { readLine() }.value
            if input == nil, retainedDisplay != nil { return }
            guard input == "finish" else { throw TestDisplay.Failure("Supervisor disappeared; unfinished run") }
            let after = try layout()
            try validate(target, descriptor: descriptor, layout: after)
            guard admitted.matches(after) else { throw TestDisplay.Failure("Display layout changed during tests") }
            reply(["finished": true])
            if retainedDisplay == nil { exit(0) }
        } catch {
            reply(["error": String(describing: error), "retained": retainedDisplay != nil])
            if retainedDisplay == nil { exit(70) }
        }
    }

    private static func validate(_ target: CGDirectDisplayID, descriptor: TestDisplayDescriptor,
                                 layout: TestDisplayLayout) throws {
        let scale: UInt32 = descriptor.hiDPI == 0 ? 1 : 2
        guard CGDisplaySerialNumber(target) == descriptor.serial,
              let mode = CGDisplayCopyDisplayMode(target),
              mode.pixelWidth == Int(descriptor.width * scale),
              mode.pixelHeight == Int(descriptor.height * scale),
              layout.usable(display: target, width: descriptor.width, height: descriptor.height),
              NSScreen.screens.contains(where: { id($0) == target }) else {
            throw TestDisplay.Failure("Existing test display identity, size, or isolation is invalid; command not started")
        }
    }

    private static func id(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private static func layout() throws -> TestDisplayLayout {
        // One bounded-capacity snapshot per phase, never one query per profile/candidate.
        var values = [CGDirectDisplayID](repeating: 0, count: 128)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(values.count), &values, &count) == .success,
              count < values.count else { throw TestDisplay.Failure("Online-display snapshot failed") }
        let screens = values.prefix(Int(count)).map { id in
            TestDisplayLayout.Screen(id: id, model: CGDisplayModelNumber(id), frame: CGDisplayBounds(id),
                                     mirrored: CGDisplayIsInMirrorSet(id) != 0)
        }
        return TestDisplayLayout(screens: screens, main: CGMainDisplayID())
    }

    private static func reply(_ value: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        } catch {
            FileHandle.standardError.write(Data("Display controller reply failed: \(error)\n".utf8))
            if retainedDisplay == nil { exit(70) }
        }
    }
}
