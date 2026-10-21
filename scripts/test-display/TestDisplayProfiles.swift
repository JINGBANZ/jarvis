import ColorSync
import Foundation

enum TestDisplayProfiles {
    static let directory = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Displays", isDirectory: true)

    static func serial(at url: URL) -> UInt32? {
        let name = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "icc", name.hasPrefix("Jarvis Tests-"),
              UUID(uuidString: String(name.dropFirst("Jarvis Tests-".count))) != nil,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let data = try? Data(contentsOf: url),
              let profile = ColorSyncProfileCreate(data as CFData, nil)?.takeRetainedValue(),
              let tag = ColorSyncProfileCopyTag(profile, "mmod" as CFString)?.takeRetainedValue() as Data?,
              tag.count >= 20, tag.prefix(8) == Data([0x6D, 0x6D, 0x6F, 0x64, 0, 0, 0, 0]) else { return nil }
        func word(_ offset: Int) -> UInt32 {
            tag[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard word(8) == TestDisplayIdentity.vendor, word(12) == TestDisplayIdentity.product else { return nil }
        return word(16)
    }

    static func cleanup(
        apply: Bool, directory: URL = directory,
        onlineSerials: () throws -> Set<UInt32> = TestDisplayIdentity.onlineSerials,
        processExists: (UInt32) -> Bool = { kill(pid_t($0), 0) == 0 || errno != ESRCH }
    ) throws -> [URL] {
        // Stable pool profiles are reusable cache entries. Only old PID identities need removal.
        _ = try onlineSerials()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var selected: [URL] = []
        for url in files.sorted(by: { $0.path < $1.path }) {
            guard let serial = serial(at: url), (1...99999).contains(serial),
                  !processExists(serial), !(try onlineSerials()).contains(serial) else { continue }
            if apply { try FileManager.default.removeItem(at: url) }
            selected.append(url)
        }
        return selected
    }
}
