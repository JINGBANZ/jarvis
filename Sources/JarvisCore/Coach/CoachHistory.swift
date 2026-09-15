import Foundation

/// The session's conversation memory, CLIENT-managed: `CoachDriver` commits each finished turn here
/// and rebuilds every request as `[system] + snapshot() + <this turn>`. Owning the memory (instead of
/// a server-side conversation object) is what lets the harness keep it small: screenshots are stubbed
/// at commit, `stay_silent` turns leave no trace, and once the estimate passes the compaction threshold
/// the oldest span is replaced with a short summary (see `CoachAttemptRunner.compactIfNeeded`).
///
/// Growth is strictly append-only between compactions — the message prefix stays byte-identical
/// across requests, which is exactly what OpenAI's prompt cache needs to keep hitting.
///
/// `@unchecked Sendable`: `lock` serializes every access to `messages` and `rewriteRevision`; any
/// future mutable state must use the same lock.
public final class CoachHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [ChatMessage] = []
    /// Bumped whenever committed messages are rewritten in place rather than merely appended to.
    /// Compaction reads history, then writes a summary of it much later from another task; growth in
    /// the tail is safe for that, but an in-place screen-text collapse is not, because the summary
    /// would reintroduce the very screen text the collapse just retired.
    private var rewriteRevision: UInt = 0

    public init() {}

    /// The full memory, oldest first. Callers prepend the system prompt and append the new turn.
    public func snapshot() -> [ChatMessage] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }

    /// Commit a finished turn's messages (the user delta, and any capture/speak calls with their
    /// results). A `stay_silent` call never enters memory, nor any result answering it: silence
    /// needs no memory, and a turn can carry one it did not end on, refused on a press or answered
    /// as not executed beside another call, whose refusal would otherwise replay to every later
    /// request, including automatic turns where staying silent is right. Two kinds of message are
    /// rewritten at commit:
    /// - **Screenshots** are replaced with a text stub (observation masking). The capture's text
    ///   evidence — what the model actually reads — rides in the tool-result message and stays
    ///   verbatim; the
    ///   pixels are ~1–2k tokens re-billed on every later request, and the model can always capture
    ///   a fresh look. When the turn carries NEW screen text, every earlier evidence dump — committed
    ///   history and any older capture within the same turn — collapses to a one-line stub:
    ///   near-identical screens re-billed forever, and a session-audit caught the model
    ///   "correcting" code the user had already fixed by reading a stale dump. Unlike the two
    ///   tail-local rewrites above, this one re-diverges the prompt-cache prefix at the oldest
    ///   collapsed block. That is deliberate: a bounded one-request re-read per capture buys back
    ///   ~1k stale tokens per dump on every later request plus the stale-context failure mode above.
    ///   A local provider receives the complete committed history once at the start of an attempt;
    ///   any capture continuation on that attempt carries only incremental input.
    /// - **Raw passthrough items** (a response's verbatim `output` array, replayed whole within the
    ///   turn's tool loop) are CONVERTED, not kept: the `function_call` items survive as one
    ///   synthetic id-less call message — so the committed `function_call_output` never orphans —
    ///   and `reasoning` (and any other) items are dropped. OpenAI only needs reasoning WITHIN the
    ///   turn's tool loop; across turns a new user message follows and stale reasoning is ignored,
    ///   retaining it would re-bill every later request, and a brain-model switch invalidates
    ///   reasoning items outright. The id-less call + output pair is the long-proven history shape.
    /// Both rewrites cost one prompt-cache divergence at the tail of the just-finished turn — far
    /// cheaper than re-billing the content on every request for the rest of the session.
    public func commit(_ turn: [ChatMessage]) {
        guard !turn.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        // Raw passthrough items convert first, so a `stay_silent` call among them is found too.
        var turn = Self.droppingSilence(turn.compactMap { m -> ChatMessage? in
            guard let raw = m.rawItemsJSON else { return m }
            return Self.convertRawItems(raw)
        })
        let screenTextHeader = JarvisPrompts.Coach.screenTextHeader
        if let newest = turn.lastIndex(where: { $0.text?.contains(screenTextHeader) == true }) {
            messages = messages.map(Self.collapsingSupersededScreenText)
            rewriteRevision &+= 1
            // One tool loop may capture more than once — only its newest text evidence stays verbatim.
            for i in turn.indices where i < newest {
                turn[i] = Self.collapsingSupersededScreenText(turn[i])
            }
        }
        messages.append(contentsOf: turn.map { m in
            m.imageBase64JPEG != nil
                ? .user(JarvisPrompts.Coach.earlierImageStub)
                : m
        })
    }

    /// The turn without its `stay_silent` calls and the results answering them. A call message
    /// keeps its other calls, so every call left in memory still has its result.
    private static func droppingSilence(_ turn: [ChatMessage]) -> [ChatMessage] {
        let silent = Set(turn.flatMap { $0.toolCalls ?? [] }
            .filter { $0.name == staySilentTool.name }
            .map(\.id))
        guard !silent.isEmpty else { return turn }
        return turn.compactMap { m in
            if let id = m.toolCallId, silent.contains(id) { return nil }
            guard let calls = m.toolCalls, calls.contains(where: { silent.contains($0.id) }) else {
                return m
            }
            let kept = calls.filter { !silent.contains($0.id) }
            guard !kept.isEmpty || m.text != nil else { return nil }
            return ChatMessage(
                role: m.role, text: m.text, imageBase64JPEG: m.imageBase64JPEG,
                toolCallId: m.toolCallId, toolCalls: kept.isEmpty ? nil : kept)
        }
    }

    /// Rewrite one committed message so its screen-text block becomes the superseded marker.
    /// Text before the block — e.g. a successful capture result — survives.
    private static func collapsingSupersededScreenText(_ m: ChatMessage) -> ChatMessage {
        guard let text = m.text,
              let header = text.range(of: JarvisPrompts.Coach.screenTextHeader)
        else { return m }
        return ChatMessage(
            role: m.role,
            text: String(text[..<header.lowerBound])
                + JarvisPrompts.Coach.supersededScreenTextStub,
            toolCallId: m.toolCallId
        )
    }

    /// The commit-time conversion of a verbatim passthrough message: keep its `function_call` items
    /// as one synthetic id-less `assistantToolCalls` message, drop everything else. Nil when the
    /// items carried no function call — nothing a later turn can use.
    private static func convertRawItems(_ itemsJSON: [String]) -> ChatMessage? {
        let calls = itemsJSON.compactMap { itemJSON -> RawToolCall? in
            guard let item = (try? JSONSerialization.jsonObject(with: Data(itemJSON.utf8))) as? [String: Any],
                  item["type"] as? String == "function_call",
                  let callId = item["call_id"] as? String,
                  let name = item["name"] as? String else { return nil }
            return RawToolCall(id: callId, name: name,
                               argumentsJSON: item["arguments"] as? String ?? "{}")
        }
        return calls.isEmpty ? nil : .assistantToolCalls(calls)
    }

    /// Rough size of the memory in tokens — used only to decide WHEN to compact. ASCII text uses the
    /// common chars/4 heuristic; every non-ASCII scalar counts as one so Chinese and other scripts do
    /// not wait several times too long. No image term: screenshots are stubbed to text at commit.
    public var estimatedTokens: Int {
        lock.lock(); defer { lock.unlock() }
        return Self.estimate(messages)
    }

    private static func estimate(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { total, m in
            var t = total + (m.text.map(estimatedTextTokens) ?? 0)
            if let calls = m.toolCalls {
                t += calls.reduce(0) { $0 + estimatedTextTokens($1.argumentsJSON) + 8 }
            }
            return t
        }
    }

    private static func estimatedTextTokens(_ text: String) -> Int {
        var asciiCount = 0
        var nonASCIICount = 0
        for scalar in text.unicodeScalars {
            if scalar.value < 128 {
                asciiCount += 1
            } else {
                nonASCIICount += 1
            }
        }
        return ((asciiCount + 3) / 4) + nonASCIICount
    }

    /// The oldest span to summarize: the longest message prefix holding roughly `fraction` of the
    /// estimated tokens — clamped to at least one message (a single oversized message must still be
    /// compactable) and never the whole history (the newest turn stays verbatim). Returns nil when
    /// there's a single message or none, or when no boundary leaves every tool call answered.
    ///
    /// The returned messages are what the summarizer reads: the pairs `compact` will keep verbatim
    /// are left out, so their text is never duplicated into the summary that sits above them.
    public func compactionPrefix(fraction: Double = 0.6)
        -> (messages: [ChatMessage], count: Int, revision: UInt)? {
        lock.lock(); defer { lock.unlock() }
        guard messages.count > 1 else { return nil }
        let budget = Int(Double(Self.estimate(messages)) * fraction)
        var used = 0, count = 0
        for m in messages {
            let cost = Self.estimate([m])
            if used + cost > budget { break }
            used += cost; count += 1
        }
        count = Self.pairSnapped(min(max(count, 1), messages.count - 1), in: messages)
        guard count >= 1 else { return nil }
        let prefix = Array(messages.prefix(count))
        let retained = Set(Self.retainedIndices(in: prefix))
        let summarizable = prefix.indices.filter { !retained.contains($0) }.map { prefix[$0] }
        // A span that is nothing but retained pairs has nothing to summarize: compacting it would
        // spend a provider round trip on an empty prompt and stack a summary of nothing on top of
        // the pairs it kept. Skip the pass; a later one starts from a prefix that reaches real turns.
        guard !summarizable.isEmpty else { return nil }
        return (summarizable, count, rewriteRevision)
    }

    /// A prefix boundary must never fall between an assistant message carrying tool calls and the
    /// `.tool` message answering it: the summary would replace the call and orphan its output,
    /// which providers reject. Snap forward to include the answer, and when that would consume the
    /// whole history, snap back to leave the pair out of the summary entirely.
    private static func pairSnapped(_ count: Int, in messages: [ChatMessage]) -> Int {
        var forward = count
        while forward < messages.count - 1, splitsPair(messages, at: forward) { forward += 1 }
        if !splitsPair(messages, at: forward) { return forward }
        var back = count
        while back > 0, splitsPair(messages, at: back) { back -= 1 }
        return back
    }

    private static func splitsPair(_ messages: [ChatMessage], at count: Int) -> Bool {
        let calledBefore = Set(messages.prefix(count).flatMap { $0.toolCalls ?? [] }.map(\.id))
        guard !calledBefore.isEmpty else { return false }
        let answeredAfter = Set(messages.dropFirst(count).compactMap(\.toolCallId))
        return !calledBefore.isDisjoint(with: answeredAfter)
    }

    /// Tool calls whose results the model must keep word for word after a summary: a loaded tool's
    /// schema and guidance, or a loaded skill's body, are the only copy it has, and summarizing
    /// them away mid-session would leave it holding a capability it can no longer use correctly.
    public static let retainedToolNames: Set<String> =
        [CoachCapabilities.loadToolName, CoachCapabilities.loadSkillName]

    /// The call/result pairs inside `messages` that survive compaction verbatim, in order.
    public static func retainedPairs(in messages: [ChatMessage]) -> [ChatMessage] {
        retainedIndices(in: messages).map { messages[$0] }
    }

    private static func retainedIndices(in messages: [ChatMessage]) -> [Int] {
        var answeredIDs: Set<String> = []
        var kept: [Int] = []
        for (index, message) in messages.enumerated() {
            if let calls = message.toolCalls,
               calls.contains(where: { retainedToolNames.contains($0.name) }) {
                answeredIDs.formUnion(calls.map(\.id))
                kept.append(index)
            } else if let id = message.toolCallId, answeredIDs.contains(id) {
                kept.append(index)
            }
        }
        return kept
    }

    /// Replace the oldest `prefixCount` messages with a single summary message, followed by the
    /// pairs `retainedPairs` says must survive verbatim. Tolerates the tail
    /// having grown while the summary was being written — only the exact prefix handed out by
    /// `compactionPrefix` is replaced. One deliberate prompt-cache miss; cache-hot again afterwards.
    ///
    /// Rejects a summary written against a since-rewritten prefix, reporting whether it applied. The
    /// summary is produced off the attempt path, so a capture committed meanwhile can collapse text
    /// inside that prefix; applying the older summary would put the retired screen text straight back
    /// into history and let a later tip cite code the user has already changed. Dropping it is safe —
    /// history is unchanged and the next completed attempt compacts again from a fresh prefix.
    @discardableResult
    public func compact(prefixCount: Int, summary: String, revision: UInt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard prefixCount > 0, prefixCount <= messages.count else { return false }
        guard revision == rewriteRevision else { return false }
        let head = ChatMessage.user(JarvisPrompts.Coach.condensedHistory(summary))
        let retained = Self.retainedPairs(in: Array(messages.prefix(prefixCount)))
        messages.replaceSubrange(0..<prefixCount, with: [head] + retained)
        return true
    }
}
