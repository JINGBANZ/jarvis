import Foundation

/// Append-only between compactions, so the prefix stays byte-identical for OpenAI's prompt cache.
/// @unchecked Sendable: `lock` guards all mutable state.
public final class CoachHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [ChatMessage] = []
    /// Bumped on in-place rewrites. A summary started before one must be dropped, or it would
    /// reintroduce the screen text the rewrite retired.
    private var rewriteRevision: UInt = 0

    public init() {}

    public func snapshot() -> [ChatMessage] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }

    /// Drops `stay_silent` calls and refused prose, which would otherwise replay on every later
    /// request, and stubs screenshots. New screen text collapses all older screen text, breaking
    /// the cache prefix on purpose: stale dumps led the model to "fix" code the user had already
    /// fixed.
    public func commit(_ turn: [ChatMessage]) {
        guard !turn.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        // Raw items go first so a `stay_silent` call among them is dropped too. Their reasoning matters
        // only within the tool loop and would be re-billed on every later request.
        var turn = Self.droppingRefusedProse(Self.droppingSilence(turn.compactMap { m -> ChatMessage? in
            guard m.rawItemsJSON != nil else { return m }
            guard let calls = m.toolCalls, !calls.isEmpty else { return nil }
            return .assistantToolCalls(calls)
        }))
        let screenTextHeader = JarvisPrompts.Coach.screenTextHeader
        if let newest = turn.lastIndex(where: { $0.text?.contains(screenTextHeader) == true }) {
            messages = messages.map(Self.collapsingSupersededScreenText)
            rewriteRevision &+= 1
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

    private static func droppingRefusedProse(_ turn: [ChatMessage]) -> [ChatMessage] {
        let nudges = Set([true, false].map { JarvisPrompts.Coach.replyMustCallSpeak(detailEnabled: $0) })
        guard turn.contains(where: { $0.role == .user && $0.text.map(nudges.contains) == true })
        else { return turn }
        var kept: [ChatMessage] = []
        for m in turn {
            if m.role == .user, let text = m.text, nudges.contains(text) {
                if let last = kept.last, last.role == .assistant, last.toolCalls == nil {
                    kept.removeLast()
                }
                continue
            }
            kept.append(m)
        }
        return kept
    }

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

    /// ASCII counts chars/4 and each non-ASCII scalar one token, so CJK text isn't undercounted.
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

    /// `messages` is the prefix minus retained pairs; pass `count` and `revision` to `compact`. Nil
    /// when no boundary leaves every tool call answered or nothing is left to summarize.
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
        guard !summarizable.isEmpty else { return nil }
        return (summarizable, count, rewriteRevision)
    }

    /// Never split a tool call from its result: providers reject an orphaned output.
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

    /// Kept verbatim through compaction: a loaded schema or skill body is the model's only copy.
    public static let retainedToolNames: Set<String> =
        [CoachCapabilities.loadToolName, CoachCapabilities.loadSkillName]

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

    /// The tail may have grown since `compactionPrefix`. Returns false, leaving history unchanged,
    /// when `revision` is stale.
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
