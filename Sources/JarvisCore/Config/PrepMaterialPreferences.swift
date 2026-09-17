import Foundation

/// Stores only paths, never a copy of the files' contents.
public final class PrepMaterialPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var sources: [PrepMaterialSource] {
        get {
            guard let stored = defaults.array(forKey: Defaults.PrepMaterial.sourcesKey) else {
                return Defaults.PrepMaterial.sources
            }
            return stored.compactMap(persistedSource(from:))
        }
        set { persist(newValue) }
    }

    public func add(_ source: PrepMaterialSource) {
        add([source])
    }

    /// Skips any source whose path is already present, including duplicates within the batch.
    public func add(_ newSources: [PrepMaterialSource]) {
        guard !newSources.isEmpty else { return }
        var current = sources
        var seenPaths = Set(current.map(\.path))
        for source in newSources where seenPaths.insert(source.path).inserted {
            current.append(source)
        }
        persist(current)
    }

    public func remove(id: UUID) {
        persist(sources.filter { $0.id != id })
    }

    private func persistedSource(from value: Any) -> PrepMaterialSource? {
        guard let dictionary = value as? [String: Any],
              let idString = dictionary["id"] as? String,
              let id = UUID(uuidString: idString),
              let path = dictionary["path"] as? String,
              let isDirectory = dictionary["isDirectory"] as? Bool else {
            return nil
        }
        return PrepMaterialSource(id: id, path: path, isDirectory: isDirectory)
    }

    private func persist(_ sources: [PrepMaterialSource]) {
        defaults.set(sources.map {
            ["id": $0.id.uuidString, "path": $0.path, "isDirectory": $0.isDirectory]
        }, forKey: Defaults.PrepMaterial.sourcesKey)
    }
}
