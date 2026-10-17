import Foundation
import SQLite3

final class ReferenceQueryBudget {
    let deadline: ContinuousClock.Instant
    init(deadline: ContinuousClock.Instant) { self.deadline = deadline }

    func install(on database: ReferenceDatabase) {
        sqlite3_progress_handler(database.handle, 1_000, { context in
            guard let context else { return 1 }
            let budget = Unmanaged<ReferenceQueryBudget>.fromOpaque(context).takeUnretainedValue()
            return ContinuousClock.now >= budget.deadline || Task.isCancelled ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    func remove(from database: ReferenceDatabase) { sqlite3_progress_handler(database.handle, 0, nil, nil) }
}
