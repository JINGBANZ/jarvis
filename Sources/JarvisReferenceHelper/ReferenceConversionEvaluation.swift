#if JARVIS_LIVE_E2E
import Foundation
import JarvisProcess

enum ReferenceConversionEvaluation {
    static func run(arguments: [String], launcher: any ProcessLaunching) async -> Int32 {
        guard arguments.count == 3 else { return 64 }
        let staging = URL(fileURLWithPath: arguments[2], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let pool = ReferenceConversionPool(staging: staging, launcher: launcher)
            let start = ContinuousClock.now
            var status = "ok"
            var textBytes = 0
            var cancellationCount = 0
            var queuedObserved = false
            do {
                let snapshot = URL(fileURLWithPath: arguments[0])
                if arguments[1] == "__test_concurrency" {
                    let cancelled = await withTaskGroup(of: Bool.self) { group in
                        for _ in 0..<3 {
                            group.addTask(priority: .userInitiated) {
                                do { _ = try await pool.convert(snapshotURL: snapshot, format: "__test_hang"); return false }
                                catch is CancellationError { return true }
                                catch { return false }
                            }
                        }
                        let readyDeadline = ContinuousClock.now + .seconds(2)
                        while ContinuousClock.now < readyDeadline {
                            let metrics = await pool.metrics()
                            if metrics["peak_workers"] == 2, (metrics["foreground_waiters"] ?? 0) >= 1 {
                                queuedObserved = true
                                break
                            }
                            try? await Task.sleep(for: .milliseconds(20))
                        }
                        group.cancelAll()
                        var count = 0
                        for await cancelled in group { if cancelled { count += 1 } }
                        return count
                    }
                    let peakWorkers = await pool.metrics()["peak_workers"]
                    cancellationCount = cancelled
                    if cancelled != 3 || peakWorkers != 2 || !queuedObserved { status = "failed" }
                } else {
                    textBytes = try await pool.convert(snapshotURL: snapshot, format: arguments[1]).utf8.count
                }
            } catch let error as ReferenceConversionError { status = error.rawValue }
            catch { status = "unavailable" }
            await pool.close()
            var result: [String: Any] = await pool.metrics().mapValues { $0 as Any }
            let elapsed = start.duration(to: .now).components
            result["elapsed_ms"] = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            result["status"] = status
            result["text_bytes"] = textBytes
            result["cancelled_jobs"] = cancellationCount
            result["queued_job_observed"] = queuedObserved
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
            FileHandle.standardOutput.write(Data([10]))
            return 0
        } catch { return 2 }
    }
}
#endif
