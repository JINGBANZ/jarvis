import Testing
import Foundation
@testable import JarvisCore

@Suite struct ActivityHistoryExporterTests {
    private func session(id: String = "2026-06-16_10-00-00_aaaa") -> SessionStore.Session {
        SessionStore.Session(
            id: id, label: "2026-06-16 10:00:00",
            url: URL(fileURLWithPath: "/tmp/\(id)"), isCurrent: false, evidenceIsComplete: true)
    }

    @Test func markdownOmitsImagesWhenScreenshotsExcluded() {
        let entries: [(ActivityLog.Entry, Data?)] = [
            (ActivityLog.Entry(time: "10:00:00", message: "🗣 heard (them): hi", imageFile: nil), nil),
            (ActivityLog.Entry(time: "10:00:05", message: "👁 looking at your screen", imageFile: "shot-1.jpg"),
             Data([0xFF, 0xD8, 0xFF, 0xD9])),
        ]
        let export = ActivityHistoryExporter.export(
            session: session(), entries: entries, format: .markdown,
            includeScreenshots: false, jarvisResponsesOnly: false)
        #expect(export.filename == "activity.md")
        #expect(!export.text.contains("![screenshot]"))
        #expect(export.images.isEmpty)
    }

    @Test func markdownEmbedsScreenshotsAsRelativeLinksWhenIncluded() {
        let entries: [(ActivityLog.Entry, Data?)] = [
            (ActivityLog.Entry(time: "10:00:05", message: "👁 looking at your screen", imageFile: "shot-1.jpg"),
             Data([0xFF, 0xD8, 0xFF, 0xD9])),
        ]
        let export = ActivityHistoryExporter.export(
            session: session(), entries: entries, format: .markdown,
            includeScreenshots: true, jarvisResponsesOnly: false)
        #expect(export.text.contains("![screenshot](images/shot-1.jpg)"))
        #expect(export.images.count == 1)
        #expect(export.images[0].filename == "images/shot-1.jpg")
        #expect(export.images[0].data == Data([0xFF, 0xD8, 0xFF, 0xD9]))
    }

    @Test func plainTextReferencesScreenshotFilenameWithoutEmbedding() {
        let entries: [(ActivityLog.Entry, Data?)] = [
            (ActivityLog.Entry(time: "10:00:05", message: "👁 looking at your screen", imageFile: "shot-1.jpg"),
             Data([0xFF, 0xD8, 0xFF, 0xD9])),
        ]
        let export = ActivityHistoryExporter.export(
            session: session(), entries: entries, format: .plainText,
            includeScreenshots: true, jarvisResponsesOnly: false)
        #expect(export.filename == "activity.txt")
        #expect(export.text.contains("[screenshot: images/shot-1.jpg]"))
        #expect(!export.text.contains("!["))
        #expect(export.images.count == 1)
    }

    @Test func htmlInlinesScreenshotsAsBase64AndWritesNoSeparateImages() {
        let entries: [(ActivityLog.Entry, Data?)] = [
            (ActivityLog.Entry(time: "10:00:05", message: "👁 looking at your screen", imageFile: "shot-1.jpg"),
             Data([0xFF, 0xD8, 0xFF, 0xD9])),
        ]
        let export = ActivityHistoryExporter.export(
            session: session(), entries: entries, format: .html,
            includeScreenshots: true, jarvisResponsesOnly: false)
        #expect(export.filename == "activity.html")
        #expect(export.text.contains("data:image/jpeg;base64,"))
        #expect(export.images.isEmpty)
    }

    @Test func jarvisResponsesOnlyKeepsTipsAndScreenViewsButDropsHeardSpeechAndSystemRows() {
        let entries: [(ActivityLog.Entry, Data?)] = [
            (ActivityLog.Entry(time: "10:00:00", message: "🗣 heard (them): hi", imageFile: nil), nil),
            (ActivityLog.Entry(time: "10:00:01", message: "👁 looking at your screen", imageFile: "shot-1.jpg"),
             Data([0xFF, 0xD8, 0xFF, 0xD9])),
            (ActivityLog.Entry(time: "10:00:02", message: "💬 try rephrasing that", imageFile: nil), nil),
            (ActivityLog.Entry(time: "10:00:03", message: "⏹ session ended by user", imageFile: nil), nil),
        ]
        let export = ActivityHistoryExporter.export(
            session: session(), entries: entries, format: .plainText,
            includeScreenshots: false, jarvisResponsesOnly: true)
        #expect(export.text.contains("looking at your screen"))
        #expect(export.text.contains("try rephrasing that"))
        #expect(!export.text.contains("heard (them)"))
        #expect(!export.text.contains("session ended"))
    }

    /// The two toggles are independent: "Jarvis responses only" only decides which rows survive;
    /// "Include screenshots" only decides whether a surviving row's own image is exported. Since a
    /// screen-view row is itself one of Jarvis's own actions, its screenshot comes along for free
    /// with no cross-referencing between the two options.
    @Test func jarvisResponsesOnlyExportsScreenshotsFromKeptScreenViewRowsWhenIncluded() {
        let entries: [(ActivityLog.Entry, Data?)] = [
            (ActivityLog.Entry(time: "10:00:00", message: "🗣 heard (them): hi", imageFile: nil), nil),
            (ActivityLog.Entry(time: "10:00:01", message: "👁 looking at your screen", imageFile: "shot-1.jpg"),
             Data([0xFF, 0xD8, 0xFF, 0xD9])),
        ]
        let export = ActivityHistoryExporter.export(
            session: session(), entries: entries, format: .markdown,
            includeScreenshots: true, jarvisResponsesOnly: true)
        #expect(export.text.contains("![screenshot](images/shot-1.jpg)"))
        #expect(export.images.count == 1)
        #expect(export.images[0].filename == "images/shot-1.jpg")
    }

    @Test func jarvisResponsesOnlyOmitsScreenViewImageWhenScreenshotsExcluded() {
        let entries: [(ActivityLog.Entry, Data?)] = [
            (ActivityLog.Entry(time: "10:00:00", message: "👁 looking at your screen", imageFile: "shot-1.jpg"),
             Data([0xFF, 0xD8, 0xFF, 0xD9])),
        ]
        let export = ActivityHistoryExporter.export(
            session: session(), entries: entries, format: .markdown,
            includeScreenshots: false, jarvisResponsesOnly: true)
        #expect(!export.text.contains("![screenshot]"))
        #expect(export.images.isEmpty)
    }

    @Test func emptyEntriesStillProduceHeaderOnlyDocument() {
        let export = ActivityHistoryExporter.export(
            session: session(), entries: [], format: .markdown,
            includeScreenshots: false, jarvisResponsesOnly: false)
        #expect(export.text.contains("2026-06-16 10:00:00"))
    }

    @Test func jarvisResponsesOnlyFilteringToZeroStillProducesHeaderOnlyDocument() {
        let entries: [(ActivityLog.Entry, Data?)] = [
            (ActivityLog.Entry(time: "10:00:00", message: "🗣 heard (them): hi", imageFile: nil), nil),
        ]
        let export = ActivityHistoryExporter.export(
            session: session(), entries: entries, format: .markdown,
            includeScreenshots: false, jarvisResponsesOnly: true)
        #expect(export.text.contains("2026-06-16 10:00:00"))
        #expect(!export.text.contains("heard (them)"))
    }
}
