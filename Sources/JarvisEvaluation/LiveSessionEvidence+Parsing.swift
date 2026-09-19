import Foundation
import JarvisBrainProviders
import JarvisCore

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
                    : nil,
                response: (object["response"] as? [String: Any]).flatMap(activityResponse))
        }
    }

    /// Mirrors `ActivityEvent.rendered`: `📎 loaded the <name> <tool|skill>`.
    static func loadedCapability(fromMessage message: String) -> LoadedCapability? {
        guard message.hasPrefix(loadedMessagePrefix) else { return nil }
        let rest = message.dropFirst(loadedMessagePrefix.count)
        guard let space = rest.lastIndex(of: " ") else { return nil }
        let name = String(rest[..<space])
        let kind = String(rest[rest.index(after: space)...])
        guard !name.isEmpty, ActivityEvent.CapabilityKind(rawValue: kind) != nil else { return nil }
        return LoadedCapability(name: name, kind: kind)
    }

    /// Mirrors `SessionAuditWorker.encodeAttempt`.
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

    /// `SessionAuditWorker` writes `t` as local `HH:mm:ss` with no date. Stamps are in file order,
    /// so one earlier than the last means midnight passed; the session start seeds that comparison.
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

    /// Mirrors `SessionDirectoryID.make`: a local-time stamp behind an optional build prefix, so
    /// search for the stamp rather than match the whole name.
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

    /// Mirrors `SessionAuditWorker.encodeTraffic`. A non-JSON request body is stored as a string
    /// and reads as empty.
    static func parseTraffic(_ object: [String: Any], index: Int) -> TrafficRecord {
        let context = object["coach_attempt"] as? [String: Any]
        let request = object["request"] as? [String: Any] ?? [:]
        let provider = object["provider"] as? String ?? request["provider"] as? String
        let exchange = RecordedExchange.read(request: request, response: object["response"])
        return TrafficRecord(
            index: index,
            tag: object["tag"] as? String ?? "",
            attemptID: context?["id"] as? Int,
            sourceTrigger: context?["source_trigger"] as? String,
            status: object["status"] as? Int,
            error: object["error"] as? String,
            provider: provider,
            instructions: exchange.instructions,
            declaredToolNames: exchange.toolNames,
            toolChoiceType: exchange.toolChoiceType,
            replayedFunctionCalls: exchange.input.compactMap { item in
                guard case .call(let call) = item else { return nil }
                return FunctionCall(callID: call.id ?? "", name: call.name ?? "", arguments: call.arguments ?? "")
            },
            replayedFunctionOutputCallIDs: exchange.input.compactMap { item in
                guard case .result(let callID, _) = item else { return nil }
                return callID ?? ""
            },
            speakParameters: exchange.speakParameters,
            speakDetail: speakDetail(in: exchange))
    }

    /// Reports what the model wrote: a speak call the runner built from prose is absent from the
    /// response and reads as `.noSpeakCall`. Null and absent `detail` both read as `.none`, as in
    /// `ToolInvocation.parse`.
    static func speakDetail(in exchange: RecordedExchange) -> SpeakDetail {
        let call = exchange.outputs.lazy.compactMap { output -> RecordedExchange.Call? in
            guard case .call(let call) = output, call.name == speakToolName else { return nil }
            return call
        }.first
        guard let call else { return .noSpeakCall }
        let arguments = call.arguments.flatMap(jsonObject)
        guard let detail = arguments?["detail"] as? String else { return .none }
        return .present(detail)
    }

    static func activityResponse(_ object: [String: Any]) -> ActivityResponse? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(ActivityResponse.self, from: data)
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
