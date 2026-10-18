import Foundation
import os

final class ReferenceStorageBudget: Sendable {
    // Reservation changes and a bounded SQLite batch must share one synchronous capacity check.
    private let reservations = OSAllocatedUnfairLock(initialState: Set<UUID>())

    var reservedBytes: Int64 { reservations.withLock { Int64($0.count) * ReferenceDocumentStore.reservationBytes } }

    func reserve(_ token: UUID, home: URL, diskBytes: () -> Int64, cleanup: () throws -> Void) throws {
        // Caller-owned actor/SQLite closures run synchronously here and never escape the lock.
        try reservations.withLockUnchecked { active in
            guard active.count < 2 else { throw ReferenceStoreError.preparing }
            let required = Int64(active.count + 1) * ReferenceDocumentStore.reservationBytes
            if diskBytes() + required > ReferenceDocumentStore.cacheTarget { try cleanup() }
            try Self.check(home: home, allocated: diskBytes(), required: required)
            active.insert(token)
        }
    }

    func release(_ token: UUID) { _ = reservations.withLock { $0.remove(token) } }

    func write(home: URL, bytes: Int, _ body: () throws -> Void) throws {
        // The writer's connection stays on its own lane; this synchronous closure never escapes.
        try reservations.withLockUnchecked { active in
            var allocated: Int64 = 0
            if let files = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) {
                for case var url as URL in files {
                    #if JARVIS_LIVE_E2E
                    if url.lastPathComponent == "budget-test-entry", FileManager.default.fileExists(atPath: home.appendingPathComponent("budget-test-disappearance").path) {
                        try FileManager.default.removeItem(at: url)
                        url.removeAllCachedResourceValues()
                    }
                    #endif
                    do {
                        let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
                        if values.isRegularFile == true { allocated += Int64(values.totalFileAllocatedSize ?? 0) }
                    } catch {
                        let failure = error as NSError
                        // Preparation can remove its snapshot after enumeration, outside this lock.
                        if failure.domain == NSCocoaErrorDomain,
                           failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError { continue }
                        if failure.domain == NSPOSIXErrorDomain, failure.code == Int(ENOENT) { continue }
                        throw error
                    }
                }
            }
            let required = Int64(active.count) * ReferenceDocumentStore.reservationBytes + Int64(bytes) * 8 + 1_048_576
            try Self.check(home: home, allocated: allocated, required: required)
            try body()
        }
    }

    private static func check(home: URL, allocated: Int64, required: Int64) throws {
        guard allocated + required <= ReferenceDocumentStore.cacheTarget else { throw ReferenceStoreError.cache_full }
        var volume = statfs()
        guard statfs(home.path, &volume) == 0,
              UInt64(volume.f_bavail) * UInt64(volume.f_bsize) >= UInt64(required) else { throw ReferenceStoreError.disk_full }
    }
}
