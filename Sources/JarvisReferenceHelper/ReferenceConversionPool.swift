import Darwin
import Foundation
import JarvisProcess

actor ReferenceConversionPool {
    static let processorVersion = ReferenceConversionWorker.processorVersion
    static let maximumWorkers = 2
    // Sampling makes this a termination threshold, not a hard allocation ceiling.
    static let maximumResidentBytes: UInt64 = 256 * 1_024 * 1_024
    static let wallTime: Duration = .seconds(15)
    static let monitoringInterval: Duration = .milliseconds(20)
    private let staging: URL
    private var workers: [UUID: Process] = [:]
    private var closed = false
    private var activeSlots = 0
    private var foregroundWaiting = 0
    #if JARVIS_LIVE_E2E
    private var peakResidentBytes: UInt64 = 0
    private var peakWorkerCount = 0
    #endif

    private let launcher: any ProcessLaunching

    init(staging: URL, launcher: any ProcessLaunching = NativeProcessLauncher()) {
        self.staging = staging
        self.launcher = launcher
    }

    func convert(snapshotURL: URL, format: String) async throws -> String {
        let foreground = Task.currentPriority >= .medium
        if foreground { foregroundWaiting += 1 }
        do {
            while activeSlots >= Self.maximumWorkers || (!foreground && foregroundWaiting > 0) {
                try Task.checkCancellation()
                guard !closed else { throw ReferenceConversionError.unavailable }
                try await Task.sleep(for: Self.monitoringInterval)
            }
            try Task.checkCancellation()
            guard !closed else { throw ReferenceConversionError.unavailable }
        } catch {
            if foreground { foregroundWaiting -= 1 }
            throw error
        }
        if foreground { foregroundWaiting -= 1 }
        activeSlots += 1
        defer { activeSlots -= 1 }
        if format == "txt" || format == "md" {
            let decoding = Task.detached { try Self.readPlainText(snapshotURL) }
            let text = try await withTaskCancellationHandler {
                try await decoding.value
            } onCancel: { decoding.cancel() }
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            return text
        }
        let id = UUID()
        let directory = staging.appendingPathComponent(id.uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw ReferenceConversionError.classify(error) }
        let output = directory.appendingPathComponent("text")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--worker", snapshotURL.path, format, output.path]
        process.currentDirectoryURL = directory
        process.environment = ["LANG": "en_US.UTF-8", "HOME": directory.path, "TMPDIR": directory.path, "PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        workers[id] = process
        #if JARVIS_LIVE_E2E
        peakWorkerCount = max(peakWorkerCount, workers.count)
        #endif
        defer {
            workers.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            try launcher.launch(process)
            let deadline = ContinuousClock.now + Self.wallTime
            while process.isRunning {
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                guard ContinuousClock.now < deadline else { throw ReferenceConversionError.conversionTimeout }
                guard let bytes = Self.residentBytes(process.processIdentifier) else {
                    if !process.isRunning { break }
                    throw ReferenceConversionError.resourceLimit
                }
                #if JARVIS_LIVE_E2E
                peakResidentBytes = max(peakResidentBytes, bytes)
                #endif
                guard bytes <= Self.maximumResidentBytes else { throw ReferenceConversionError.resourceLimit }
                try await Task.sleep(for: Self.monitoringInterval)
            }
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw ReferenceConversionError(exitStatus: process.terminationStatus)
            }
            let text = try await Task.detached {
                let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
                guard let bytes = attributes[.size] as? NSNumber, bytes.intValue <= ReferenceTextOutput.maximumBytes else {
                    throw ReferenceConversionError.limitExceeded
                }
                guard let text = String(data: try Data(contentsOf: output), encoding: .utf8) else {
                    throw ReferenceConversionError.invalidDocument
                }
                return text
            }.value
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            return text
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            while process.isRunning { await Self.waitAfterTermination() }
            throw error
        }
    }

    func close() async {
        closed = true
        for process in workers.values where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        while activeSlots > 0 { await Self.waitAfterTermination() }
    }

    #if JARVIS_LIVE_E2E
    func metrics() -> [String: UInt64] {
        ["peak_rss_bytes": peakResidentBytes, "rss_limit_bytes": Self.maximumResidentBytes,
         "peak_workers": UInt64(peakWorkerCount), "remaining_workers": UInt64(workers.count),
         "poll_interval_ms": 20, "foreground_waiters": UInt64(foregroundWaiting)]
    }
    #endif

    private static func readPlainText(_ url: URL) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ReferenceConversionError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ReferenceConversionError.unavailable
        }
        guard info.st_size <= ReferenceSourceCapture.maximumSourceBytes else { throw ReferenceConversionError.limitExceeded }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let piece = try handle.read(upToCount: 65_536) ?? Data()
            if piece.isEmpty { break }
            guard piece.count <= ReferenceSourceCapture.maximumSourceBytes - data.count else {
                throw ReferenceConversionError.limitExceeded
            }
            data.append(piece)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ReferenceConversionError.invalidDocument }
        return text
    }

    private static func waitAfterTermination() async {
        await Task.detached { try? await Task.sleep(for: Self.monitoringInterval) }.value
    }

    private static func residentBytes(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? info.ri_resident_size : nil
    }
}
