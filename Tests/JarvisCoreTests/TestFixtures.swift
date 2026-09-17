import Foundation
@testable import JarvisCore

enum TestFixtures {
    /// A real 4x4 JPEG, so tests exercise valid image bytes rather than arbitrary base64.
    static let tinyJpegBase64 =
        "/9j/4AAQSkZJRgABAQAASABIAAD/4QDIRXhpZgAATU0AKgAAAAgABgEGAAMAAAABAAIAAAESAAMAAAABAAEAAAEaAAUAAAABAAAAVgEbAAUAAAABAAAAXgEoAAMAAAABAAIAAIdpAAQAAAABAAAAZgAAAAAAAABIAAAAAQAAAEgAAAABAAeQAAAHAAAABDAyMjGRAQAHAAAABAECAwCgAAAHAAAABDAxMDCgAQADAAAAAQABAACgAgAEAAAAAQAAAASgAwAEAAAAAQAAAASkBgADAAAAAQAAAAAAAAAA/8AAEQgABAAEAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A+LfjT4+1Xwl40/sqwtbSeM2sMpaeLc+5wc/dKjHpxXkv/C5fEX/QP07/AL8N/wDF10X7SX/JSB/14238jXgNe7UzjF8z/fS/8Cf+Z8DhMtw7pQbpx2XRdj//2Q=="

    static var tinyJpeg: Data { Data(base64Encoded: tinyJpegBase64)! }
}

extension FileSessionAudit {
    /// Waits for the asynchronous open so records under test follow it, as in production.
    static func readyForTesting(directory: URL) async -> FileSessionAudit {
        let audit = FileSessionAudit(
            directory: directory,
            worker: SessionAuditWorker(
                limits: .production,
                writer: SessionAuditFileWriter()))
        let marker = directory.appendingPathComponent(FileSessionAudit.healthFilename)
        while !FileManager.default.fileExists(atPath: marker.path) {
            await Task.yield()
        }
        return audit
    }

    func closeForTesting() async -> SessionAuditCloseResult {
        await close()
    }

    func recordForTesting(
        file: URL,
        expectedLineCount: Int,
        _ record: () -> Void
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        record()
        while ContinuousClock.now < deadline {
            let lineCount = (try? String(contentsOf: file, encoding: .utf8))?
                .split(separator: "\n").count ?? 0
            if lineCount >= expectedLineCount { return true }
            await Task.yield()
        }
        return false
    }
}
