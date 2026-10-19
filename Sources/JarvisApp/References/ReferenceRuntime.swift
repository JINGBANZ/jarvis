import Foundation
import JarvisCore

@MainActor
final class ReferenceRuntime {
    let library: ReferenceLibrary
    private let supervisor: ReferenceHelperSupervisor
    private var enabled = false
    private var disabledTools: Set<String> = []
    private var sources: [ReferenceSourceSelection] = []
    private lazy var watcher = ReferenceSourceWatcher { [weak self] in self?.reconcile() }

    init(home: URL? = nil) {
        let bundle = Bundle.main.bundleURL
        let development = Bundle.main.infoDictionary?["JarvisDevelopmentBuild"] as? Bool == true
        let root = home ?? (development
            ? bundle.deletingLastPathComponent().appendingPathComponent(".jarvis/references", isDirectory: true)
            : FileSecretStore().directoryURL.appendingPathComponent("references", isDirectory: true))
        supervisor = ReferenceHelperSupervisor(bundle: bundle.appendingPathComponent("Contents/Resources/ReferenceHelper"), home: root)
        library = ReferenceLibrary(supervisor: supervisor)
    }

    #if JARVIS_LIVE_E2E
    var processIdentifier: Int32? { supervisor.processIdentifier }
    #endif

    func configure(preferences: BrainPreferences, sources: ReferencePreferences) {
        let disabled = preferences.disabledTools
        configure(enabled: !disabled.contains(searchReferencesTool.name), sources: sources.sources, disabledTools: disabled)
    }

    func configure(enabled: Bool, sources: [ReferenceSourceSelection], disabledTools: Set<String> = []) {
        self.disabledTools = disabledTools
        self.enabled = enabled
        self.sources = sources
        watcher.watch(enabled ? sources : [], excluding: [supervisor.homeURL])
        reconcile()
    }

    func reconcile() {
        library.prepare(enabled: enabled, sources: sources.map {
            ReferenceSource(id: $0.id, url: URL(fileURLWithPath: $0.path))
        }, disabledTools: disabledTools)
    }

    func stop() async {
        watcher.stop()
        library.shutdown()
        await supervisor.stop()
    }
}
