#if JARVIS_LIVE_E2E
import Foundation
import JarvisCore

extension ReferenceHarnessAppDelegate {
    func runRetrievalChecks(library: ReferenceLibrary, store: URL) async throws {
        let folder = output.appendingPathComponent("retrieval")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let original = "# Context\r\n\r\n" + String(repeating: "😀é background\r\n\r\n", count: 2_000) + "# Payments\r\n\r\nORCHID-439 C++ 支付失败 账单-42\r\n"
        let originalURL = folder.appendingPathComponent("Payment.md")
        try original.write(to: originalURL, atomically: true, encoding: .utf8)
        try "C# managed types 账单_42".write(to: folder.appendingPathComponent("managed.md"), atomically: true, encoding: .utf8)
        try await library.configure(enabled: true, sources: [ReferenceSource(id: UUID(), url: folder)])
        let access = try await admission(library)
        let list = try await access.session.list(query: nil, cursor: nil)
        let payment = try requireEntry(list, name: "Payment.md")
        let managed = try requireEntry(list, name: "managed.md")
        try await waitForSearch(access.session, count: 2, timeout: .seconds(10))
        let evidence = try await access.session.search(query: "ORCHID-439", documentIDs: nil)
        guard let hit = evidence.hits.first else { throw ReferenceProtocolError.malformed }
        let scalars = original.unicodeScalars
        let begin = scalars.index(scalars.startIndex, offsetBy: hit.offset)
        let end = scalars.index(scalars.startIndex, offsetBy: hit.nextOffset)
        try require(hit.documentID == payment && hit.offset > 16_000 && hit.text == String(scalars[begin..<end]), "original scalar excerpt beyond first page")
        try require(hit.name == "Payment.md" && hit.section == "# Payments", "display name and original section")
        results.append(["case": "search-original-offsets"])
        let plus = try await access.session.search(query: "C++", documentIDs: nil)
        let hash = try await access.session.search(query: "C#", documentIDs: nil)
        let chinese = try await access.session.search(query: "账单-42", documentIDs: nil)
        try require(plus.hits.allSatisfy { $0.documentID == payment } && !plus.hits.isEmpty
                    && hash.hits.allSatisfy { $0.documentID == managed } && !hash.hits.isEmpty
                    && chinese.hits.allSatisfy { $0.documentID == payment } && !chinese.hits.isEmpty, "multilingual identifier separation")
        results.append(["case": "search-multilingual-identifiers"])
        let denied = try await access.session.search(query: "ORCHID-439", documentIDs: [managed])
        try require(denied.hits.isEmpty && denied.coverage.eligibleDocuments == 1, "eligibility before top-K")
        results.append(["case": "search-session-filter"])
        try "replacement".write(to: originalURL, atomically: true, encoding: .utf8)
        let pinned = try await access.session.read(documentID: payment, offset: hit.offset, revisionID: hit.revisionID)
        try require(pinned.text.hasPrefix(hit.text), "first search pins text before later read")
        results.append(["case": "search-first-pin-read"])
        library.release(sessionID: access.sessionID)

        let scale = output.appendingPathComponent("search-scale")
        try FileManager.default.createDirectory(at: scale, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let common = String(repeating: "local reference background words and durable text.\n", count: 20)
        for index in 0..<10_000 {
            try (common + "\nscaleID-\(index)\n").write(to: scale.appendingPathComponent("document-\(index).txt"), atomically: true, encoding: .utf8)
        }
        let preparation = ContinuousClock.now
        try await library.configure(enabled: true, sources: [ReferenceSource(id: UUID(), url: scale)])
        let large = try await admission(library)
        try require(large.context.documentCatalog?.totalCount == 10_000, "complete 10k frozen membership")
        try await waitForSearch(large.session, count: 10_000, timeout: .seconds(280))
        let ready = preparation.duration(to: .now)
        results.append(["case": "search-10k-preparation", "elapsed": String(describing: ready), "documents": 10_000, "characters_per_document": common.count])
        var durations: [Double] = []
        for _ in 0..<20 {
            let started = ContinuousClock.now
            let found = try await large.session.search(query: "scaleID-9999", documentIDs: nil)
            let components = started.duration(to: .now).components
            durations.append(Double(components.seconds) + Double(components.attoseconds) / 1e18)
            try require(found.complete && found.coverage.searchedDocuments == 10_000 && found.hits.count == 1
                        && found.hits[0].name == "document-9999.txt" && found.hits[0].revisionID.count == 64,
                        "full-length revision keys and complete 10k retrieval")
        }
        durations.sort()
        results.append(["case": "search-10k-swift-ipc", "samples": durations.count,
                        "median_ms": durations[durations.count / 2] * 1_000, "p95_ms": durations[18] * 1_000,
                        "max_ms": durations.last! * 1_000])
        library.release(sessionID: large.sessionID)
    }

    private func waitForSearch(_ session: any DocumentSession, count: Int, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let status = try await session.search(query: "nevermatchesreadinessprobe", documentIDs: nil)
            if status.complete && status.coverage.searchedDocuments == count { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "ReferenceHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "complete search preparation deadline"])
    }
}
#endif
