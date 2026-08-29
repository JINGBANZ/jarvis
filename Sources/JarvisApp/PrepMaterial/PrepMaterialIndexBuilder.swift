import Foundation
import JarvisCore
import PDFKit

/// Reads the user's configured prep-material sources and builds a `PrepMaterialIndex` from whatever
/// text extracts successfully.
///
/// Lives in JarvisApp, not JarvisCore: it touches the filesystem and shells out to `textutil`, both
/// banned from the Foundation-only coaching kernel by `scripts/check-coaching-kernel.sh`. Mirrors how
/// `WindowScopedScreenCapture` sits behind `ScreenCapturing` — Core owns the port and the pure
/// chunking/ranking logic, the macOS edge owns reading files and per-format extraction.
enum PrepMaterialIndexBuilder {
    private static let supportedExtensions: Set<String> = ["txt", "md", "pdf", "docx"]
    /// Caps how many files extract concurrently. A folder source can expand to an unbounded file
    /// count; without a cap, one large folder would spawn that many simultaneous PDFKit parses and
    /// `textutil` subprocesses from an unattended Session-Start background path.
    private static let maxConcurrentExtractions = 8

    /// Builds an index from every configured source, skipping whatever fails to extract — a corrupt
    /// PDF or an unreadable file never blocks the rest. Returns nil when nothing produced usable
    /// text, so the caller can leave `search_prep_notes` out of the tool set entirely rather than
    /// install an index with zero chunks.
    ///
    /// Each file's extraction runs on its own detached task — the same "OS-bound synchronous edge,
    /// so run it off the cooperative executor" reasoning `CoachDriver.captureScreen` already applies
    /// to its own blocking subprocess call.
    static func build(from sources: [PrepMaterialSource]) async -> PrepMaterialIndex? {
        let files = sources.flatMap(expand)
        guard !files.isEmpty else { return nil }

        var chunks: [PrepMaterialChunk] = []
        for batchStart in stride(from: 0, to: files.count, by: maxConcurrentExtractions) {
            // A detached task isn't linked to its caller's cancellation, so once dispatched it runs
            // to completion regardless — but checking here before dispatching a batch means a Stop
            // that lands mid-build stops adding new file reads/subprocesses rather than working
            // through the whole remaining list.
            guard !Task.isCancelled else { break }
            let batch = files[batchStart..<min(batchStart + maxConcurrentExtractions, files.count)]
            let extractions = batch.map { file in
                Task.detached(priority: .utility) { () -> [PrepMaterialChunk] in
                    guard let text = extractText(from: file) else { return [] }
                    return PrepMaterialChunker.chunk(text: text, sourceDisplayName: file.lastPathComponent)
                }
            }
            for extraction in extractions {
                chunks.append(contentsOf: await extraction.value)
            }
        }

        guard !chunks.isEmpty else { return nil }
        return PrepMaterialIndex(chunks: chunks)
    }

    /// A file source expands to itself (if its extension is supported); a folder expands to every
    /// supported *regular file* inside it, recursively — a directory or package bundle whose name
    /// happens to end in a supported extension is skipped rather than handed to `extractText`.
    private static func expand(_ source: PrepMaterialSource) -> [URL] {
        let url = URL(fileURLWithPath: source.path)
        guard source.isDirectory else {
            return supportedExtensions.contains(url.pathExtension.lowercased()) ? [url] : []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
    }

    private static func extractText(from url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "txt", "md":
            return try? String(contentsOf: url, encoding: .utf8)
        case "pdf":
            return extractPDFText(from: url)
        case "docx":
            return extractDocxText(from: url)
        default:
            return nil
        }
    }

    private static func extractPDFText(from url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// `textutil` is a stock macOS CLI — no dependency, no network — that converts Word documents to
    /// plain text. Same "borrow the OS tool" pattern as `screencapture`.
    private static func extractDocxText(from url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        // Never a Pipe() nobody drains: textutil blocking on a full stderr pipe while this thread
        // blocks on stdout's readDataToEndOfFile() is a classic Process deadlock. Same reason
        // SyntheticSpeechFixtures.swift routes its own subprocess's stderr to the null device.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        // textutil separates paragraphs with a single newline, not the blank-line convention
        // PrepMaterialChunker splits on — left as-is, the whole document would extract as one
        // oversized chunk. Treat each non-empty line as its own paragraph instead.
        //
        // Known imprecision: plain-text conversion loses the distinction between a real paragraph
        // break and a manual line break inside one paragraph (e.g. pasted text), so this can
        // occasionally fragment one paragraph into several chunks. Bounded impact — worse retrieval
        // granularity for that source, not data loss — and not worth chasing without richer input
        // (e.g. an HTML conversion that keeps paragraph tags) than plain text can carry.
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
