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

        let extractions = files.map { file in
            Task.detached(priority: .utility) { () -> [PrepMaterialChunk] in
                guard let text = extractText(from: file) else { return [] }
                return PrepMaterialChunker.chunk(text: text, sourceDisplayName: file.lastPathComponent)
            }
        }

        var chunks: [PrepMaterialChunk] = []
        for extraction in extractions {
            chunks.append(contentsOf: await extraction.value)
        }

        guard !chunks.isEmpty else { return nil }
        return PrepMaterialIndex(chunks: chunks)
    }

    /// A file source expands to itself (if its extension is supported); a folder expands to every
    /// supported file inside it, recursively.
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
        process.standardError = Pipe()
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
        return text
    }
}
