import Foundation
import JarvisCore
import PDFKit

enum PrepMaterialIndexBuilder {
    private static let supportedExtensions: Set<String> = ["txt", "md", "pdf", "docx"]
    /// Folder sources are unbounded, so cap concurrent PDFKit parses and `textutil` subprocesses.
    private static let maxConcurrentExtractions = 8

    /// Skips files that fail to extract. Nil when nothing yielded text, so no port is installed.
    /// Extraction blocks, so it runs on detached tasks off the cooperative executor.
    static func build(from sources: [PrepMaterialSource]) async -> PrepMaterialIndex? {
        let files = sources.flatMap(expand)
        guard !files.isEmpty else { return nil }

        var chunks: [PrepMaterialChunk] = []
        for batchStart in stride(from: 0, to: files.count, by: maxConcurrentExtractions) {
            // Detached tasks ignore cancellation, so check before each batch to stop after a Stop.
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

    /// Folders yield regular files only, so a package bundle named like a document is skipped.
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
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // PDFPage.string has no blank-line breaks, so otherwise a page is one unsplittable chunk.
        return normalizeLinesToParagraphs(text)
    }

    private static func extractDocxText(from url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        // Never an undrained Pipe: a full stderr pipe deadlocks against readDataToEndOfFile below.
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
        // textutil also separates paragraphs with a single newline.
        return normalizeLinesToParagraphs(text)
    }

    /// Makes each line a paragraph, since `PrepMaterialChunker` splits on blank lines. A wrapped
    /// paragraph may fragment, because plain text can't tell a line break from a paragraph break.
    private static func normalizeLinesToParagraphs(_ text: String) -> String {
        text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
