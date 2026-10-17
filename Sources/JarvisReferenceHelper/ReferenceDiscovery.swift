import Foundation

struct ReferenceDiscovery: Sendable {
    struct Source: Codable, Sendable, Equatable { let source_id: UUID; let path: String }
    struct Document: Sendable {
        let path: String
        let root: String
        let identity: String
        let format: String
        let name: String
        var sourceIDs: Set<UUID>
    }

    static func identity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ReferenceStoreError.invalid_source }
        return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }
    static func contains(_ url: URL, root: URL) -> Bool { url.pathComponents.starts(with: root.pathComponents) }
    static func scan(_ sources: [Source]) throws -> [Document] {
        let files = FileManager.default
        var found: [String: Document] = [:]
        for source in sources {
            try Task.checkCancellation()
            let root = URL(fileURLWithPath: source.path).resolvingSymlinksInPath().standardizedFileURL
            var directory: ObjCBool = false
            guard files.fileExists(atPath: root.path, isDirectory: &directory) else { throw ReferenceStoreError.invalid_source }
            var candidates: [URL] = []
            if directory.boolValue {
                var enumerationFailed = false
                guard let enumerator = files.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                    errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw ReferenceStoreError.unavailable }
                for case let url as URL in enumerator {
                    try Task.checkCancellation()
                    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                    guard contains(resolved, root: root) else { throw ReferenceStoreError.invalid_source }
                    if ["txt", "md", "pdf", "docx"].contains(resolved.pathExtension.lowercased()) {
                        guard candidates.count < 100_000 else { throw ReferenceStoreError.resource_limit }
                        if (try resolved.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true { candidates.append(resolved) }
                    }
                }
                guard !enumerationFailed else { throw ReferenceStoreError.unavailable }
            } else {
                guard ["txt", "md", "pdf", "docx"].contains(root.pathExtension.lowercased()) else { throw ReferenceStoreError.unsupported_format }
                candidates = [root]
            }
            for url in candidates {
                try Task.checkCancellation()
                let key = url.path
                if var previous = found[key] {
                    previous.sourceIDs.insert(source.source_id)
                    // A directory grant also authorizes a reliably identified rename inside it.
                    if root.pathComponents.count < URL(fileURLWithPath: previous.root).pathComponents.count {
                        previous = Document(path: key, root: root.path, identity: previous.identity, format: previous.format,
                                            name: previous.name, sourceIDs: previous.sourceIDs)
                    }
                    found[key] = previous
                } else {
                    let name = url.lastPathComponent.unicodeScalars.map { scalar -> String in
                        if CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == "\\" { return " " }
                        return String(scalar)
                    }.joined()
                    found[key] = Document(path: key, root: root.path, identity: try identity(url),
                                          format: url.pathExtension.lowercased(), name: name, sourceIDs: [source.source_id])
                }
                guard found.count <= 100_000 else { throw ReferenceStoreError.resource_limit }
            }
        }
        return found.values.sorted { $0.path < $1.path }
    }
}
