import CoreServices
import Foundation
import JarvisCore

@MainActor
final class ReferenceSourceWatcher {
    private final class Context {
        let receive: @MainActor ([String], [FSEventStreamEventFlags]) -> Void
        init(receive: @escaping @MainActor ([String], [FSEventStreamEventFlags]) -> Void) { self.receive = receive }
    }
    private final class NativeStream {
        let value: FSEventStreamRef
        init(_ value: FSEventStreamRef) { self.value = value }
        deinit {
            FSEventStreamStop(value)
            FSEventStreamInvalidate(value)
            FSEventStreamRelease(value)
        }
    }
    private var stream: NativeStream?
    private var generation = UUID()
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func watch(_ sources: [ReferenceSourceSelection], excluding: [URL] = []) {
        stop()
        guard !sources.isEmpty else { return }
        let paths = Set(sources.map {
            $0.isDirectory ? $0.path : URL(fileURLWithPath: $0.path).deletingLastPathComponent().path
        }).sorted()
        let watched = generation
        let owner = Context { [weak self] paths, flags in
            guard let self, self.generation == watched else { return }
            let excluded = excluding.map(\.path)
            let mustRescan = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
            let structural = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved)
            if zip(paths, flags).contains(where: { path, flag in
                flag & mustRescan != 0 || ReferenceSourceChange.affects(path,
                    directory: flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0,
                    structural: flag & structural != 0, sources: sources, excluding: excluded)
            }) { self.onChange() }
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(owner).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Context>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            }, release: { info in
                if let info { Unmanaged<Context>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let strings = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let values = (0..<count).map { String(cString: strings[$0]) }
            let eventFlags = Array(UnsafeBufferPointer(start: flags, count: count))
            // FSEvents delivers only on the explicitly selected main queue; its context retains this closure.
            MainActor.assumeIsolated {
                Unmanaged<Context>.fromOpaque(info).takeUnretainedValue().receive(values, eventFlags)
            }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents)) else { return }
        self.stream = NativeStream(stream)
        FSEventStreamSetDispatchQueue(stream, .main)
        if !FSEventStreamStart(stream) { stop() }
    }

    func stop() {
        generation = UUID()
        stream = nil
    }
}
