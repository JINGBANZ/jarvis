import Foundation

enum TranscriptionBenchmarkFiles {
    static func prepareOutputDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path)
    }

    static func write(_ data: Data, named name: String, to directory: URL) throws {
        let directory = directory.standardizedFileURL
        let url = directory.appendingPathComponent(name).standardizedFileURL
        guard !name.isEmpty,
              url.deletingLastPathComponent() == directory,
              url.lastPathComponent == name else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let temporary = directory.appendingPathComponent(
            ".\(name).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func writeText(_ text: String, named name: String, to directory: URL) throws {
        try write(Data(text.utf8), named: name, to: directory)
    }

    static func writeFailure(_ message: String, to directory: URL) {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "status": "failed",
            "error": message,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]) else { return }
        try? prepareOutputDirectory(directory)
        try? write(data, named: "benchmark-error.json", to: directory)
    }

    static func writeProgress(
        phase: String,
        model: String? = nil,
        detail: String? = nil,
        to directory: URL
    ) {
        var object: [String: Any] = ["phase": phase]
        if let model { object["model"] = model }
        if let detail { object["detail"] = detail }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]) else { return }
        try? write(data, named: "progress.json", to: directory)
    }

    static func createMarker(named name: String, in directory: URL) throws {
        try write(Data(), named: name, to: directory)
    }
}
