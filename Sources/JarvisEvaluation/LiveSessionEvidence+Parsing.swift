import Foundation
import JarvisBrainProviders
import JarvisCore

/// Record decoding for `LiveSessionEvidence`. Each reader names the writer it mirrors, so a field
/// that moves on the writer side is found by reading the two side by side.
extension LiveSessionEvidence {
    private static let loadedMessagePrefix = "📎 loaded the "

    /// `ActivityLog.PersistedEntry`: `k` kind, `m` message, `o` occurrence time.
    static func parseActivity(_ objects: [[String: Any]]) -> [ActivityRow] {
        objects.enumerated().map { index, object in
            let kind = object["k"] as? String
            let message = object["m"] as? String ?? ""
            return ActivityRow(
                index: index,
                kind: kind,
                message: message,
                occurredAt: (object["o"] as? NSNumber)?.doubleValue,
                loadedCapability: kind == ActivityEvent.Kind.capabilityLoaded.rawValue
                    ? loadedCapability(fromMessage: message)
                    : nil)
        }
    }

    /// `ActivityEvent.rendered` writes `📎 loaded the <name> <tool|skill>`: the kind is the last word
    /// and everything between the prefix and it is the name.
    static func loadedCapability(fromMessage message: String) -> LoadedCapability? {
        guard message.hasPrefix(loadedMessagePrefix) else { return nil }
        let rest = message.dropFirst(loadedMessagePrefix.count)
        guard let space = rest.lastIndex(of: " ") else { return nil }
        let name = String(rest[..<space])
        let kind = String(rest[rest.index(after: space)...])
        guard !name.isEmpty, ActivityEvent.CapabilityKind(rawValue: kind) != nil else { return nil }
        return LoadedCapability(name: name, kind: kind)
    }

    /// `SessionAuditWorker.encodeAttempt`: `started` and `finished` records keyed by `attempt`. A
    /// finished record pairs with the started record before it that has the same id; a finished
    /// record with no such started record, or a repeated one, is ignored.
    static func parseAttempts(_ objects: [[String: Any]], sessionDate: Date) -> [Attempt] {
        let instants = parseClockStamps(objects.map { $0["t"] as? String }, sessionDate: sessionDate)
        var startedIndices: [Int] = []
        var startedIDs: Set<Int> = []
        var finishedIndexByID: [Int: Int] = [:]
        for (index, object) in objects.enumerated() {
            guard let id = object["attempt"] as? Int else { continue }
            switch object["event"] as? String {
            case "started" where !startedIDs.contains(id):
                startedIDs.insert(id)
                startedIndices.append(index)
            case "finished" where startedIDs.contains(id) && finishedIndexByID[id] == nil:
                finishedIndexByID[id] = index
            default:
                continue
            }
        }
        return startedIndices.map { startedIndex in
            let started = objects[startedIndex]
            let id = started["attempt"] as? Int ?? 0
            let finishedIndex = finishedIndexByID[id]
            let finished = finishedIndex.map { objects[$0] }
            let transcript = (started["transcript"] as? [[String: Any]] ?? []).map {
                TranscriptEntry(
                    speaker: $0["speaker"] as? String ?? "",
                    text: $0["text"] as? String ?? "",
                    at: $0["at"] as? Double)
            }
            return Attempt(
                id: id,
                startedRecordIndex: startedIndex,
                finishedRecordIndex: finishedIndex,
                startedAt: instants[startedIndex],
                finishedAt: finishedIndex.flatMap { instants[$0] },
                trigger: started["trigger"] as? String ?? "",
                sourceTrigger: started["source_trigger"] as? String ?? "",
                wake: started["wake"] as? String ?? "",
                provider: started["provider"] as? String ?? "",
                model: started["model"] as? String ?? "",
                terminal: finished?["terminal"] as? String,
                outcome: finished?["outcome"] as? String,
                transcript: transcript)
        }
    }

    /// Dates the local `HH:mm:ss` stamps of attempt records, given in file order.
    ///
    /// `SessionAuditWorker` formats `t` without a time zone, so the stamp is the machine's local
    /// clock with no date; `SessionDirectoryID.make` names the folder in the same local time.
    /// Records are appended in time order, so a stamp earlier than the one before it means the
    /// session crossed midnight, and it and every later stamp move to the next day. The session's
    /// own start time seeds that comparison, so a session begun just before midnight whose first
    /// attempt starts after it is dated correctly too.
    static func parseClockStamps(_ stamps: [String?], sessionDate: Date) -> [TimeInterval?] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let sessionDay = calendar.startOfDay(for: sessionDate)
        let start = calendar.dateComponents([.hour, .minute, .second], from: sessionDate)
        var previous = (start.hour ?? 0) * 3600 + (start.minute ?? 0) * 60 + (start.second ?? 0)
        var dayOffset = 0
        return stamps.map { stamp in
            guard let stamp, let clock = clockTime(stamp) else { return nil }
            let secondsIntoDay = clock.hour * 3600 + clock.minute * 60 + clock.second
            if secondsIntoDay < previous { dayOffset += 1 }
            previous = secondsIntoDay
            // Calendar arithmetic, not 86_400-second steps: a day that changes DST is not 24 hours.
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: sessionDay),
                  let instant = calendar.date(
                    bySettingHour: clock.hour, minute: clock.minute, second: clock.second, of: day)
            else { return nil }
            return instant.timeIntervalSince1970
        }
    }

    private static func clockTime(_ stamp: String) -> (hour: Int, minute: Int, second: Int)? {
        let fields = stamp.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let hour = Int(fields[0]), let minute = Int(fields[1]), let second = Int(fields[2]),
              (0..<24).contains(hour), (0..<60).contains(minute), (0..<60).contains(second)
        else { return nil }
        return (hour, minute, second)
    }

    /// `SessionDirectoryID.make` stamps the folder `yyyy-MM-dd_HH-mm-ss` in local time behind an
    /// optional build prefix. Searching for the stamp instead of matching the whole name keeps older
    /// unprefixed names and copied folders readable.
    static func parseSessionDate(fromDirectoryName name: String) -> Date? {
        guard let match = name.firstMatch(
            of: /[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}/)
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.date(from: String(match.output))
    }

    static func parseHealthState(_ json: String?) -> String? {
        guard let json, let object = jsonObject(json) else { return nil }
        return object["state"] as? String
    }

    /// `SessionAuditWorker.encodeTraffic`. `request` is either the Responses API body from
    /// `OpenAIBrainClient.encodeBody` or the CLI record from `CLIBrainClient.prepareTurn`, which alone
    /// carries `provider`. A body that was not JSON is stored as a string and reads as empty here.
    static func parseTraffic(_ object: [String: Any], index: Int) -> TrafficRecord {
        let context = object["coach_attempt"] as? [String: Any]
        let request = object["request"] as? [String: Any] ?? [:]
        let input = request["input"] as? [[String: Any]] ?? []
        let tools = request["tools"] as? [[String: Any]] ?? []
        let toolChoice = request["tool_choice"]
        return TrafficRecord(
            index: index,
            tag: object["tag"] as? String ?? "",
            attemptID: context?["id"] as? Int,
            sourceTrigger: context?["source_trigger"] as? String,
            status: object["status"] as? Int,
            error: object["error"] as? String,
            cliProvider: request["provider"] as? String,
            instructions: request["instructions"] as? String,
            declaredToolNames: tools.compactMap { $0["name"] as? String },
            toolChoiceType: toolChoice as? String
                ?? (toolChoice as? [String: Any])?["type"] as? String,
            replayedFunctionCalls: input.compactMap { item in
                guard item["type"] as? String == "function_call" else { return nil }
                return FunctionCall(
                    callID: item["call_id"] as? String ?? "",
                    name: item["name"] as? String ?? "",
                    arguments: item["arguments"] as? String ?? "")
            },
            replayedFunctionOutputCallIDs: input.compactMap { item in
                guard item["type"] as? String == "function_call_output" else { return nil }
                return item["call_id"] as? String ?? ""
            },
            speakDiagram: speakDiagram(inResponse: object["response"]))
    }

    /// The speak call's `mermaid` argument. The OpenAI response is the raw Responses body, whose
    /// `output` lists calls as `function_call` items with JSON-string `arguments`. A CLI response
    /// (`CLIBrainClient.responseRecord`) keeps the model's text under `reply`, and the call is the
    /// protocol object inside it. A null and an absent `mermaid` both read as `.none`, as
    /// `ToolInvocation.parse` reads them. A CLI reply the client turned into a speak call from prose
    /// holds no protocol object, so it reads as `.noSpeakCall`: this reports what the model wrote.
    static func speakDiagram(inResponse response: Any?) -> SpeakDiagram {
        guard let response = response as? [String: Any] else { return .noSpeakCall }
        let arguments: [String: Any]?
        if let output = response["output"] as? [[String: Any]] {
            guard let call = output.first(where: {
                $0["type"] as? String == "function_call" && $0["name"] as? String == speakTool.name
            }) else { return .noSpeakCall }
            arguments = (call["arguments"] as? String).flatMap(jsonObject)
        } else if let reply = response["reply"] as? String {
            guard let call = cliToolCall(in: reply), call.name == speakTool.name else {
                return .noSpeakCall
            }
            arguments = call.arguments
        } else {
            return .noSpeakCall
        }
        guard let mermaid = arguments?["mermaid"] as? String else { return .none }
        return .present(mermaid)
    }

    /// The client's own rule, so a reply the client read as a speak call reads as one here.
    static func cliToolCall(in reply: String) -> (name: String, arguments: [String: Any])? {
        guard let call = CLIBrainClient.extractToolCall(from: reply) else { return nil }
        return (call.name, jsonObject(call.argumentsJSON) ?? [:])
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
