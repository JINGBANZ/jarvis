#if JARVIS_LIVE_E2E
import AppKit
import Carbon.HIToolbox
import JarvisCore
import JarvisOverlay

@MainActor
final class ShortcutReplacementHarness: OverlayRendering {
    private let keyboard: HotkeyController
    private let mouse: MouseHotkeyController
    private let panel = OverlayBoxPanel()
    private let turns = TurnTaskBox()
    private var driver: CoachDriver?
    private var delivered: [String] = []
    private var progress: BrainReplyProgress?
    private var completed = false
    private static let actions: [CoachingShortcut] = [.hint, .explainMore, .showCode]

    init(defaults: UserDefaults) {
        let preferences = Self.actions.enumerated().map { index, shortcut in
            let preference = HotkeyPreferences(defaults: defaults, shortcut: shortcut)
            preference.combination = .init(keyCode: UInt32(18 + index), modifiers: [.command, .option, .control, .shift])
            preference.mouseCombination = .init(button: index + 2, modifiers: [.command, .option, .control, .shift])
            return preference
        }
        keyboard = HotkeyController(preferences: preferences)
        mouse = MouseHotkeyController(preferences: preferences)
        keyboard.onRequest = { [weak self] shortcut in
            guard let self, let driver = self.driver, let reason = shortcut.triggerReason else { return }
            let operation = driver.admitTrigger(reason)
            self.turns.run {
                let outcome = await operation()
                if outcome == .spoke { await MainActor.run { self.completed = true } }
            }
        }
        mouse.isEnabled = { [weak self] _ in self?.driver != nil }
        mouse.onRequest = { [weak self] shortcut in self?.keyboard.onRequest?(shortcut) }
    }

    func run() async throws {
        defer {
            driver = nil
            turns.cancelAll()
            Self.actions.forEach { keyboard.unregister($0) }
            panel.setSessionLive(false)
        }
        try require(keyboard.registered.count == Self.actions.count, "keyboard registration")
        for mode: CoachingMode in [.automatic, .manual] {
            for (index, action) in Self.actions.enumerated() {
                for mouseFirst in [false, true] {
                    for streaming in [false, true] {
                        try await checkReplacement(mode: mode, action: action,
                            replacement: Self.actions[(index + 1) % Self.actions.count],
                            mouseFirst: mouseFirst, streaming: streaming)
                    }
                }
            }
            for mouseFirst in [false, true] {
                try await checkRapidPresses(mode: mode, mouseFirst: mouseFirst)
            }
        }
        jlog("Signed shortcut replacement checks passed: keyboard/mouse dispatch, all coaching actions, automatic/manual")
    }

    private func checkReplacement(mode: CoachingMode, action: CoachingShortcut,
                                  replacement: CoachingShortcut, mouseFirst: Bool, streaming: Bool) async throws {
        let brain = ShortcutReplacementBrain(streamFirstReply: streaming)
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .them, text: "Explain the binary search invariant.", at: 0))
        let driver = CoachDriver(config: .default, transcript: transcript,
            route: .init(targets: [.init(target: .init(provider: .openAI, modelID: "synthetic"), brain: brain)]),
            screen: ShortcutReplacementScreen(), overlay: self, clock: SystemClock())
        driver.setMode(mode)
        self.driver = driver
        delivered = []
        progress = nil
        completed = false
        panel.setSessionLive(true)
        do {
            try dispatch(action, mouse: mouseFirst)
            try await wait { await brain.calls.count == 1 }
            if streaming { try await wait { self.progress != nil } }
            try dispatch(.hint, mouse: !mouseFirst)
            try dispatch(.showCode, mouse: mouseFirst)
            try dispatch(replacement, mouse: !mouseFirst)
            if streaming {
                try require(await brain.calls.count == 1 && progress != nil, "visible reply stays active")
                await brain.releaseFirstReply()
            } else {
                try await wait { self.delivered == ["replacement"] }
                await brain.releaseFirstReply()
            }
            try await wait { self.completed }
            let calls = await brain.calls
            let expectedReplies = streaming ? ["first reply", "replacement"] : ["replacement"]
            try require(calls.count == 2 && delivered == expectedReplies && progress == nil,
                        "replacement and protected streaming through keyboard and mouse in \(mode)")
            let expected = replacement == .hint ? "hint shortcut" : replacement.title
            try require(calls[1].compactMap(\.text).joined().contains(expected), "latest shortcut intent")
            if streaming {
                try require(calls[1].flatMap { $0.toolCalls ?? [] }.contains {
                    $0.argumentsJSON.contains("first reply")
                }, "queued shortcut sees the completed reply")
            }
            try require(driver.handledTranscriptCount == 1, "unconsumed speech commits once")
        } catch {
            await brain.releaseFirstReply()
            for task in turns.cancelAll() { await task.value }
            await driver.cancelBackgroundWork()?.value
            throw error
        }
        for task in turns.cancelAll() { await task.value }
        await driver.cancelBackgroundWork()?.value
        panel.setSessionLive(false)
    }

    private func checkRapidPresses(mode: CoachingMode, mouseFirst: Bool) async throws {
        let brain = ShortcutReplacementBrain(holdFirstReply: false)
        let driver = CoachDriver(config: .default, transcript: RollingTranscript(),
            route: .init(targets: [.init(target: .init(provider: .openAI, modelID: "synthetic"), brain: brain)]),
            screen: ShortcutReplacementScreen(), overlay: self, clock: SystemClock())
        driver.setMode(mode)
        self.driver = driver
        delivered = []
        progress = nil
        completed = false
        panel.setSessionLive(true)
        try dispatch(.hint, mouse: mouseFirst)
        try dispatch(.showCode, mouse: !mouseFirst)
        try await wait { self.completed }
        let calls = await brain.calls
        try require(calls.count == 1 && calls[0].compactMap(\.text).joined().contains("Show code")
                    && delivered == ["replacement"], "mixed bindings preserve physical press order")
        for task in turns.cancelAll() { await task.value }
        await driver.cancelBackgroundWork()?.value
        panel.setSessionLive(false)
    }

    private func dispatch(_ shortcut: CoachingShortcut, mouse useMouse: Bool) throws {
        if useMouse {
            let button = Int(shortcut.rawValue) + 1
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                mouseCursorPosition: .zero, mouseButton: .center) else { throw CocoaError(.coderValueNotFound) }
            event.flags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            try require(mouse.dispatchHarnessEvent(.otherMouseDown, event: event), "mouse down routes")
            try require(mouse.dispatchHarnessEvent(.otherMouseUp, event: event), "mouse up is consumed")
        } else {
            var event: EventRef?
            try require(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                0, EventAttributes(0), &event) == noErr, "create Carbon event")
            guard let event else { throw CocoaError(.coderValueNotFound) }
            defer { ReleaseEvent(event) }
            var identifier = EventHotKeyID(signature: 0x4A_52_56_53, id: shortcut.rawValue)
            try require(SetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr,
                "set Carbon identity")
            try require(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr, "Carbon dispatch")
        }
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            try require(ContinuousClock.now < deadline, "shortcut replacement deadline")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "ShortcutReplacementHarness", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    nonisolated func render(_ hint: String) {}
    func deliver(_ hint: String, detail: ReplyDetail?) -> ReplyDetail? {
        delivered.append(hint)
        progress = nil
        return panel.deliver(hint, detail: detail)
    }
    func showReplyProgress(_ progress: BrainReplyProgress?) {
        self.progress = progress
        panel.showReplyProgress(progress)
    }
}

private actor ShortcutReplacementBrain: BrainClient {
    private(set) var calls: [[ChatMessage]] = []
    private let holdFirstReply: Bool
    private let streamFirstReply: Bool
    private var firstReply: CheckedContinuation<Void, Never>?
    init(holdFirstReply: Bool = true, streamFirstReply: Bool = false) {
        self.holdFirstReply = holdFirstReply
        self.streamFirstReply = streamFirstReply
    }
    func releaseFirstReply() {
        firstReply?.resume()
        firstReply = nil
    }
    func makeConversation(progress: ToolCallProgressSink?) async throws -> any BrainConversation {
        Conversation(brain: self, progress: progress)
    }
    func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
        try await respond(messages, progress: nil)
    }
    private func respond(_ messages: [ChatMessage], progress: ToolCallProgressSink?) async throws -> BrainResponse {
        calls.append(messages)
        if holdFirstReply && calls.count == 1 {
            if streamFirstReply {
                _ = progress?(.init(index: 0, name: "speak", arguments: #"{"hint":"first reply","detail":"streaming"#))
            }
            await withCheckedContinuation { firstReply = $0 }
            return .init(toolCalls: [.speak(callId: "old", hint: "first reply")])
        }
        return .init(toolCalls: [.speak(callId: "new", hint: "replacement")])
    }
    private struct Conversation: BrainConversation {
        let brain: ShortcutReplacementBrain
        let progress: ToolCallProgressSink?
        func respond(messages: [ChatMessage], tools: [ToolDef], toolChoice: ToolChoice) async throws -> BrainResponse {
            try await brain.respond(messages, progress: progress)
        }
        func finish() async {}
    }
}

private struct ShortcutReplacementScreen: ScreenCapturing {
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? { nil }
    func makeAttemptCapture() -> any ScreenCapturing { self }
    func cancelCapture() {}
}
#endif
