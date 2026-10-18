import Foundation

public enum ReferenceSourceChange {
    public static func affects(_ path: String, directory: Bool, structural: Bool,
                               sources: [PrepMaterialSource], excluding: [String]) -> Bool {
        let changed = URL(fileURLWithPath: path).standardizedFileURL
        func contains(_ root: String) -> Bool {
            changed.pathComponents.starts(with: URL(fileURLWithPath: root).standardizedFileURL.pathComponents)
        }
        guard !excluding.contains(where: contains) else { return false }
        return sources.contains { source in
            if !source.isDirectory { return changed.path == URL(fileURLWithPath: source.path).standardizedFileURL.path }
            guard contains(source.path) else { return false }
            return directory ? structural : ["txt", "md", "pdf", "docx"].contains(changed.pathExtension.lowercased())
        }
    }
}
