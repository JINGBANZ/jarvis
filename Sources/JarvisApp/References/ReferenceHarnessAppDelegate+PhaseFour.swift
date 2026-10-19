#if JARVIS_LIVE_E2E
import Foundation
import JarvisCore

private actor ReferenceHarnessBrain: BrainClient {
    private var script: [BrainResponse]
    private(set) var requests: [[ChatMessage]] = []
    private(set) var declarations: [[ToolDef]] = []
    private let summary: Bool
    init(_ script: [BrainResponse] = [], summary: Bool = false) { self.script = script; self.summary = summary }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        requests.append(messages); declarations.append(tools)
        if summary { return .init(toolCalls: [], outputText: #"{"context":"Synthetic reference review","decisions":["Preserve boundary decision"],"coaching":[],"openQuestions":[],"verification":["No execution evidence supplied"]}"#) }
        guard !script.isEmpty else { throw ReferenceProtocolError.malformed }
        return script.removeFirst()
    }
}

// @unchecked Sendable: the lock protects synthetic Activity and overlay observations.
private final class ReferenceHarnessSink: ActivityEventRecording, OverlayRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ActivityEvent] = []
    private var hints: [String] = []
    var activityCount: Int { lock.withLock { events.count } }
    var hintCount: Int { lock.withLock { hints.count } }
    func record(_ event: ActivityEvent, at date: Date) { lock.withLock { events.append(event) } }
    func render(_ hint: String) { lock.withLock { hints.append(hint) } }
}

private struct ReferenceHarnessScreen: ScreenCapturing {
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? { nil }
    func cancelCapture() {}
}

extension ReferenceHarnessAppDelegate {
    private struct PhaseFixture {
        let runtime: ReferenceRuntime
        let root: URL
        let store: URL
        let defaults: UserDefaults
        let preferences: BrainPreferences
        let sources: ReferencePreferences
    }

    func runPhaseFourChecks(selection: String) async throws {
        let cases = (1...7).map { String(format: "REF%02d", $0) }
        try require(selection == "all" || cases.contains(selection), "known REF selector")
        for name in cases where selection == "all" || selection == name {
            let root = output.appendingPathComponent(name)
            let source = root.appendingPathComponent("sources")
            let store = root.appendingPathComponent("store")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try "# Alpha\nUniquequasar evidence. 😀é\n".write(to: source.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
            try "Previously unread beta evidence.\n".write(to: source.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)
            try "UNUSED-PRIVATE-CONTENT-SENTINEL-7392".write(to: source.appendingPathComponent("unused.txt"), atomically: true, encoding: .utf8)
            let domain = "jarvis.reference-harness.\(UUID())"
            let defaults = UserDefaults(suiteName: domain)!
            let preferences = BrainPreferences(defaults: defaults)
            preferences.disabledTools = []
            let sources = ReferencePreferences(defaults: defaults)
            sources.add(.init(path: source.path, isDirectory: true))
            let runtime = ReferenceRuntime(home: store)
            let fixture = PhaseFixture(runtime: runtime, root: source, store: store, defaults: defaults,
                                       preferences: preferences, sources: sources)
            do {
                try await phaseFour(name, fixture)
                let pid = runtime.processIdentifier
                await runtime.stop()
                if let pid { try require(kill(pid, 0) != 0 && errno == ESRCH, "\(name) helper reaped") }
                defaults.removePersistentDomain(forName: domain)
                results.append(["case": name, "layer": "signed deterministic production handlers and packaged helper"])
            } catch {
                await runtime.stop()
                defaults.removePersistentDomain(forName: domain)
                throw error
            }
        }
    }

    private func phaseFour(_ name: String, _ fixture: PhaseFixture) async throws {
        let runtime = fixture.runtime
        let library = runtime.library
        if name == "REF05" {
            try Data().write(to: fixture.store.appendingPathComponent("index-before-publish"))
        }
        runtime.configure(preferences: fixture.preferences, sources: fixture.sources)
        let start = ContinuousClock.now
        let admitted = try await admission(library)
        try require(start.duration(to: .now) < .seconds(2.3), "\(name) absolute metadata admission budget")
        let result = ReferenceAdmissionResult.admitted(admitted)
        let entries = try await admitted.session.list(query: nil, cursor: nil)
        let alpha = try requireEntry(entries, name: "alpha.md")
        let beta = try requireEntry(entries, name: "beta.txt")
        let context = String(decoding: admitted.context.serialized, as: UTF8.self)
        try require(!context.contains(fixture.root.path) && !context.contains("UNUSED-PRIVATE-CONTENT"), "metadata-only path-free catalog")
        switch name {
        case "REF01":
            let brain = ReferenceHarnessBrain([try referenceCall("list_references", ["query": NSNull(), "cursor": NSNull()], id: "list"), referenceFinish])
            let (driver, transcript, _) = referenceDriver(brain: brain, result: result)
            try await referenceTurn(driver, transcript, "List admitted references.")
            let requests = await brain.requests
            let listed = try referenceOutput("list", in: requests)
            try require(listed["total_count"] as? Int == 3, "actual list handler returns catalog membership")
            try assertReferencePrefix(requests, context: admitted.context)
            try require(!requests.flatMap { $0.compactMap(\.text) }.joined().contains("UNUSED-PRIVATE-CONTENT"), "unused content absent provider requests")
            library.release(sessionID: admitted.sessionID)
            fixture.preferences.disabledTools = [searchReferencesTool.name]
            runtime.configure(preferences: fixture.preferences, sources: fixture.sources)
            let disabled = try await library.admit(startID: UUID())
            try require(disabled.admitted == nil && disabled.capabilities(disabledTools: []).tool(named: readReferenceTool.name) == nil,
                        "disabled admission has no catalog or tools")
            try await referenceOmittedProjection(disabled)
            do {
                _ = try await admitted.session.list(query: nil, cursor: nil)
                throw ReferenceProtocolError.malformed
            } catch let failure as ReferenceAccessFailure {
                try require(failure.reason == .released, "new omitted Start cannot retain old released handle")
            }
            fixture.preferences.disabledTools = []
            fixture.sources.sources = []
            runtime.configure(preferences: fixture.preferences, sources: fixture.sources)
            let empty = try await library.admit(startID: UUID())
            guard case .omitted(_, .empty) = empty else { throw ReferenceProtocolError.malformed }
            try await referenceOmittedProjection(empty)
            try require(ReferenceOmissionReason.empty.warning == nil && ReferenceOmissionReason.disabled.warning == nil,
                        "disabled and empty are silent")
            fixture.sources.sources = [.init(path: fixture.root.appendingPathComponent("missing").path, isDirectory: true)]
            runtime.configure(preferences: fixture.preferences, sources: fixture.sources)
            let failed = try await library.admit(startID: UUID())
            guard case .omitted(_, .failed) = failed else { throw ReferenceProtocolError.malformed }
            try require(ReferenceOmissionReason.failed.warning != nil, "failed metadata produces one typed omission reason")
            fixture.sources.sources = [.init(path: fixture.root.appendingPathComponent("alpha.md").path, isDirectory: false)]
            runtime.configure(preferences: fixture.preferences, sources: fixture.sources)
            let selectedFile = try await admission(library)
            let selectedEntries = try await selectedFile.session.list(query: nil, cursor: nil)
            try require(selectedEntries.entries.count == 1, "direct file selection admits only the selected file")
            library.release(sessionID: selectedFile.sessionID)
            fixture.sources.sources = [.init(path: fixture.root.path, isDirectory: false)]
            runtime.configure(preferences: fixture.preferences, sources: fixture.sources)
            let changedKind = try await library.admit(startID: UUID())
            guard case .omitted(_, .failed) = changedKind else { throw ReferenceProtocolError.malformed }
            try await referenceOmittedProjection(changedKind)
            let delay = fixture.store.appendingPathComponent("metadata-delay-ms")
            try "2500".write(to: delay, atomically: true, encoding: .utf8)
            fixture.sources.sources = [.init(path: fixture.root.path, isDirectory: true)]
            runtime.configure(preferences: fixture.preferences, sources: fixture.sources)
            let deadlineStart = ContinuousClock.now
            let omitted = try await library.admit(startID: UUID())
            guard case .omitted(_, .timeout) = omitted else { throw ReferenceProtocolError.malformed }
            try require(deadlineStart.duration(to: .now) < .seconds(2.3), "absolute metadata deadline expires independently of later readiness")
            try FileManager.default.removeItem(at: delay)
            runtime.configure(preferences: fixture.preferences, sources: fixture.sources)
            let later = try await admission(library)
            let omittedBrain = ReferenceHarnessBrain([referenceFinish, referenceFinish])
            let (omittedDriver, omittedTranscript, _) = referenceDriver(brain: omittedBrain, result: omitted)
            try await referenceTurn(omittedDriver, omittedTranscript, "Continue without references after admission timed out.")
            try await referenceTurn(omittedDriver, omittedTranscript, "The helper is ready now; this same session remains unchanged.")
            let omittedRequests = await omittedBrain.requests
            try require(omittedRequests.allSatisfy { !$0.contains { $0.text?.contains("documentCatalog") == true || $0.text?.contains("- read_reference:") == true } },
                        "late readiness cannot add catalog or tools to an omitted session")
            library.release(sessionID: later.sessionID)
        case "REF02":
            // Admission finishes while other Start readiness is held; later Settings edits affect only the next Start.
            let first = try await admitted.session.read(documentID: alpha, offset: 0, revisionID: nil)
            fixture.preferences.disabledTools = [searchReferencesTool.name, readReferenceTool.name]
            fixture.sources.sources = []
            runtime.configure(preferences: fixture.preferences, sources: fixture.sources)
            let brain = ReferenceHarnessBrain([try referenceCall("read_reference", ["document_id": beta.uuidString, "offset": 0, "revision_id": NSNull()], id: "unread"), referenceFinish])
            let (driver, transcript, _) = referenceDriver(brain: brain, result: result, disabledTools: fixture.preferences.disabledTools)
            try await referenceTurn(driver, transcript, "Read beta, which this session has never opened.")
            let evidence = try referenceOutput("unread", in: await brain.requests)
            try require((evidence["text"] as? String)?.contains("Previously unread beta") == true, "actual read survives Settings disable and root removal")
            try require(result.capabilities(disabledTools: fixture.preferences.disabledTools).tool(named: readReferenceTool.name) != nil,
                        "admitted reference access is frozen")
            try require(try await admitted.session.read(documentID: alpha, offset: 0, revisionID: first.revisionID) == first,
                        "existing pin survives Settings change")
            let next = try await library.admit(startID: UUID())
            try require(next.admitted == nil, "next session observes disabled Settings")
            // Independent read restriction also freezes when the master remains enabled.
            fixture.sources.add(.init(path: fixture.root.path, isDirectory: true))
            fixture.preferences.disabledTools = [readReferenceTool.name]
            runtime.configure(preferences: fixture.preferences, sources: fixture.sources)
            let restricted = try await admission(library)
            fixture.preferences.disabledTools = []
            runtime.configure(preferences: fixture.preferences, sources: fixture.sources)
            try require(ReferenceAdmissionResult.admitted(restricted).capabilities(disabledTools: []).tool(named: readReferenceTool.name) == nil,
                        "read reenable cannot widen an earlier admission")
            let beforeRemoval = try await admission(library)
            fixture.sources.sources = []
            runtime.configure(preferences: fixture.preferences, sources: fixture.sources)
            let removalBrain = ReferenceHarnessBrain([try referenceCall("read_reference", ["document_id": beta.uuidString, "offset": 0, "revision_id": NSNull()], id: "removed-root"), referenceFinish])
            let (removalDriver, removalTranscript, _) = referenceDriver(brain: removalBrain, result: .admitted(beforeRemoval))
            try await referenceTurn(removalDriver, removalTranscript, "Read beta after its Settings root was removed with References still enabled.")
            try require((try referenceOutput("removed-root", in: await removalBrain.requests)["text"] as? String)?.contains("Previously unread beta") == true,
                        "root removal independently preserves unread active membership")
            guard case .omitted(_, .empty) = try await library.admit(startID: UUID()) else { throw ReferenceProtocolError.malformed }

        case "REF03":
            try await referenceWatcherChecks(fixture)
        case "REF04":
            _ = try await admitted.session.read(documentID: alpha, offset: 0, revisionID: nil)
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("alpha.md"))
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("beta.txt"))
            let brain = ReferenceHarnessBrain([
                try referenceCall("read_reference", ["document_id": alpha.uuidString, "offset": 0, "revision_id": NSNull()], id: "pinned"),
                try referenceCall("read_reference", ["document_id": beta.uuidString, "offset": 0, "revision_id": NSNull()], id: "deleted"), referenceFinish])
            let (driver, transcript, _) = referenceDriver(brain: brain, result: result)
            try await referenceTurn(driver, transcript, "Read the pinned original and the deleted unread original.")
            let requests = await brain.requests
            try require((try referenceOutput("pinned", in: requests)["text"] as? String)?.contains("Uniquequasar") == true,
                        "pinned original remains readable after deletion")
            let failure = requests.flatMap { $0 }.first { $0.toolCallId == "deleted" }?.text ?? ""
            try require(failure.contains("Reference access: unavailable.") && !failure.contains(fixture.root.path), "unread original deletion is a typed safe failure")
        case "REF05":
            let brain = ReferenceHarnessBrain([
                try referenceCall("read_reference", ["document_id": alpha.uuidString, "offset": 0, "revision_id": NSNull()], id: "read"),
                try referenceCall("search_references", ["query": "uniquequasar", "document_ids": NSNull()], id: "search"), referenceFinish])
            let (driver, transcript, _) = referenceDriver(brain: brain, result: result)
            try await referenceTurn(driver, transcript, "Read alpha and search the admitted collection.")
            let requests = await brain.requests
            let read = try referenceOutput("read", in: requests)
            let search = try referenceOutput("search", in: requests)
            try require(read["search_ready"] as? Bool == false && (read["text"] as? String)?.contains("Uniquequasar") == true,
                        "actual read works before held FTS publication")
            try require(search["complete"] as? Bool == false && (search["hits"] as? [Any])?.isEmpty == true,
                        "actual zero-hit partial result discloses incomplete coverage")
            try FileManager.default.removeItem(at: fixture.store.appendingPathComponent("index-before-publish"))
            let deadline = ContinuousClock.now + .seconds(5)
            var ready = false
            while .now < deadline, !ready {
                let search = try await admitted.session.search(query: "uniquequasar", documentIDs: nil)
                ready = search.complete && search.hits.contains { $0.documentID == alpha }
                if !ready { try await Task.sleep(for: .milliseconds(25)) }
            }
            try require(ready && String(decoding: admitted.context.serialized, as: UTF8.self) == context, "late FTS readiness never rewrites catalog")
            let conversionGate = fixture.store.appendingPathComponent("preparation-after-reserve")
            try Data().write(to: conversionGate)
            let delayedURL = fixture.root.appendingPathComponent("delayed.docx")
            try FileManager.default.copyItem(at: output.appendingPathComponent("formats/sample.docx"), to: delayedURL)
            runtime.configure(preferences: fixture.preferences, sources: fixture.sources)
            let conversionSession = try await admission(library)
            let delayedList = try await conversionSession.session.list(query: nil, cursor: nil)
            let delayedID = try requireEntry(delayedList, name: "delayed.docx")
            let conversionContext = conversionSession.context.serialized
            let conversionBrain = ReferenceHarnessBrain([try referenceCall("read_reference", ["document_id": delayedID.uuidString,
                "offset": 0, "revision_id": NSNull()], id: "converting"), referenceFinish])
            let (conversionDriver, conversionTranscript, _) = referenceDriver(brain: conversionBrain, result: .admitted(conversionSession))
            try await referenceTurn(conversionDriver, conversionTranscript, "Read the separately delayed Word document once.")
            let conversionRequests = await conversionBrain.requests
            try require(conversionRequests.flatMap { $0 }.contains { $0.toolCallId == "converting" && $0.text?.contains("Reference access: preparing.") == true },
                        "separately delayed conversion is a bounded typed preparing result")
            try FileManager.default.removeItem(at: conversionGate)
            let conversionDeadline = ContinuousClock.now + .seconds(5)
            var converted = false
            while .now < conversionDeadline, !converted {
                do { converted = try await conversionSession.session.read(documentID: delayedID, offset: 0, revisionID: nil).text.contains("ORCHID-439") }
                catch let failure as ReferenceAccessFailure where failure.reason == .preparing {}
                if !converted { try await Task.sleep(for: .milliseconds(50)) }
            }
            try require(converted && conversionSession.context.serialized == conversionContext, "later conversion readiness preserves the admitted catalog")
            let lateBrain = ReferenceHarnessBrain([try referenceCall("read_reference", ["document_id": delayedID.uuidString,
                "offset": 0, "revision_id": NSNull()], id: "converted"), referenceFinish])
            let (lateDriver, lateTranscript, _) = referenceDriver(brain: lateBrain, result: .admitted(conversionSession))
            try await referenceTurn(lateDriver, lateTranscript, "Read the Word document after preparation completed.")
            try require((try referenceOutput("converted", in: await lateBrain.requests)["text"] as? String)?.contains("ORCHID-439") == true,
                        "actual tool handler gains content after conversion without catalog rewrite")

        case "REF06":
            let brain = ReferenceHarnessBrain([try referenceCall("read_reference", ["document_id": alpha.uuidString, "offset": 0, "revision_id": NSNull()], id: "read")] + Array(repeating: referenceFinish, count: 6))
            let summarizer = ReferenceHarnessBrain(summary: true)
            let (driver, transcript, _) = referenceDriver(brain: brain, result: result, summarizer: summarizer, threshold: 100)
            for index in 0..<4 {
                try await referenceTurn(driver, transcript, "Synthetic turn \(index). " + String(repeating: "Boundary design remains a proposal requiring evidence. ", count: 60))
                try await Task.sleep(for: .milliseconds(50))
            }
            let requests = await brain.requests
            try assertReferencePrefix(requests, context: admitted.context)
            try require(requests.contains { $0.contains { $0.text?.hasPrefix("[session so far, condensed") == true } }, "actual driver compaction committed history")
            let summaries = await summarizer.requests
            try require(!summaries.isEmpty && summaries.allSatisfy { !$0.contains { $0.text?.contains("documentCatalog") == true } },
                        "catalog stays outside summarizer input")
            let tools = await brain.declarations
            try require(tools.dropFirst().allSatisfy { $0 == tools.first }, "tools remain stable across real driver compaction")
        case "REF07":
            try await referenceCancellationChecks(fixture, active: admitted, document: alpha)
        default: throw ReferenceProtocolError.malformed
        }
    }

    private var referenceFinish: BrainResponse {
        .init(toolCalls: [.speak(callId: "finish", hint: "Synthetic evidence received.")],
              rawToolCalls: [.init(id: "finish", name: "speak", argumentsJSON: #"{"hint":"Synthetic evidence received."}"#)])
    }

    private func referenceCall(_ name: String, _ arguments: [String: Any], id: String) throws -> BrainResponse {
        let object: [String: Any] = ["name": name, "arguments": arguments]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        guard let call = ToolInvocation.parse(callId: id, name: "call_tool", argumentsJSON: text) else { throw ReferenceProtocolError.malformed }
        return .init(toolCalls: [call], rawToolCalls: [.init(id: id, name: "call_tool", argumentsJSON: text)])
    }

    private func referenceDriver(brain: ReferenceHarnessBrain, result: ReferenceAdmissionResult,
                                 disabledTools: Set<String> = [], summarizer: ReferenceHarnessBrain? = nil,
                                 threshold: Int = 100000) -> (CoachDriver, RollingTranscript, ReferenceHarnessSink) {
        let transcript = RollingTranscript()
        let sink = ReferenceHarnessSink()
        let target = BrainTarget(provider: .openAI, modelID: BrainModelCatalog.defaultModel(for: .openAI).id)
        let driver = CoachDriver(config: .init(historyCompactionTokenThreshold: threshold), transcript: transcript,
            route: .init(targets: [.init(target: target, brain: brain, summarizer: summarizer)]),
            screen: ReferenceHarnessScreen(), overlay: sink, clock: SystemClock(), automaticAttemptDelay: { _ in },
            activity: sink, capabilities: result.capabilities(disabledTools: disabledTools),
            documents: result.admitted?.session, sessionContext: result.admitted?.context)
        return (driver, transcript, sink)
    }

    private func referenceTurn(_ driver: CoachDriver, _ transcript: RollingTranscript, _ text: String) async throws {
        transcript.append(.init(speaker: .them, text: text, at: Date().timeIntervalSince1970))
        try require(await driver.handleTrigger(.turnEnd) == .spoke, "synthetic model turn committed")
    }

    private func referenceOutput(_ id: String, in requests: [[ChatMessage]]) throws -> [String: Any] {
        guard let text = requests.flatMap({ $0 }).first(where: { $0.toolCallId == id })?.text,
              let newline = text.firstIndex(of: "\n"),
              let object = try JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8)) as? [String: Any] else {
            throw ReferenceProtocolError.malformed
        }
        return object
    }

    private func assertReferencePrefix(_ requests: [[ChatMessage]], context: SessionContext) throws {
        let serialized = String(decoding: context.serialized, as: UTF8.self)
        for request in requests {
            let indices = request.indices.filter { request[$0].text?.contains(serialized) == true }
            try require(indices == [1] && request[1].role == .user, "exact catalog once before history")
            try require(!request.compactMap(\.text).joined().contains("UNUSED-PRIVATE-CONTENT"), "unused content never enters provider requests")
        }
    }

    private func referenceOmittedProjection(_ omitted: ReferenceAdmissionResult) async throws {
        let brain = ReferenceHarnessBrain([referenceFinish])
        let (driver, transcript, sink) = referenceDriver(brain: brain, result: omitted)
        try await referenceTurn(driver, transcript, "Please consult my References for this question.")
        let requests = await brain.requests
        let definitions = await brain.declarations
        try require(requests.count == 1 && omitted.admitted == nil, "omitted admission creates a fresh coaching request without a document session")
        try require(requests.allSatisfy { request in !request.contains { message in
            let text = message.text ?? ""
            return text.contains("SessionContext (") || text.contains("documentCatalog")
                || text.contains("- list_references:") || text.contains("- read_reference:") || text.contains("- search_references:")
        } }, "disabled/empty first request omits catalog and deferred reference tools")
        try require(definitions.allSatisfy { $0.allSatisfy { !["list_references", "read_reference", "search_references", "call_tool", "load_tool"].contains($0.name) } },
                    "disabled/empty first request offers no reference capability")
        try require(sink.activityCount == 1 && sink.hintCount == 1, "disabled/empty coaching remains silent about References")
    }

    private func referenceWatcherChecks(_ fixture: PhaseFixture) async throws {
        let selected = fixture.root.appendingPathComponent("alpha.md")
        var changes = 0
        let watcher = ReferenceSourceWatcher { changes += 1 }
        watcher.watch([.init(path: selected.path, isDirectory: false)], excluding: [fixture.store])
        try "irrelevant sibling".write(to: fixture.root.appendingPathComponent("sibling.txt"), atomically: true, encoding: .utf8)
        try Data().write(to: fixture.store.appendingPathComponent("cache-write"))
        try await Task.sleep(for: .milliseconds(450))
        try require(changes == 0, "unrelated sibling and owned cache do not reconfigure selected file")
        try "selected edit".write(to: selected, atomically: false, encoding: .utf8)
        try await waitReferenceChange { changes > 0 }
        let edited = changes
        try "atomic replacement".write(to: selected, atomically: true, encoding: .utf8)
        try await waitReferenceChange { changes > edited }
        watcher.stop()
        let stopped = changes
        try "after stop".write(to: selected, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(350))
        try require(changes == stopped, "stopped watcher discards queued callbacks")

        fixture.sources.sources = [.init(path: fixture.root.path, isDirectory: true)]
        fixture.runtime.configure(preferences: fixture.preferences, sources: fixture.sources)
        let nested = fixture.root.appendingPathComponent("nested/deeper")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "new nested metadata".write(to: nested.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        var discovered = false
        let deadline = ContinuousClock.now + .seconds(5)
        while .now < deadline, !discovered {
            let candidate = try await admission(fixture.runtime.library)
            discovered = try await candidate.session.list(query: "new.md", cursor: nil).entries.contains { $0.name == "new.md" }
            fixture.runtime.library.release(sessionID: candidate.sessionID)
            if !discovered { try await Task.sleep(for: .milliseconds(100)) }
        }
        try require(discovered, "native filesystem watcher discovers a new nested supported file before next Start")
    }

    private func waitReferenceChange(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try require(condition(), "native filesystem event delivered")
    }

    private func referenceCancellationChecks(_ fixture: PhaseFixture, active: ReferenceAdmissionResult.Admitted,
                                             document: UUID) async throws {
        let library = fixture.runtime.library
        let pending = PendingReferenceAdmission(library: library, deadline: .now + .seconds(2))
        let ready = try await pending.result()
        guard let newlyAdmitted = ready.admitted else { throw ReferenceProtocolError.malformed }
        var releaseReadiness: CheckedContinuation<Void, Never>?
        let readiness = Task {
            await withCheckedContinuation { releaseReadiness = $0 }
            _ = try? await pending.result()
        }
        while releaseReadiness == nil { await Task.yield() }
        readiness.cancel()
        pending.cancel()
        do {
            _ = try await newlyAdmitted.session.list(query: nil, cursor: nil)
            throw ReferenceProtocolError.malformed
        } catch let failure as ReferenceAccessFailure {
            try require(failure.reason == .released, "Stop releases admitted pending ownership before noncooperative readiness resumes")
        }
        _ = try await active.session.read(documentID: document, offset: 0, revisionID: nil)
        releaseReadiness?.resume()
        await readiness.value

        let delay = fixture.store.appendingPathComponent("read-reply-delay-ms")
        try "1500".write(to: delay, atomically: true, encoding: .utf8)
        let brain = ReferenceHarnessBrain([try referenceCall("read_reference", ["document_id": document.uuidString,
            "offset": 0, "revision_id": NSNull()], id: "late"), referenceFinish])
        let (driver, transcript, sink) = referenceDriver(brain: brain, result: .admitted(active))
        transcript.append(.init(speaker: .them, text: "Read the admitted reference.", at: Date().timeIntervalSince1970))
        let turn = Task { await driver.handleTrigger(.turnEnd) }
        while await brain.requests.isEmpty { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        turn.cancel()
        try require(await turn.value == .cancelled, "Stop cancels an awaited reference tool")
        let events = sink.activityCount
        try await Task.sleep(for: .milliseconds(1700))
        let requestCount = await brain.requests.count
        try require(sink.activityCount == events && sink.hintCount == 0 && requestCount == 1,
                    "late reference reply delivers no Activity, overlay, continuation or stale warning")
        try FileManager.default.removeItem(at: delay)

        for index in 0..<3 {
            let queued = ReferenceRuntime(home: fixture.store.deletingLastPathComponent().appendingPathComponent("queued-\(index)"))
            queued.configure(preferences: fixture.preferences, sources: fixture.sources)
            await queued.stop()
            await Task.yield()
            try require(queued.processIdentifier == nil, "early Quit drains queued warmup before any later launch")
        }
        try await referenceStartupStopChecks(home: fixture.store.deletingLastPathComponent())
        try await onboardingStopChecks(home: fixture.store.deletingLastPathComponent())
        library.release(sessionID: active.sessionID)
        do {
            _ = try await active.session.list(query: nil, cursor: nil)
            throw ReferenceProtocolError.malformed
        } catch let failure as ReferenceAccessFailure {
            try require(failure.reason == .released, "Stop closes session access")
        }
    }
}
#endif
