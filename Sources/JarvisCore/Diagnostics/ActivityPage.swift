import Foundation

package struct ActivityPage<Navigation: AnyObject> {
    package enum Source: Equatable {
        case current(UUID)
        case history
    }

    private struct Loading {
        let navigation: Navigation
        var scripts: [String]
    }

    private let source: Source
    private var loading: Loading?

    package init(
        source: Source, navigation: Navigation, rows: [String], total: Int,
        evidenceIsComplete: Bool
    ) {
        self.source = source
        var scripts = rows
        scripts.append(ActivityLog.summaryScript(shown: rows.count, total: total))
        scripts.append(ActivityLog.evidenceScript(isComplete: evidenceIsComplete))
        loading = Loading(navigation: navigation, scripts: scripts)
    }

    package var isReady: Bool { loading == nil }

    package var isCurrent: Bool {
        if case .current = source { return true }
        return false
    }

    package mutating func append(_ script: String, from subscription: UUID) -> String? {
        guard source == .current(subscription) else { return nil }
        if loading != nil {
            loading?.scripts.append(script)
            return nil
        }
        return script
    }

    package mutating func finish(_ navigation: Navigation) -> [String]? {
        guard let loading, loading.navigation === navigation else { return nil }
        self.loading = nil
        return loading.scripts
    }
}
