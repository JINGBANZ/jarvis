import CryptoKit
import Darwin
import Foundation

enum ReferenceSourceCapture {
    static let maximumSourceBytes = 25 * 1_024 * 1_024
    static let supportedFormats: Set<String> = ["txt", "md", "pdf", "docx"]

    static func statIdentity(url: URL, root: URL) throws -> String {
        let (descriptor, _) = try authorizedFile(url: url, root: root)
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ReferenceConversionError.unavailable }
        return identity(info)
    }

    static func statState(url: URL, root: URL) throws -> String {
        let (descriptor, _) = try authorizedFile(url: url, root: root)
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ReferenceConversionError.unavailable }
        return state(info)
    }

    static func validate(capture: CapturedReference, originalURL: URL, root: URL) throws {
        guard try statState(url: originalURL, root: root) == capture.sourceState else {
            throw ReferenceConversionError.sourceChanged
        }
    }

    static func capture(url: URL, root: URL, staging: URL, expectedIdentity: String? = nil) throws -> CapturedReference {
        let format = url.pathExtension.lowercased()
        guard supportedFormats.contains(format) else { throw ReferenceConversionError.unsupportedFormat }
        let (descriptor, resolved) = try authorizedFile(url: url, root: root)
        let source = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? source.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw ReferenceConversionError.unavailable }
        guard expectedIdentity == nil || expectedIdentity == identity(before) else { throw ReferenceConversionError.sourceChanged }
        guard before.st_size <= maximumSourceBytes else { throw ReferenceConversionError.limitExceeded }
        let snapshot = staging.appendingPathComponent(UUID().uuidString + ".snapshot")
        let destination = open(snapshot.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard destination >= 0 else { throw errno == ENOSPC ? ReferenceConversionError.diskFull : .unavailable }
        let output = FileHandle(fileDescriptor: destination, closeOnDealloc: true)
        var keep = false
        defer {
            try? output.close()
            if !keep { try? FileManager.default.removeItem(at: snapshot) }
        }
        var hasher = SHA256()
        var count = 0
        while true {
            try Task.checkCancellation()
            let piece = try source.read(upToCount: 65_536) ?? Data()
            if piece.isEmpty { break }
            guard piece.count <= maximumSourceBytes - count else { throw ReferenceConversionError.limitExceeded }
            count += piece.count
            hasher.update(data: piece)
            do { try output.write(contentsOf: piece) }
            catch { throw ReferenceConversionError.classify(error) }
        }
        var after = stat(), pathState = stat()
        guard fstat(descriptor, &after) == 0, lstat(resolved.path, &pathState) == 0,
              unchanged(before, after), unchanged(after, pathState), count == after.st_size,
              try canonicalURL(url) == resolved else {
            throw ReferenceConversionError.sourceChanged
        }
        do { try output.synchronize() }
        catch { throw ReferenceConversionError.classify(error) }
        keep = true
        return CapturedReference(snapshotURL: snapshot, sourceHash: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                                 format: format, sourceIdentity: identity(before), sourceState: state(before))
    }

    private static func authorizedFile(url: URL, root: URL) throws -> (Int32, URL) {
        let resolved = try canonicalURL(url)
        let allowed = try canonicalURL(root)
        guard allowed.standardizedFileURL.path == root.standardizedFileURL.path,
              resolved.pathComponents.starts(with: allowed.pathComponents) else { throw ReferenceConversionError.unavailable }
        // Open each directory without following links so a concurrent parent swap cannot escape the admitted root.
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw ReferenceConversionError.unavailable }
        defer { Darwin.close(directory) }
        let components = resolved.pathComponents.dropFirst()
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ReferenceConversionError.unavailable }
            Darwin.close(directory)
            directory = next
        }
        guard let name = components.last else { throw ReferenceConversionError.unavailable }
        let descriptor = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ReferenceConversionError.unavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw ReferenceConversionError.unavailable
        }
        return (descriptor, resolved)
    }

    private static func canonicalURL(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else { throw ReferenceConversionError.unavailable }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    private static func identity(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }

    private static func state(_ info: stat) -> String {
        "\(identity(info)):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    private static func unchanged(_ left: stat, _ right: stat) -> Bool {
        identity(left) == identity(right) && left.st_size == right.st_size
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
            && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
            && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
            && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }
}
