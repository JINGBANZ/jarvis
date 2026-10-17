import Foundation

extension ReferenceDocumentStore {
    struct SourceLocation: Sendable {
        let url: URL
        let root: URL
        let identity: String?
    }

    func sourceLocation(document: String, session: String?) throws -> SourceLocation {
        let row: [String?]?
        if let session {
            row = try db.rows("SELECT path,root,identity FROM session_documents WHERE session_id=? AND document_id=?", [session, document]).first
        } else {
            row = try db.rows("SELECT path,root,identity FROM metadata WHERE generation=(SELECT generation FROM configuration WHERE id=1 AND state='ready') AND document_id=?", [document]).first
        }
        guard let row, let path = row[0], let root = row[1], let identity = row[2] else { throw ReferenceStoreError.unknown_document }
        var url = URL(fileURLWithPath: path)
        var boundary = URL(fileURLWithPath: root)
        var expected: String? = identity
        if let current = try db.rows("SELECT path,identity FROM documents WHERE id=? AND present=1", [document]).first,
           let currentPath = current[0], current[1] != nil {
            if currentPath == path {
                expected = nil
            } else {
                let candidate = URL(fileURLWithPath: currentPath)
                if path == root { boundary = candidate }
                guard ReferenceDiscovery.contains(candidate, root: boundary) else { throw ReferenceStoreError.source_changed }
                url = candidate
                expected = nil
            }
        }
        if try db.scalar("SELECT id FROM documents WHERE path=? AND present=1 AND id<>? LIMIT 1", [url.path, document]) != nil {
            throw ReferenceStoreError.source_changed
        }
        return SourceLocation(url: url, root: boundary, identity: expected)
    }

    func prepare(document: String, session: String?, waiter: UUID, background: Bool) async throws -> String {
        let source = try sourceLocation(document: document, session: session)
        let stateTask = Task.detached(priority: background ? .utility : .userInitiated) {
            try ReferenceSourceCapture.statState(url: source.url, root: source.root)
        }
        let state = try await withTaskCancellationHandler { try await stateTask.value } onCancel: { stateTask.cancel() }
        try Task.checkCancellation()
        if let session, try db.scalar("SELECT state FROM sessions WHERE id=?", [session]) != "active" { throw ReferenceStoreError.unknown_session }
        if let existing = jobs[document] {
            guard existing.sourceState == state else { throw ReferenceStoreError.preparing }
        } else {
            let enabled = try db.scalar("SELECT enabled FROM configuration WHERE id=1 AND state='ready'") == "1"
            let currentMember = try db.scalar("SELECT document_id FROM metadata WHERE document_id=? AND generation=(SELECT generation FROM configuration WHERE id=1)", [document]) != nil
            let token = UUID()
            try reserve(token)
            let task = Task { await self.performPreparation(document: document, source: source, state: state, token: token) }
            let retained = background || (enabled && currentMember)
            jobs[document] = Preparation(token: token, task: task, background: retained, waiters: [:], sourceState: state)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard jobs[document] != nil else { continuation.resume(throwing: ReferenceStoreError.unavailable); return }
                jobs[document]?.waiters[waiter] = continuation
                if let session { waiterSessions[waiter] = session }
                if !background {
                    waiterTimers[waiter] = Task {
                        do { try await Task.sleep(for: .milliseconds(1500)) }
                        catch { return }
                        self.detachWaiter(waiter, error: ReferenceStoreError.preparing)
                    }
                }
            }
        } onCancel: { Task { await self.detachWaiter(waiter, error: CancellationError()) } }
    }

    func performPreparation(document: String, source: SourceLocation, state: String, token: UUID) async {
        var snapshot: URL?
        var revision: String?
        var result: Result<String, Error>
        do {
            #if JARVIS_LIVE_E2E
            await ReferenceSearchIndex.barrier(home: home, name: "preparation-after-reserve")
            #endif
            try Task.checkCancellation()
            let staging = self.staging
            let captureTask = Task.detached(priority: .utility) {
                try ReferenceSourceCapture.capture(url: source.url, root: source.root, staging: staging, expectedIdentity: source.identity)
            }
            let captured = try await withTaskCancellationHandler { try await captureTask.value } onCancel: { captureTask.cancel() }
            snapshot = captured.snapshotURL
            guard captured.sourceState == state else { throw ReferenceStoreError.source_changed }
            try Task.checkCancellation()
            let identifier = hash(Data((document + "\n" + captured.sourceHash + "\n" + ReferenceConversionPool.processorVersion).utf8))
            revision = identifier
            if try db.scalar("SELECT ready FROM revisions WHERE id=?", [identifier]) != "1" {
                let text = try await converters.convert(snapshotURL: captured.snapshotURL, format: captured.format)
                try Task.checkCancellation()
                let path = databasePath
                let writer = Task.detached(priority: .utility) {
                    try ReferenceRevisionWriter.write(databasePath: path, revision: identifier, document: document, sourceHash: captured.sourceHash, text: text)
                }
                try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
            }
            let validation = Task.detached(priority: .utility) {
                try ReferenceSourceCapture.validate(capture: captured, originalURL: source.url, root: source.root)
            }
            try await withTaskCancellationHandler { try await validation.value } onCancel: { validation.cancel() }
            try Task.checkCancellation()
            guard !closed, jobs[document]?.token == token else { throw CancellationError() }
            try db.transaction {
                try db.execute("INSERT INTO revision_sources VALUES(?,?) ON CONFLICT(revision_id) DO UPDATE SET source_state=excluded.source_state", [identifier, captured.sourceState])
                try db.execute("UPDATE revisions SET ready=1,last_used=strftime('%s','now') WHERE id=?", [identifier])
                try db.execute("UPDATE documents SET current_revision=?,identity=? WHERE id=? AND path=? AND present=1", [identifier, captured.sourceIdentity, document, source.url.path])
            }
            revisionCaptures[identifier] = (captured, source.url, source.root)
            result = .success(identifier)
        } catch {
            if let revision {
                try? db.transaction {
                    try db.execute("DELETE FROM content_parts WHERE revision_id=? AND revision_id IN (SELECT id FROM revisions WHERE ready=0)", [revision])
                    try db.execute("DELETE FROM revisions WHERE id=? AND ready=0", [revision])
                }
            }
            result = .failure(error)
        }
        if let snapshot { try? FileManager.default.removeItem(at: snapshot) }
        storageBudget.release(token)
        if case .success(let identifier) = result {
            do {
                try enqueueIndex(identifier)
                #if JARVIS_LIVE_E2E
                if FileManager.default.fileExists(atPath: home.appendingPathComponent("preparation-after-index-enqueue").path) {
                    await ReferenceSearchIndex.barrier(home: home, name: "preparation-after-index-enqueue")
                }
                #endif
            } catch { result = .failure(error) }
        }
        guard let job = jobs[document], job.token == token else { return }
        jobs.removeValue(forKey: document)
        for (waiter, continuation) in job.waiters {
            waiterSessions.removeValue(forKey: waiter)
            waiterTimers.removeValue(forKey: waiter)?.cancel()
            continuation.resume(with: result)
        }
    }

    func detachWaiter(_ waiter: UUID, error: Error) {
        for document in Array(jobs.keys) {
            guard let continuation = jobs[document]?.waiters.removeValue(forKey: waiter) else { continue }
            waiterSessions.removeValue(forKey: waiter)
            waiterTimers.removeValue(forKey: waiter)?.cancel()
            continuation.resume(throwing: error)
            cancelUnneeded(document)
            return
        }
    }
    func cancelUnneeded(_ document: String) {
        guard let job = jobs[document], job.waiters.isEmpty, !job.background else { return }
        if (try? db.scalar("SELECT document_id FROM session_documents WHERE document_id=? AND pin IS NULL LIMIT 1", [document])) != nil { return }
        job.task.cancel()
    }
}
