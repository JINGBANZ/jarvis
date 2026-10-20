#if JARVIS_LIVE_E2E
import Foundation
import JarvisCore

extension ReferenceHarnessAppDelegate {
    func runAccessChecks(real: ReferenceHelperSupervisor, fixture: URL, store: URL,
                         startup: Duration, idleRSS: Int) async throws {
        let gate = store.appendingPathComponent("index-before-publish")
        try "hold".write(to: gate, atomically: true, encoding: .utf8)
        let library = ReferenceLibrary(supervisor: real)
        let source = ReferenceSource(id: UUID(), url: fixture, isDirectory: true)
        try await library.configure(enabled: true, sources: [source])
        let admitted = try await admission(library)
        let list = try await admitted.session.list(query: nil, cursor: nil)
        try require(list.entries.count == 1, "complete metadata admission")
        let document = list.entries[0].documentID
        let read = try await admitted.session.read(documentID: document, offset: 0, revisionID: nil)
        try require(read.text.contains("Uniquequasar") && !read.searchReady, "read before own index readiness")
        let originalContext = admitted.context.serialized
        let partial = try await admitted.session.search(query: "uniquequasar", documentIDs: nil)
        try require(!partial.complete && partial.hits.isEmpty && partial.coverage.searchedDocuments == 0, "staged index is ineligible while text remains readable")
        try FileManager.default.removeItem(at: gate)
        var search = try await admitted.session.search(query: "uniquequasar", documentIDs: nil)
        let indexDeadline = ContinuousClock.now + .seconds(5)
        while !search.complete, ContinuousClock.now < indexDeadline {
            try await Task.sleep(for: .milliseconds(20))
            search = try await admitted.session.search(query: "uniquequasar", documentIDs: nil)
        }
        try require(search.complete && search.coverage.searchedDocuments == 1, "complete typed search coverage")
        results.append(["case": "read-independent-of-index"])
        try require(search.hits.contains(where: { $0.documentID == document }), "native FTS over authoritative revision")
        results.append(["case": "real-read-search", "startup": String(describing: startup), "idle_rss_kib": idleRSS])

        let searchDelay = store.appendingPathComponent("search-reply-delay-ms")
        try "2200".write(to: searchDelay, atomically: true, encoding: .utf8)
        let searchStarted = ContinuousClock.now
        let delayed = try await admitted.session.search(query: "uniquequasar", documentIDs: nil)
        try require(delayed.complete && delayed.hits.contains(where: { $0.documentID == document }), "complete search reply has transport headroom")
        try require(searchStarted.duration(to: .now) >= .seconds(2.1) && searchStarted.duration(to: .now) < .seconds(3.5), "bounded search response")
        try FileManager.default.removeItem(at: searchDelay)
        results.append(["case": "search-response-headroom", "elapsed": String(describing: searchStarted.duration(to: .now))])

        try "Replacement content".write(to: fixture.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        let unchanged = try await admitted.session.read(documentID: document, offset: 0, revisionID: read.revisionID)
        try require(unchanged.text == read.text, "first read pins original content")
        await real.stop()
        try await library.reconnect()
        let restored = try await admitted.session.read(documentID: document, offset: 0, revisionID: read.revisionID)
        try require(restored == unchanged && admitted.context.serialized == originalContext, "restart restores actual pin and immutable context")
        results.append(["case": "same-supervisor-restart"])
        results.append(["case": "first-read-pins"])

        let second = try await admission(library)
        let latest = try await second.session.read(documentID: document, offset: 0, revisionID: nil)
        try require(latest.text == "Replacement content" && latest.revisionID != read.revisionID, "new session reads changed content")
        library.release(sessionID: second.sessionID)
        results.append(["case": "next-session-revision"])

        let unreadURL = fixture.appendingPathComponent("unread.md")
        try "# Untouched\nReference remains accessible.".write(to: unreadURL, atomically: true, encoding: .utf8)
        try await library.configure(enabled: true, sources: [source])
        let beforeDisable = try await admission(library)
        let members = try await beforeDisable.session.list(query: nil, cursor: nil)
        let unreadID = try requireEntry(members, name: "unread.md")
        let beforeDisableContext = beforeDisable.context.serialized
        try await library.configure(enabled: false, sources: [source])
        let retained = try await beforeDisable.session.read(documentID: unreadID, offset: 0, revisionID: nil)
        try require(retained.text.contains("Reference remains accessible"), "disabled future feature preserves unread active membership")
        let disabled = try await library.admit(startID: UUID())
        try requireOmission(disabled, .disabled)
        try require(beforeDisable.context.serialized == beforeDisableContext, "catalog remains immutable")
        results.append(["case": "disabled-future-active-access"])
        results.append(["case": "disabled-next-admission"])

        try await library.configure(enabled: true, sources: [])
        try requireOmission(try await library.admit(startID: UUID()), .empty)
        results.append(["case": "empty-admission"])
        try await library.configure(enabled: true, sources: [ReferenceSource(id: UUID(), url: fixture.appendingPathComponent("absent"), isDirectory: true)])
        try requireOmission(try await library.admit(startID: UUID()), .failed)
        results.append(["case": "failed-metadata-admission"])

        let formatSource = ReferenceSource(id: UUID(), url: output.appendingPathComponent("formats"), isDirectory: true)
        try await library.configure(enabled: true, sources: [formatSource])
        let formats = try await admission(library)
        let formatList = try await formats.session.list(query: nil, cursor: nil)
        let pdf = try await formats.session.read(documentID: requireEntry(formatList, name: "sample.pdf"), offset: 0, revisionID: nil)
        guard let firstPage = pdf.text.range(of: "ORCHID-439"), let secondPage = pdf.text.range(of: "QUARTZ-982") else { throw ReferenceProtocolError.malformed }
        try require(firstPage.lowerBound < secondPage.lowerBound, "PDF page text order")
        results.append(["case": "native-pdf-read"])
        let docx = try await formats.session.read(documentID: requireEntry(formatList, name: "sample.docx"), offset: 0, revisionID: nil)
        guard let before = docx.text.range(of: "Before table"), let cell = docx.text.range(of: "ORCHID-439"),
              let after = docx.text.range(of: "After table") else { throw ReferenceProtocolError.malformed }
        try require(before.lowerBound < cell.lowerBound && cell.lowerBound < after.lowerBound && docx.text.contains("\t"), "DOCX interleaved table order")
        results.append(["case": "native-docx-read"])
        library.release(sessionID: formats.sessionID)

        let delay = store.appendingPathComponent("metadata-delay-ms")
        try "2500".write(to: delay, atomically: true, encoding: .utf8)
        try await library.configure(enabled: true, sources: [source])
        let started = ContinuousClock.now
        try requireOmission(try await library.admit(startID: UUID()), .timeout)
        try require(started.duration(to: .now) >= .seconds(1.9) && started.duration(to: .now) < .seconds(2.8), "two-second absolute metadata deadline")
        results.append(["case": "bounded-metadata-timeout", "elapsed": String(describing: started.duration(to: .now))])
        try FileManager.default.removeItem(at: delay)
        try await library.configure(enabled: true, sources: [source])

        let canceledStart = UUID()
        let canceled = Task { try await library.admit(startID: canceledStart) }
        canceled.cancel()
        do { _ = try await canceled.value; throw ReferenceProtocolError.malformed }
        catch is CancellationError {}
        let abandoned = try await library.admit(startID: UUID())
        guard case .admitted(let abandonedSession) = abandoned else { throw ReferenceProtocolError.malformed }
        library.abandon(startID: abandonedSession.startID)
        do { _ = try await abandonedSession.session.list(query: nil, cursor: nil); throw ReferenceProtocolError.malformed }
        catch is ReferenceAccessFailure {}
        results.append(["case": "canceled-and-abandoned-admissions"])

        let replyDelay = store.appendingPathComponent("admit-reply-delay-ms")
        try "2500".write(to: replyDelay, atomically: true, encoding: .utf8)
        let lostStart = UUID()
        try requireOmission(try await library.admit(startID: lostStart), .timeout)
        try FileManager.default.removeItem(at: replyDelay)
        let recovered = try await admission(library)
        try require(recovered.sessionID != admitted.sessionID, "late committed admission does not replace active session")
        try require(try await admitted.session.read(documentID: document, offset: 0, revisionID: read.revisionID).text == read.text,
                    "abandoned start retains unrelated active pins")
        results.append(["case": "lost-admit-response"])
        library.release(sessionID: recovered.sessionID)
        library.release(sessionID: beforeDisable.sessionID)
        library.release(sessionID: admitted.sessionID)
        try await runRetrievalChecks(library: library, store: store)
        await real.stop()
    }

    func admission(_ library: ReferenceLibrary) async throws -> ReferenceAdmissionResult.Admitted {
        let start = UUID()
        guard case .admitted = try await library.admit(startID: start) else { throw ReferenceProtocolError.malformed }
        return try library.accept(startID: start)
    }

    private func requireOmission(_ result: ReferenceAdmissionResult, _ reason: ReferenceOmissionReason) throws {
        guard case .omitted(_, let actual) = result, actual == reason else { throw ReferenceProtocolError.malformed }
        try require((reason == .disabled || reason == .empty) == (reason.warning == nil), "omission warning policy")
    }

    func requireEntry(_ list: ReferenceListResult, name: String) throws -> UUID {
        guard let entry = list.entries.first(where: { $0.name == name }) else { throw ReferenceProtocolError.malformed }
        return entry.documentID
    }
}
#endif
