import Foundation
@testable import JarvisCore

/// Shared test fixtures.
enum TestFixtures {
    /// A real, tiny (4×4) baseline JPEG, base64-encoded — the kind of payload `ScreenCapturing`
    /// returns. Used by the screenshot end-to-end tests so they exercise genuine image bytes
    /// (valid SOI/EOI markers) rather than arbitrary base64, proving the capture round-trips to the
    /// activity log without corruption.
    static let tinyJpegBase64 =
        "/9j/4AAQSkZJRgABAQAASABIAAD/4QDIRXhpZgAATU0AKgAAAAgABgEGAAMAAAABAAIAAAESAAMAAAABAAEAAAEaAAUAAAABAAAAVgEbAAUAAAABAAAAXgEoAAMAAAABAAIAAIdpAAQAAAABAAAAZgAAAAAAAABIAAAAAQAAAEgAAAABAAeQAAAHAAAABDAyMjGRAQAHAAAABAECAwCgAAAHAAAABDAxMDCgAQADAAAAAQABAACgAgAEAAAAAQAAAASgAwAEAAAAAQAAAASkBgADAAAAAQAAAAAAAAAA/8AAEQgABAAEAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A+LfjT4+1Xwl40/sqwtbSeM2sMpaeLc+5wc/dKjHpxXkv/C5fEX/QP07/AL8N/wDF10X7SX/JSB/14238jXgNe7UzjF8z/fS/8Cf+Z8DhMtw7pQbpx2XRdj//2Q=="

    /// Decoded bytes of `tinyJpegBase64`.
    static var tinyJpeg: Data { Data(base64Encoded: tinyJpegBase64)! }
}

extension FileSessionAudit {
    /// Persistence tests get an isolated worker. Wait for its asynchronous open before sending the
    /// record under test so the assertion observes the same ordered lifecycle as production.
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

    /// Persistence assertions await the real asynchronous lifecycle.
    func closeForTesting() async -> SessionAuditCloseResult {
        await close()
    }

    /// Submit once, then wait for the worker to persist the accepted event.
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
