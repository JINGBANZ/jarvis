import AppKit
import ColorSync

@main
struct TestDisplayContracts {
    static func main() {
        do { try run() } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--hold" {
            let identity = try TestDisplayIdentity.reserve(
                excluding: [], directory: URL(fileURLWithPath: arguments[1]))
            print("READY \(identity.serial)")
            fflush(stdout)
            withExtendedLifetime(identity) { while getppid() != 1 { usleep(100_000) } }
        } else if arguments == ["--snapshot"] {
            var count: UInt32 = 0
            precondition(CGGetOnlineDisplayList(0, nil, &count) == .success && count > 0)
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count) + 16)
            precondition(CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success)
            let displays = ids.prefix(Int(count)).map { id -> [String: Any] in
                let frame = CGDisplayBounds(id)
                return ["id": id, "vendor": CGDisplayVendorNumber(id), "product": CGDisplayModelNumber(id),
                        "serial": CGDisplaySerialNumber(id), "main": id == CGMainDisplayID(),
                        "frame": [frame.origin.x, frame.origin.y, frame.width, frame.height]]
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: displays), as: UTF8.self))
        } else if arguments == ["--child"] {
            print("READY \(ProcessInfo.processInfo.environment["JARVIS_TEST_DISPLAY_ID"] ?? "missing")")
            fflush(stdout)
            while getppid() != 1 { usleep(100_000) }
        } else {
            try contracts()
            print("Test-display identity and profile contracts passed")
        }
    }

    static func contracts() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("jarvis-display-contracts-\(UUID())")
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }
        let locks = root.appendingPathComponent("locks")
        var leases = try (0..<4).map { _ in try TestDisplayIdentity.reserve(excluding: [], directory: locks) }
        precondition(Set(leases.map(\.serial)) == Set(TestDisplayIdentity.serials))
        expectFailure { _ = try TestDisplayIdentity.reserve(excluding: [], directory: locks) }
        let first = leases.removeFirst().serial
        let reused = try TestDisplayIdentity.reserve(excluding: [], directory: locks)
        precondition(reused.serial == first)
        leases.removeAll()
        let alternate = try TestDisplayIdentity.reserve(excluding: [first], directory: locks)
        precondition(alternate.serial != first)
        withExtendedLifetime((reused, alternate)) {}

        let unsafe = root.appendingPathComponent("unsafe")
        try files.createDirectory(at: unsafe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o777])
        try files.setAttributes([.posixPermissions: 0o777], ofItemAtPath: unsafe.path)
        expectFailure { _ = try TestDisplayIdentity.reserve(excluding: [], directory: unsafe) }
        let linked = root.appendingPathComponent("linked")
        try files.createSymbolicLink(at: linked, withDestinationURL: locks)
        expectFailure { _ = try TestDisplayIdentity.reserve(excluding: [], directory: linked) }

        let profiles = root.appendingPathComponent("profiles")
        try files.createDirectory(at: profiles, withIntermediateDirectories: false)
        func fixture(serial: UInt32, vendor: UInt32 = TestDisplayIdentity.vendor,
                     product: UInt32 = TestDisplayIdentity.product, name: String = "Jarvis Tests",
                     truncated: Bool = false) throws -> URL {
            let profile = ColorSyncProfileCreateMutableCopy(
                ColorSyncProfileCreateWithName("com.apple.ColorSync.sRGB" as CFString)!.takeRetainedValue())!.takeRetainedValue()
            let words: [UInt32] = [0x6D6D6F64, 0, vendor, product, serial, 0, 0, 0, 0, 0]
            let tag = Data(words.flatMap { value in (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } })
            ColorSyncProfileSetTag(profile, "mmod" as CFString, (truncated ? tag.prefix(12) : tag) as CFData)
            let data = ColorSyncProfileCopyData(profile, nil).takeRetainedValue() as Data
            let url = profiles.appendingPathComponent("\(name)-\(UUID()).icc")
            try data.write(to: url)
            return url
        }
        let dead = try fixture(serial: 90001)
        let active = try fixture(serial: 90002)
        let alive = try fixture(serial: 90003)
        let stable = try fixture(serial: TestDisplayIdentity.serials[0])
        let physical = try fixture(serial: 90004, vendor: 0x610)
        let unrelated = try fixture(serial: 90005, product: 0x1234)
        let renamed = try fixture(serial: 90006, name: "Other display")
        let malformed = try fixture(serial: 90007, truncated: true)
        let link = profiles.appendingPathComponent("Jarvis Tests-\(UUID()).icc")
        try files.createSymbolicLink(at: link, withDestinationURL: dead)
        let invalid = profiles.appendingPathComponent("Jarvis Tests-\(UUID()).icc")
        try Data("invalid ICC".utf8).write(to: invalid)
        let protected = Set([active, alive, stable, physical, unrelated, renamed, malformed, link, invalid].map(\.lastPathComponent))
        let before = Set(try files.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil))
        let preview = try TestDisplayProfiles.cleanup(
            apply: false, directory: profiles, onlineSerials: { [90002] }, processExists: { $0 == 90003 })
        precondition(preview.map(\.lastPathComponent) == [dead.lastPathComponent])
        let afterPreview = Set(try files.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil))
        precondition(afterPreview == before)
        expectFailure {
            _ = try TestDisplayProfiles.cleanup(apply: true, directory: profiles, onlineSerials: {
                throw TestDisplay.Failure("unavailable desktop")
            })
        }
        precondition(files.fileExists(atPath: dead.path))
        let removed = try TestDisplayProfiles.cleanup(
            apply: true, directory: profiles, onlineSerials: { [90002] }, processExists: { $0 == 90003 })
        precondition(removed.map(\.lastPathComponent) == [dead.lastPathComponent])
        let remaining = Set(try files.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil).map(\.lastPathComponent))
        precondition(remaining == protected)
    }

    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation() } catch { return }
        preconditionFailure("Expected the operation to fail closed")
    }
}
