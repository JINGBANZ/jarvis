import CoreGraphics
import Foundation

final class TestDisplayIdentity {
    static let vendor: UInt32 = 0x4A56
    static let product: UInt32 = 0x5453
    static let serials: [UInt32] = (1...4).map { 0x4A560000 + $0 }
    static var lockDirectory: URL {
        URL(fileURLWithPath: "/private/tmp/jarvis-test-display-\(getuid())", isDirectory: true)
    }

    let serial: UInt32
    private let file: Int32

    private init(serial: UInt32, file: Int32) {
        self.serial = serial
        self.file = file
    }

    deinit { Darwin.close(file) }

    static func reserve(excluding: Set<UInt32>, directory: URL = lockDirectory) throws -> TestDisplayIdentity {
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            throw TestDisplay.Failure("Could not create the test-display identity directory: \(String(cString: strerror(errno)))")
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw TestDisplay.Failure("The test-display identity directory must be private and owned by this user.")
        }
        for serial in serials where !excluding.contains(serial) {
            let path = directory.appendingPathComponent("\(serial).lock").path
            // Keep lock files in place: unlinking a locked inode lets another helper reserve the same serial.
            let file = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw TestDisplay.Failure("Could not open a test-display identity lock.") }
            guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
                Darwin.close(file)
                throw TestDisplay.Failure("Unsafe test-display identity lock.")
            }
            if flock(file, LOCK_EX | LOCK_NB) == 0 {
                return TestDisplayIdentity(serial: serial, file: file)
            }
            let busy = errno == EWOULDBLOCK
            Darwin.close(file)
            guard busy else { throw TestDisplay.Failure("Could not reserve a test-display identity.") }
        }
        throw TestDisplay.Failure("All four test-display identities are busy. No tests started; retry after another run finishes.")
    }

    static func onlineSerials() throws -> Set<UInt32> {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            throw TestDisplay.Failure("Could not inspect online displays. Run from a logged-in macOS desktop.")
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count) + 16)
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success,
              count < displays.count else {
            throw TestDisplay.Failure("Could not inspect online displays.")
        }
        return Set(displays.prefix(Int(count)).filter {
            CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == product
        }.map { CGDisplaySerialNumber($0) })
    }
}
