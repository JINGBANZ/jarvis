import Foundation

/// The model behind the human-facing activity viewer. It records the coaching exchange — heard
/// speech, manual hint requests, every brain action (screen view, tip, or deliberate silence), and
/// fixed non-sensitive notices when a brain change succeeds, a route advances, degrades, or stops. It
/// pushes those entries into an in-app `WKWebView` window (see `ActivityViewer` in JarvisApp) and
/// persists them so past sessions can be browsed later. Detailed diagnostics belong exclusively in
/// `JarvisLog`.
///
/// This type is UI-free (Foundation only): it generates the page HTML and the per-row JS as plain
/// strings; the WebView lives in JarvisApp. See wiki/build-and-run.md.
public final class ActivityLog: @unchecked Sendable {
    public static let shared = ActivityLog()
    public static let filename = "jarvis-activity.jsonl"

    /// Stable on-disk identity for each typed Activity event. Human copy and emoji may evolve; tools
    /// reading the complete log can use this value instead of reverse-parsing prose.
    public enum EventKind: String, Codable, CaseIterable, Sendable {
        case heard
        case manualHint
        case screenViewed
        case screenViewFailed
        case tip
        case stayedSilent
        case coachingStopped
        case coachingTurnFailed
        case transcriptionStopped
        case audioCaptureStopped
        case systemAudioStopped
        case settingsChangeNotApplied
        case brainChangeApplied
        case brainFallback
        case brainFailover
        case brainPrimaryRecovered
        case brainRecoveryDeferred
        case brainFallbackUnavailable
        case brainRouteAdvanced
        case brainRouteTargetSkipped
        case brainRouteExhausted
    }

    /// A human-visible event in the coaching exchange. Keeping this closed set typed prevents
    /// transport, retry, error details, and other diagnostic strings from leaking into the activity
    /// viewer through a generic logging call.
    public enum Event: Sendable {
        /// A finalized utterance from the user (`me`) or interviewer (`them`).
        case heard(speaker: Speaker, text: String)
        /// The user explicitly requested help through the manual-hint shortcut.
        case manualHint(prompt: String)
        /// Jarvis captured and viewed the screen while preparing a coaching response.
        case screenViewed(imageBase64JPEG: String)
        /// The brain chose to view the screen, but capture failed. Activity gets fixed recovery
        /// guidance while raw failure detail stays in debug.
        case screenViewFailed
        /// Jarvis displayed these coaching lines to the user.
        case tip(lines: [String])
        /// The brain explicitly chose `stay_silent` for this turn.
        case stayedSilent
        /// Coaching ended because the selected brain could not respond. Carries only the provider,
        /// never the raw error, so the notice cannot expose provider diagnostics during screen
        /// sharing.
        case coachingStopped(provider: BrainProvider)
        /// One coaching turn failed temporarily while capture and transcription remain live. The
        /// provider identity is enough for fixed recovery copy; raw error detail stays in debug.
        case coachingTurnFailed(provider: BrainProvider)
        /// The session ended because transcription became unusable. Carries a fixed, typed reason;
        /// raw provider and transport details remain exclusively in diagnostics.
        case transcriptionStopped(reason: TranscriptionFailureReason)
        /// Coaching ended because the running audio capture became unavailable. No device or route
        /// detail is carried; the fixed copy points to diagnostics.
        case audioCaptureStopped
        /// The secondary system-audio transcription stopped while microphone coaching continued.
        case systemAudioStopped
        /// An explicit Settings reapply failed its preflight while the existing session continued.
        case settingsChangeNotApplied
        /// A live brain replacement completed its first non-truncated terminal turn. Provider
        /// identities are enough for a fixed human-facing success notice; model transport details
        /// remain in jlog.
        case brainChangeApplied(previous: BrainProvider, current: BrainProvider)
        /// A failed target was exhausted and the next user-authorized route target became active.
        case brainRouteAdvanced(previous: BrainProvider, current: BrainProvider)
        /// A route target was proven unavailable before a provider request could be constructed.
        case brainRouteTargetSkipped(provider: BrainProvider)
        /// Every user-authorized target was exhausted, so coaching stopped.
        case brainRouteExhausted(lastProvider: BrainProvider)

        var kind: EventKind {
            switch self {
            case .heard: .heard
            case .manualHint: .manualHint
            case .screenViewed: .screenViewed
            case .screenViewFailed: .screenViewFailed
            case .tip: .tip
            case .stayedSilent: .stayedSilent
            case .coachingStopped: .coachingStopped
            case .coachingTurnFailed: .coachingTurnFailed
            case .transcriptionStopped: .transcriptionStopped
            case .audioCaptureStopped: .audioCaptureStopped
            case .systemAudioStopped: .systemAudioStopped
            case .settingsChangeNotApplied: .settingsChangeNotApplied
            case .brainChangeApplied: .brainChangeApplied
            case .brainRouteAdvanced: .brainRouteAdvanced
            case .brainRouteTargetSkipped: .brainRouteTargetSkipped
            case .brainRouteExhausted: .brainRouteExhausted
            }
        }
    }

    /// One recorded line. `imageFile` is the relative `shot-N.jpg` name on disk (the bytes the DOM
    /// renders are passed separately as base64), or nil for a plain text line.
    public struct Entry: Sendable, Equatable {
        public let time: String
        public let message: String
        public let imageFile: String?
        public init(time: String, message: String, imageFile: String?) {
            self.time = time; self.message = message; self.imageFile = imageFile
        }
    }

    /// The atomic cut point returned by `attach`: the empty page shell plus the current entries
    /// already encoded as `appendRow(...)` snippets to replay. `shown` = rows in the snapshot
    /// (capped at `maxLines`); `total` = everything recorded this session (for "showing last N of M").
    public struct Snapshot: Sendable {
        public let shellHTML: String
        public let rows: [String]
        public let shown: Int
        public let total: Int
    }

    /// On-disk line format for `jarvis-activity.jsonl` (one JSON object per line).
    private struct PersistedEntry: Codable {
        let t: String       // time, HH:mm:ss
        let m: String       // message
        let s: String?      // shot filename, if any
        let k: EventKind?   // stable event identity; nil only for backward-compatible old rows
    }

    /// In-memory replay cap for a late-attaching viewer. Sized for hours of coaching (an hour-long
    /// session logs a few thousand lines) — a cap this high exists only as a runaway backstop, so the
    /// viewer shows the WHOLE session, not just its tail. Entries are small (text + a filename; shot
    /// bytes stay on disk), so memory is not a concern.
    private let maxLines = 10_000
    private let queue = DispatchQueue(label: "jarvis.activitylog")   // serializes state + disk writes
    private var entries: [Entry] = []
    private var totalCount = 0    // everything recorded this session (survives the maxLines cap)
    private var shotSeq = 0       // monotonic id for saved screenshot files this session
    private let df: DateFormatter
    private var dir: URL?         // nil ⇒ disabled (no observer pushes, no disk writes)
    private var onAppend: ((String) -> Void)?

    /// Internal so tests can spin up an isolated instance; the app uses `.shared`.
    init() {
        df = DateFormatter()
        // Fixed-format formatter: pin to en_US_POSIX + Gregorian so output is stable regardless of
        // the user's locale or system calendar (Apple QA1480).
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "HH:mm:ss"
    }

    /// Turn on the viewer for a session. `directory` is this session's dir; an empty
    /// `jarvis-activity.jsonl` is created at 0600 immediately so the session is discoverable by
    /// `SessionStore.listSessions()` even before its first event.
    public func enable(directory: URL) {
        queue.sync {
            dir = directory
            entries.removeAll(); totalCount = 0; shotSeq = 0; onAppend = nil
            let url = directory.appendingPathComponent(Self.filename)
            FileManager.default.createFile(atPath: url.path, contents: Data(),
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    /// Turn the viewer back off (no further pushes or disk writes).
    public func disable() {
        queue.sync { dir = nil; entries.removeAll(); totalCount = 0; shotSeq = 0; onAppend = nil }
    }

    /// Append one human-facing coaching event: persist it, then push it to the observer. No-op when
    /// disabled. Call `jlog` instead for diagnostics.
    ///
    /// When a screen-view event carries a base64 JPEG, the `.jpg` is written **first** (owner-only)
    /// and then the `.jsonl` line referencing it — so a persisted reference always points at a file
    /// that exists.
    public func record(_ event: Event, at date: Date = Date()) {
        let kind = event.kind
        let message: String
        let imageBase64: String?
        switch event {
        case .heard(let speaker, let text):
            message = "🗣 heard (\(speaker.rawValue)): \"\(text)\""
            imageBase64 = nil
        case .manualHint(let prompt):
            message = "⌨️ hint shortcut — \(prompt)"
            imageBase64 = nil
        case .screenViewed(let imageBase64JPEG):
            message = "👁 looking at your screen"
            imageBase64 = imageBase64JPEG
        case .screenViewFailed:
            message = "👁 couldn't view your screen — screen capture failed; check Screen Recording permission"
            imageBase64 = nil
        case .tip(let lines):
            message = "💬 \(lines.joined(separator: " "))"
            imageBase64 = nil
        case .stayedSilent:
            message = "🤫 stayed silent — nothing useful to add"
            imageBase64 = nil
        case .coachingStopped(let provider):
            message = "⏹ coaching stopped — \(provider.displayName) couldn't respond; check Settings → Brain"
            imageBase64 = nil
        case .coachingTurnFailed(let provider):
            message = "⚠️ \(provider.displayName) couldn't respond this turn — listening continues"
            imageBase64 = nil
        case .transcriptionStopped(let reason):
            message = "⏹ session failed — \(reason.activityDescription)"
            imageBase64 = nil
        case .audioCaptureStopped:
            message = "⏹ coaching stopped — audio capture became unavailable; check jarvis-debug.log"
            imageBase64 = nil
        case .systemAudioStopped:
            message = "⚠️ system audio stopped — microphone coaching continues; check jarvis-debug.log"
            imageBase64 = nil
        case .settingsChangeNotApplied:
            message = "⚠️ settings change wasn't applied — current coaching session continues; check Settings → Brain"
            imageBase64 = nil
        case .brainChangeApplied(let previous, let current):
            if previous == current {
                message = "🧠 brain change applied — \(current.displayName) setup is active"
            } else {
                message = "🧠 brain switch applied — \(previous.displayName) → \(current.displayName)"
            }
            imageBase64 = nil
        case .brainRouteAdvanced(let previous, let current):
            if previous == current {
                message = "⚠️ \(previous.displayName) target couldn't respond — continuing with the next \(current.displayName) model"
            } else {
                message = "⚠️ \(previous.displayName) couldn't respond — continuing on \(current.displayName)"
            }
            imageBase64 = nil
        case .brainRouteTargetSkipped(let provider):
            message = "⚠️ \(provider.displayName) fallback is unavailable — continuing to the next fallback target"
            imageBase64 = nil
        case .brainRouteExhausted(let provider):
            message = "⏹ coaching stopped — every fallback target was exhausted; last target: \(provider.displayName)"
            imageBase64 = nil
        }
        queue.async { [self] in
            guard let dir else { return }
            let shotName = imageBase64.flatMap { saveShot($0, in: dir) }
            let entry = Entry(time: df.string(from: date), message: message, imageFile: shotName)
            appendJSONL(entry, kind: kind, in: dir)
            entries.append(entry)
            totalCount += 1
            if entries.count > maxLines { entries.removeFirst(entries.count - maxLines) }
            // Push with the live bytes in hand (no disk read on the hot path).
            onAppend?(Self.rowScript(time: entry.time, message: entry.message, imageBase64: imageBase64))
        }
    }

    /// Atomically register the live observer and capture the current snapshot, so every subsequent
    /// entry arrives via `onAppend` exactly once — never double-rendered or missed. Snapshot rows
    /// re-read their screenshot bytes from disk (a rare, one-shot cost when the viewer opens).
    public func attach(_ onAppend: @escaping (String) -> Void) -> Snapshot {
        queue.sync {
            self.onAppend = onAppend
            let rows: [String] = entries.map { e in
                let b64: String? = e.imageFile.flatMap { name in
                    guard let dir else { return nil }
                    return (try? Data(contentsOf: dir.appendingPathComponent(name)))?.base64EncodedString()
                }
                return Self.rowScript(time: e.time, message: e.message, imageBase64: b64)
            }
            return Snapshot(shellHTML: Self.htmlShell(), rows: rows, shown: entries.count, total: totalCount)
        }
    }

    /// Stop pushing to the observer (e.g. while the viewer shows a *past* session).
    public func detach() { queue.sync { onAppend = nil } }

    /// Wait until every event recorded before this call is persisted. Session teardown and
    /// evaluation use this barrier so a just-recorded catastrophic outcome cannot race the evaluator.
    public func flush() {
        queue.sync {}
    }

    /// Decode a base64 JPEG and write it as the next owner-only `shot-N.jpg` in `dir`. Returns the
    /// relative filename, or nil if the payload was invalid / the write failed. Must run on `queue`.
    private func saveShot(_ base64: String, in dir: URL) -> String? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        shotSeq += 1
        let name = "shot-\(shotSeq).jpg"
        guard FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path,
                                             contents: data, attributes: [.posixPermissions: 0o600])
        else { return nil }
        return name
    }

    /// Append one JSON line to `jarvis-activity.jsonl`. Best-effort; a failed write just means that
    /// line won't survive into history (the live push already happened). Must run on `queue`.
    private func appendJSONL(_ entry: Entry, kind: EventKind, in dir: URL) {
        let pe = PersistedEntry(t: entry.time, m: entry.message, s: entry.imageFile, k: kind)
        guard let data = try? JSONEncoder().encode(pe) else { return }
        let url = dir.appendingPathComponent(Self.filename)
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
        try? fh.write(contentsOf: Data([0x0A]))   // newline
    }

    // MARK: - Pure rendering (testable without a WebView)

    /// The JS call that renders one row. Pushed to `evaluateJavaScript` (live) or replayed from a
    /// snapshot. The payload is a JSON object literal; the page's JS sets text via `textContent` and
    /// the image via `img.src`, so the message is XSS-safe by construction and no HTML escaping is
    /// needed here. `imageBase64`, when present, becomes an in-memory `data:` URI.
    public static func rowScript(time: String, message: String, imageBase64: String?) -> String {
        struct Row: Encodable {
            let time: String
            let message: String
            let cls: String
            let img: String?
        }
        let row = Row(time: time, message: message, cls: cssClass(for: message),
                      img: imageBase64.map { "data:image/jpeg;base64,\($0)" })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]   // keep data: URIs readable (no \/ )
        guard let data = try? encoder.encode(row), let json = String(data: data, encoding: .utf8) else {
            return "appendRow({});"
        }
        return "appendRow(\(json));"
    }

    /// Colour class keyed on the line's **leading marker** (the intentional emoji prefix), not a
    /// substring match anywhere — so a coaching tip that happens to contain "failed" isn't
    /// mis-coloured as an error.
    static func cssClass(for message: String) -> String {
        let m = message.trimmingCharacters(in: .whitespaces)
        if m.hasPrefix("💬") { return "say" }
        if m.hasPrefix("👁") { return "see" }
        if m.hasPrefix("🗣") || m.hasPrefix("🤫 quiet") { return "hear" }
        if m.hasPrefix("🤫 stayed silent") || m.hasPrefix("💭") || m.hasPrefix("…") { return "think" }
        if m.hasPrefix("🧠") { return "think" }
        if m.hasPrefix("⏹ coaching stopped") { return "think" }
        if m.hasPrefix("⚠️") { return "think" }
        let low = m.lowercased()
        if low.contains("error") || low.contains("failed") || low.contains("denied") { return "err" }
        return ""
    }

    /// Whether a persisted row belongs in the human-facing viewer. New rows are guaranteed by the
    /// typed `Event` API; this also hides diagnostic rows from sessions written by older builds.
    static func isHumanFacing(message: String, imageFile: String?) -> Bool {
        if imageFile != nil { return true }
        let m = message.trimmingCharacters(in: .whitespaces)
        return m.hasPrefix("🗣 heard") || m.hasPrefix("⌨️ hint shortcut")
            || m.hasPrefix("👁 looking at your screen") || m.hasPrefix("👁 couldn't view your screen")
            || m.hasPrefix("💬") || m.hasPrefix("🤫 stayed silent")
            || m.hasPrefix("⏹ coaching stopped")
            || m.hasPrefix("⏹ session failed")
            || (m.hasPrefix("⚠️") && m.contains("couldn't respond this turn")
                && m.hasSuffix("listening continues"))
            || m.hasPrefix("⚠️ system audio stopped")
            || m.hasPrefix("⚠️ settings change wasn't applied")
            || m.hasPrefix("🧠 brain switch applied")
            || m.hasPrefix("🧠 brain change applied")
            || m.hasPrefix("⚠️ brain switch failed")
            || m.hasPrefix("⚠️ brain change failed")
    }

    /// The empty page shell: dark theme, a header with a live count, the row container, the lightbox
    /// overlay, and the JS that `appendRow`/`openShot`/`closeShot`/`clearRows`/`setMeta` drive. Rows
    /// are injected at runtime via `evaluateJavaScript`; no row HTML is rendered server-side, so the
    /// page never embeds untrusted text and there is no reload.
    public static func htmlShell() -> String {
        """
        <!doctype html><html lang="en"><head>
        <meta charset="utf-8">
        <title>Jarvis Activity</title>
        <style>
          :root { color-scheme: dark; }
          body { margin: 0; background: #0d1117; color: #c9d1d9;
                 font: 13px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; }
          header { position: sticky; top: 0; padding: 10px 16px; background: #161b22;
                   border-bottom: 1px solid #30363d; font-weight: 600; z-index: 10; }
          header .count { color: #8b949e; font-weight: 400; }
          main { padding: 8px 16px 40px; }
          .row { display: flex; gap: 12px; padding: 1px 0; white-space: pre-wrap; }
          .t { color: #6e7681; flex: 0 0 auto; }
          .m { flex: 1 1 auto; }
          .say .m  { color: #3fb950; }
          .see .m  { color: #d29922; }
          .hear .m { color: #58a6ff; }
          .think .m{ color: #8b949e; }
          .err .m  { color: #f85149; }
          .shot { display: block; margin-top: 4px; width: fit-content; }
          .shot img { display: block; max-height: 140px; max-width: 280px;
                      border: 1px solid #30363d; border-radius: 6px; cursor: zoom-in; }
          .lightbox { position: fixed; inset: 0; z-index: 1000; display: none;
                      align-items: center; justify-content: center; cursor: zoom-out;
                      background: rgba(1, 4, 9, 0.85); }
          .lightbox.open { display: flex; }
          .lightbox img { max-width: 92vw; max-height: 92vh; border: 1px solid #30363d;
                          border-radius: 8px; box-shadow: 0 8px 40px rgba(0, 0, 0, 0.6); }
        </style></head><body>
        <header>Jarvis — activity log <span class="count" id="count"></span></header>
        <main id="log"></main>
        <div class="lightbox" id="lightbox"><img id="lightbox-img" alt="full-size screenshot"></div>
        <script>
          function appendRow(p){
            var log=document.getElementById('log');
            var row=document.createElement('div'); row.className='row '+(p.cls||'');
            var t=document.createElement('span'); t.className='t'; t.textContent=p.time||'';
            var m=document.createElement('span'); m.className='m'; m.textContent=p.message||'';
            if(p.img){
              var a=document.createElement('a'); a.className='shot'; a.href=p.img;
              var img=document.createElement('img'); img.src=p.img; img.alt='screenshot of the user\\'s screen';
              a.appendChild(img);
              a.addEventListener('click',function(e){e.preventDefault();openShot(p.img);});
              m.appendChild(a);
            }
            row.appendChild(t); row.appendChild(m); log.appendChild(row);
            var near=(window.innerHeight+window.scrollY)>=(document.body.scrollHeight-60);
            if(near) window.scrollTo(0,document.body.scrollHeight);
          }
          function openShot(src){ document.getElementById('lightbox-img').src=src;
            document.getElementById('lightbox').classList.add('open'); }
          function closeShot(){ var b=document.getElementById('lightbox');
            b.classList.remove('open'); document.getElementById('lightbox-img').removeAttribute('src'); }
          function clearRows(){ document.getElementById('log').innerHTML=''; }
          function setMeta(s){ document.getElementById('count').textContent=s; }
          document.addEventListener('keydown',function(e){ if(e.key==='Escape') closeShot(); });
          document.getElementById('lightbox').addEventListener('click',closeShot);
        </script>
        </body></html>
        """
    }
}
