import AppKit

@main
@MainActor
final class TestDisplayRunner {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { await run() }
        NSApplication.shared.run()
    }

    private static func run() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw TestDisplay.Failure("Supervisor worker only") }
            let descriptor = try JSONDecoder().decode(TestDisplayDescriptor.self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let original = NSScreen.screens.map { (id: id($0), frame: $0.frame) }
            let main = CGMainDisplayID()
            let before = try onlineDisplays()
            guard !original.isEmpty, before.allSatisfy({
                CGDisplayVendorNumber($0) != descriptor.vendor || CGDisplayModelNumber($0) != descriptor.product
            }) else { throw TestDisplay.Failure("Desktop unavailable or an unowned Jarvis display is online") }
            let display = try TestDisplay(descriptor)
            // AppKit needs to process the display-change notification. All calls are bounded
            // by the external supervisor; a same-thread timeout cannot interrupt WindowServer.
            try await Task.sleep(for: .seconds(1))
            let created = NSScreen.screens
            guard let screen = created.first(where: { id($0) == display.id }),
                  CGMainDisplayID() == main, CGDisplayIsInMirrorSet(display.id) == 0,
                  original.allSatisfy({ old in
                      created.first(where: { id($0) == old.id })?.frame == old.frame
                          && !old.frame.intersects(screen.frame)
                  }),
                  created.filter({ id($0) != display.id }).allSatisfy({ !$0.frame.intersects(screen.frame) }),
                  let uuid = CGDisplayCreateUUIDFromDisplayID(display.id)?.takeRetainedValue()
            else { throw TestDisplay.Failure("Display isolation changed the desktop; command not started") }
            let persistent = CFUUIDCreateString(nil, uuid) as String
            reply(["display": display.id, "uuid": persistent,
                   "expected_profile": "/Library/ColorSync/Profiles/Displays/Jarvis Tests-\(persistent).icc"])
            let input = await Task.detached { readLine() }.value
            guard input == "stop" else { throw TestDisplay.Failure("Supervisor disappeared; unfinished run") }
            let removed = display.id
            display.close()
            try await Task.sleep(for: .seconds(1))
            let after = try onlineDisplays()
            let restored = NSScreen.screens
            guard !after.contains(removed), Set(after) == Set(before), CGMainDisplayID() == main,
                  original.allSatisfy({ old in restored.first(where: { id($0) == old.id })?.frame == old.frame })
            else { throw TestDisplay.Failure("Display teardown/layout could not be verified") }
            reply(["stopped": true])
            exit(0)
        } catch {
            reply(["error": String(describing: error)])
            exit(70)
        }
    }

    private static func id(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private static func onlineDisplays() throws -> [CGDirectDisplayID] {
        // One bounded-capacity snapshot per phase, never one query per profile/candidate.
        var values = [CGDirectDisplayID](repeating: 0, count: 128)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(values.count), &values, &count) == .success,
              count > 0, count < values.count else { throw TestDisplay.Failure("Online-display snapshot failed") }
        return Array(values.prefix(Int(count)))
    }

    private static func reply(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { exit(70) }
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
