import Foundation

/// Persisted list of local files/folders the user has pointed Jarvis at as interview prep material.
/// Backed by UserDefaults — the same per-macOS-account storage every other setting already uses, so
/// this data is inherently local to the signed-in user with no separate tenant/isolation concept
/// needed. Jarvis stores only the path, never a copy of the file's contents; it reads the live file
/// at Session Start. Mirrors `BrainPreferences.fallbackTargets`.
///
/// Foundation-only so it stays unit-testable in JarvisCore; inject a `UserDefaults(suiteName:)` in
/// tests.
public final class PrepMaterialPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every configured source, in the order the user added them. A malformed persisted entry (a
    /// hand-edited or stale plist) is dropped rather than crashing or surfacing a broken row.
    public var sources: [PrepMaterialSource] {
        get {
            guard let stored = defaults.array(forKey: Defaults.PrepMaterial.sourcesKey) else {
                return Defaults.PrepMaterial.sources
            }
            return stored.compactMap(persistedSource(from:))
        }
        set { persist(newValue) }
    }

    /// Adds one source, unless its path is already present.
    public func add(_ source: PrepMaterialSource) {
        var current = sources
        guard !current.contains(where: { $0.path == source.path }) else { return }
        current.append(source)
        persist(current)
    }

    /// Forgets one source. Never touches the underlying file — Jarvis only reads it.
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
