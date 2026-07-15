import Foundation
import JarvisCore
import Network

/// Records whether macOS considers the local network path usable and which interface carries it.
/// Realtime transport errors include this snapshot, separating a local route outage from an
/// apparently-healthy path whose connection was lost farther upstream.
// SAFETY: `summary` is the only cross-queue mutable state and every access is guarded by `lock`.
// `NWPathMonitor` invokes its handler on `queue`, so actor isolation cannot express this ownership.
final class NetworkPathDiagnostics: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "jarvis.network-path")
    private let lock = NSLock()
    private var summary = "not observed yet"

    var currentSummary: String {
        lock.lock(); defer { lock.unlock() }
        return summary
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let next = Self.describe(path)
            self.lock.lock()
            let changed = next != self.summary
            self.summary = next
            self.lock.unlock()
            if changed { jlog("Jarvis network path: \(next)") }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    private static func describe(_ path: NWPath) -> String {
        let status: String = switch path.status {
        case .satisfied: "satisfied"
        case .requiresConnection: "requires connection"
        case .unsatisfied: "unsatisfied"
        @unknown default: "unknown"
        }
        let interfaces = [
            (NWInterface.InterfaceType.wifi, "wifi"),
            (.wiredEthernet, "ethernet"),
            (.cellular, "cellular"),
            (.loopback, "loopback"),
            (.other, "other"),
        ].compactMap { path.usesInterfaceType($0.0) ? $0.1 : nil }
        let route = interfaces.isEmpty ? "no active interface" : interfaces.joined(separator: "+")
        return "\(status), \(route), expensive=\(path.isExpensive), constrained=\(path.isConstrained)"
    }
}
