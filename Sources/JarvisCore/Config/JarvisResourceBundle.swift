import Foundation

public enum JarvisResourceBundle: String, Sendable {
    case core = "Jarvis_JarvisCore"
    case app = "Jarvis_JarvisApp"

    public func url(forResource name: String, in hostBundle: Bundle? = nil) -> URL? {
        // Swift Testing can load our code into an xctest bundle inside a separate host process.
        let host = hostBundle ?? Bundle(for: Anchor.self)
        var containers = [host.resourceURL, host.bundleURL].compactMap { $0 }
        if host.bundleURL.pathExtension == "app" {
            containers = [host.resourceURL].compactMap { $0 }
        } else if host.bundleURL.pathExtension == "xctest" {
            containers.append(host.bundleURL.deletingLastPathComponent())
        }
        for container in containers {
            let url = container.appendingPathComponent(rawValue + ".bundle")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let resources = Bundle(url: url)?.resourceURL else { return nil }
            let resource = resources.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: resource.path) ? resource : nil
        }
        return nil
    }

    private final class Anchor: NSObject {}
}
