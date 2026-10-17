import Foundation

final class ReferenceTextOutput {
    static let maximumBytes = 100 * 1_024 * 1_024
    private let handle: FileHandle
    let directory: URL
    private(set) var bytes = 0

    init(url: URL) throws {
        directory = url.deletingLastPathComponent()
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw errno == ENOSPC ? ReferenceConversionError.diskFull : .unavailable }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func append(_ text: String) throws {
        let data = Data(text.utf8)
        guard data.count <= Self.maximumBytes - bytes else { throw ReferenceConversionError.limitExceeded }
        try handle.write(contentsOf: data)
        bytes += data.count
    }

    func finish() throws { try handle.close() }
}
