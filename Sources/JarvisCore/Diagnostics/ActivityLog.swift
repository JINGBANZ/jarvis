import Foundation

/// The model behind the human-facing activity viewer. It records the coaching exchange — heard
/// speech, manual hint requests, every brain action (screen view, tip, or deliberate silence), and
/// fixed non-sensitive notices when a brain change succeeds, a route advances, degrades, or stops,
/// and one typed reason whenever the live session ends. It pushes those entries into an in-app
/// `WKWebView` window (see `ActivityViewer` in JarvisApp) and persists them so past sessions can be
/// browsed later. Detailed diagnostics belong exclusively in `JarvisLog`.
///
/// This type is UI-free (Foundation only): it generates the page HTML and the per-row JS as plain
/// strings; the WebView lives in JarvisApp. See wiki/build-and-run.md.
///
/// It is the terminal *projection* of the session-evidence stack, not a recorder: producers
/// admit one `SessionEvent` through `FileSessionAudit`, the one bounded worker persists the row and
/// its attachment, and this type renders and retains what the worker hands back
/// (wiki/lean-coaching-core.md, Phase 2).
public final class ActivityLog: @unchecked Sendable {
    public static let shared = ActivityLog()
    public static let filename = "jarvis-activity.jsonl"
    /// The fixed, human-safe notice shown when a session's evidence is known to be incomplete. It
    /// says the record has holes and nothing else: no transport, retry, timing, lifecycle, or raw
    /// error detail — that stays in the owner-only session folder. Not an `ActivityEvent`, because
    /// nothing happened in the coaching exchange; it is a property of the session's record.
    public static let incompleteEvidenceNotice = "incomplete record"
    public static let incompleteEvidenceDetail =
        "Some of this session's activity could not be saved." 
    /// Shared live/history backstop. Both paths retain insertion identities first, then ask
    /// `ConversationChronology` to display those retained entries by event time.
    public static let retainedEntryLimit = 10_000

    /// One recorded line. `imageFile` is the relative `shot-N.jpg` name on disk (the bytes the DOM
    /// renders are passed separately as base64), or nil for a plain text line.
    public struct Entry: Sendable, Equatable {
        public let time: String
        public let message: String
        public let imageFile: String?
        /// Numeric event time and stable insertion tie-breaker. Both are nil for old or mixed
        /// sessions that cannot be reordered safely.
        public let occurredAt: TimeInterval?
        public let insertionOrder: UInt64?
        public init(
            time: String,
            message: String,
            imageFile: String?,
            occurredAt: TimeInterval? = nil,
            insertionOrder: UInt64? = nil
        ) {
            self.time = time
            self.message = message
            self.imageFile = imageFile
            self.occurredAt = occurredAt
            self.insertionOrder = insertionOrder
        }
    }

    /// The atomic cut point returned by `attach`: the empty page shell plus the current entries
    /// already encoded as `appendRow(...)` snippets to replay. `shown` = rows in the snapshot
    /// (capped at `retainedEntryLimit`); `total` = everything recorded this session (for
    /// "showing last N of M").
    public struct Snapshot: Sendable {
        public let shellHTML: String
        public let rows: [String]
        public let shown: Int
        public let total: Int
        /// False when this session is known to have lost evidence, so the window can say so
        /// instead of presenting an apparently complete story.
        public let evidenceIsComplete: Bool
    }

    /// On-disk line format for `jarvis-activity.jsonl` (one JSON object per line).
    private struct PersistedEntry: Codable {
        let t: String       // time, HH:mm:ss
        let m: String       // message
        let s: String?      // shot filename, if any
        let k: ActivityEvent.Kind?  // stable event identity; nil only for backward-compatible old rows
        let o: TimeInterval? // event occurrence time (Unix seconds)
        let q: UInt64?      // stable insertion tie-breaker
        let r: TimeInterval? // record/completion time (Unix seconds), for chronology diagnosis
    }

    /// Why a row did not become a persistable row, so the worker can tell an intended drop from a
    /// lost one. A session that already ended refuses later rows by design; a projection that has
    /// rotated to the next session cannot give this row a chronology entry, and that loss is real.
    enum Admission {
        case row(AdmittedRow)
        /// This session's terminal marker was already recorded. Dropping later rows is the contract.
        case sessionEnded
        /// The window moved on to another session before the worker drained this row.
        case notCurrent
    }

    /// One row that has been given its place in the session's chronology and is ready to be
    /// persisted and pushed. Building it is the projection's decision; writing it is the evidence
    /// worker's job.
    struct AdmittedRow {
        /// The `jarvis-activity.jsonl` line, without its trailing newline.
        let line: Data
        /// The live `appendRow(...)` payload for an attached viewer.
        let script: String
    }

    /// In-memory replay cap for a late-attaching viewer. Sized for hours of coaching (an hour-long
    /// session logs a few thousand lines) — a cap this high exists only as a runaway backstop, so the
    /// viewer shows the WHOLE session, not just its tail. Entries are small (text + a filename; shot
    /// bytes stay on disk), so memory is not a concern.
    ///
    /// The lock replaces this type's former private serial queue. Admission and publication run on
    /// the one evidence worker; `attach`/`detach` run on the viewer's thread. It is held only across
    /// in-memory bookkeeping — no disk access happens behind it any more.
    private let lock = NSLock()
    private var entries = ConversationChronology<Entry>()
    private var totalCount = 0    // everything recorded this session (survives the retained-entry cap)
    private var shotSeq = 0       // monotonic id for saved screenshot files this session
    private var sessionHasEnded = false
    private let df: DateFormatter
    private var dir: URL?         // nil ⇒ disabled (no observer pushes)
    /// Which session is on screen. The worker drains asynchronously, so a stopped session's rows
    /// and its close can arrive after a replacement Start has rotated this projection. Every entry
    /// point below is scoped by this identity: late work from the old session reaches its own
    /// files, never the new session's window (wiki/lean-coaching-core.md, "A New Session After
    /// Stop → Start").
    private var sessionID: UUID?
    private var onAppend: ((String) -> Void)?
    /// Last completeness the evidence worker reported for this session. Health counters are
    /// monotonic, so this only ever moves from true to false — one notice, never a flicker.
    private var evidenceIsComplete = true

    /// Internal so tests can spin up an isolated instance; the app uses `.shared`.
    init() {
        df = DateFormatter()
        // Fixed-format formatter: pin to en_US_POSIX + Gregorian so output is stable regardless of
        // the user's locale or system calendar (Apple QA1480).
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "HH:mm:ss"
    }

    /// Turn on the viewer for a session. `directory` is this session's dir, used to re-read
    /// screenshot bytes when a viewer attaches late, and `session` is the evidence handle's
    /// identity, which scopes every later call from the worker. The empty owner-only
    /// `jarvis-activity.jsonl` that makes the session discoverable by `SessionStore.listSessions()`
    /// is created by the evidence worker when it opens the session, alongside every other evidence
    /// file.
    public func enable(directory: URL, session: UUID) {
        lock.withLock {
            dir = directory
            sessionID = session
            entries.removeAll(); totalCount = 0; shotSeq = 0; sessionHasEnded = false; onAppend = nil
            evidenceIsComplete = true
        }
    }

    /// Turn the viewer back off (no further pushes).
    public func disable() {
        lock.withLock {
            dir = nil
            sessionID = nil
            entries.removeAll()
            totalCount = 0
            shotSeq = 0
            sessionHasEnded = false
            onAppend = nil
            evidenceIsComplete = true
        }
    }

    /// The evidence worker's verdict on this session's record, reported when it persists a row and
    /// again when it seals the session. The signal is the existing monotonic health record — there
    /// is no second counter — so the notice appears once, on the transition, and never retracts.
    ///
    /// A stopped session's close routinely lands after a replacement Start (Stop drains cancelled
    /// turns and compaction first), so this is scoped by session: a partial old session never puts
    /// an incomplete-record notice on the new session's healthy window.
    func noteEvidence(isComplete: Bool, for session: UUID) {
        let observer = lock.withLock { () -> ((String) -> Void)? in
            guard sessionID == session, !isComplete, evidenceIsComplete else { return nil }
            evidenceIsComplete = false
            return onAppend
        }
        observer?(Self.evidenceScript(isComplete: false))
    }

    /// Whether this projection is showing `session` and it has not yet ended. The worker checks it
    /// before decoding and writing a screenshot, so a row that will be refused leaves no orphan
    /// `shot-N.jpg` behind.
    func isRecording(for session: UUID) -> Bool {
        lock.withLock { dir != nil && sessionID == session && !sessionHasEnded }
    }

    /// Reserve the next owner-only screenshot filename for this session. The worker writes the
    /// bytes; the sequence belongs here because it is per-session viewer state. Returns nil once
    /// this projection has moved on, so a stopped session cannot consume the live session's
    /// numbering.
    func nextShotFilename(for session: UUID) -> String? {
        lock.withLock {
            guard sessionID == session else { return nil }
            shotSeq += 1
            return "shot-\(shotSeq).jpg"
        }
    }

    /// Give one occurrence its place in the session chronology and build what to persist and push.
    ///
    /// Teardown can race a coaching task that is finishing cancellation. Once the typed end marker
    /// is admitted, it is the final event for this session by definition.
    func admit(
        _ event: ActivityEvent,
        at date: Date,
        shotFilename: String?,
        for session: UUID
    ) -> Admission {
        let rendered = event.rendered
        let recordedAt = Date().timeIntervalSince1970
        return lock.withLock { () -> Admission in
            guard dir != nil, sessionID == session else { return .notCurrent }
            guard !sessionHasEnded else { return .sessionEnded }
            let baseEntry = Entry(
                time: df.string(from: date),
                message: rendered.message,
                imageFile: shotFilename)
            let item = entries.append(baseEntry, occurredAt: date.timeIntervalSince1970)
            let entry = Entry(
                time: baseEntry.time,
                message: baseEntry.message,
                imageFile: baseEntry.imageFile,
                occurredAt: item.occurredAt,
                insertionOrder: item.insertionOrder)
            totalCount += 1
            if rendered.kind == .sessionEnded {
                sessionHasEnded = true
            }
            let removedItems = entries.keepMostRecentInsertions(Self.retainedEntryLimit)
            let chronologicalIndex = entries.chronologicalIndex(
                forInsertionOrder: item.insertionOrder)
            guard let line = Self.persistedLine(
                entry, kind: rendered.kind, recordedAt: recordedAt)
            else { return .notCurrent }
            // Push with the live bytes in hand (no disk read on the hot path).
            return .row(AdmittedRow(
                line: line,
                script: Self.rowScript(
                    time: entry.time,
                    message: entry.message,
                    imageBase64: rendered.imageBase64,
                    insertionIndex: chronologicalIndex,
                    insertionOrder: item.insertionOrder,
                    removedInsertionOrders: removedItems.map(\.insertionOrder))))
        }
    }

    /// Push an admitted row to the live viewer. Called after persistence is attempted: a failed
    /// write costs the row its place in history, not its place on screen. Only `admit` can produce
    /// a row, and only for the session on screen, so the identity check here is belt-and-braces
    /// against a rotation landing between the two calls.
    func publish(_ row: AdmittedRow, for session: UUID) {
        let observer = lock.withLock { sessionID == session ? onAppend : nil }
        observer?(row.script)
    }

    /// Atomically register the live observer and capture the current snapshot, so every subsequent
    /// entry arrives via `onAppend` exactly once — never double-rendered or missed. Snapshot rows
    /// re-read their screenshot bytes from disk (a rare, one-shot cost when the viewer opens).
    public func attach(_ onAppend: @escaping (String) -> Void) -> Snapshot {
        lock.withLock {
            self.onAppend = onAppend
            let rows: [String] = entries.chronologicalItems.map { item in
                let e = item.element
                let b64: String? = e.imageFile.flatMap { name in
                    guard let dir else { return nil }
                    return (try? Data(contentsOf: dir.appendingPathComponent(name)))?.base64EncodedString()
                }
                return Self.rowScript(
                    time: e.time,
                    message: e.message,
                    imageBase64: b64,
                    insertionOrder: item.insertionOrder)
            }
            return Snapshot(
                shellHTML: Self.htmlShell(),
                rows: rows,
                shown: entries.count,
                total: totalCount,
                evidenceIsComplete: evidenceIsComplete)
        }
    }

    /// Stop pushing to the observer (e.g. while the viewer shows a *past* session).
    public func detach() { lock.withLock { onAppend = nil } }

    /// Encode one `jarvis-activity.jsonl` line. Pure — the worker owns the write.
    private static func persistedLine(
        _ entry: Entry,
        kind: ActivityEvent.Kind,
        recordedAt: TimeInterval
    ) -> Data? {
        try? JSONEncoder().encode(PersistedEntry(
            t: entry.time,
            m: entry.message,
            s: entry.imageFile,
            k: kind,
            o: entry.occurredAt,
            q: entry.insertionOrder,
            r: recordedAt))
    }

    // MARK: - Pure rendering (testable without a WebView)

    /// The JS call that renders one row. Pushed to `evaluateJavaScript` (live) or replayed from a
    /// snapshot. The payload is a JSON object literal; the page's JS sets text via `textContent` and
    /// the image via `img.src`, so the message is XSS-safe by construction and no HTML escaping is
    /// needed here. `imageBase64`, when present, becomes an in-memory `data:` URI. A live row's
    /// insertion index is computed by `ConversationChronology`; the WebView only applies it.
    public static func rowScript(
        time: String,
        message: String,
        imageBase64: String?,
        insertionIndex: Int? = nil,
        insertionOrder: UInt64? = nil,
        removedInsertionOrders: [UInt64] = []
    ) -> String {
        struct Row: Encodable {
            let time: String
            let message: String
            let cls: String
            let img: String?
            let insertionIndex: Int?
            /// Encode UInt64 identities as strings; JavaScript numbers cannot represent all of them.
            let insertionOrder: String?
            let removedInsertionOrders: [String]?
        }
        let row = Row(time: time, message: message, cls: cssClass(for: message),
                      img: imageBase64.map { "data:image/jpeg;base64,\($0)" },
                      insertionIndex: insertionIndex,
                      insertionOrder: insertionOrder.map(String.init),
                      removedInsertionOrders: removedInsertionOrders.isEmpty
                        ? nil
                        : removedInsertionOrders.map(String.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]   // keep data: URIs readable (no \/ )
        guard let data = try? encoder.encode(row), let json = String(data: data, encoding: .utf8) else {
            return "appendRow({});"
        }
        return "appendRow(\(json));"
    }

    /// The JS call that shows or clears the incomplete-record notice. Both strings are fixed and
    /// human-safe; the page sets them with `textContent`/`title`, so nothing here can inject markup.
    public static func evidenceScript(isComplete: Bool) -> String {
        let label = isComplete ? "" : incompleteEvidenceNotice
        let detail = isComplete ? "" : incompleteEvidenceDetail
        return "setEvidence(\(jsString(label)),\(jsString(detail)));"
    }

    /// JSON-encode one string for embedding in a `evaluateJavaScript` call.
    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return json
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
        if m.hasPrefix("⏹ session ended by error") { return "err" }
        if m.hasPrefix("⏹ session ended") { return "think" }
        if m.hasPrefix("⚠️") { return "think" }
        let low = m.lowercased()
        if low.contains("error") || low.contains("failed") || low.contains("denied") { return "err" }
        return ""
    }

    /// Whether a persisted row belongs in the human-facing viewer. New rows are guaranteed by the
    /// typed `Event` API; this also hides diagnostic rows from sessions written by older builds.
    static func isHumanFacing(
        message: String,
        imageFile: String?,
        kind: ActivityEvent.Kind? = nil
    ) -> Bool {
        // Current builds persist a stable kind only for typed, human-facing events. Prefix matching
        // remains the compatibility path for logs created before event kinds were added.
        if kind != nil { return true }
        if imageFile != nil { return true }
        let m = message.trimmingCharacters(in: .whitespaces)
        return m.hasPrefix("🗣 heard") || m.hasPrefix("⌨️ hint shortcut")
            || m.hasPrefix("👁 looking at your screen") || m.hasPrefix("👁 couldn't view your screen")
            || m.hasPrefix("💬") || m.hasPrefix("🤫 stayed silent")
            || m.hasPrefix("⏹ session ended")
            || (m.hasPrefix("⚠️") && m.hasSuffix("listening continues")
                && (m.contains("couldn't respond this turn")
                    || m.contains("couldn't finish the response — retrying while")))
            || m.hasPrefix("⚠️ system audio stopped")
            || m.hasPrefix("⚠️ settings change wasn't applied")
            || m.hasPrefix("🧠 brain switch applied")
            || m.hasPrefix("🧠 brain change applied")
            || m.hasPrefix("⚠️ brain switch failed")
            || m.hasPrefix("⚠️ brain change failed")
    }

    /// The empty page shell: an adaptive Settings-style activity feed, a header with a live count and
    /// non-persisted readiness badge, the lightbox overlay, and the JS that the App viewer drives.
    /// Rows are injected at runtime via `evaluateJavaScript`; no row HTML is rendered server-side, so
    /// the page never embeds untrusted text and there is no reload.
    public static func htmlShell() -> String {
        """
        <!doctype html><html lang="en"><head>
        <meta charset="utf-8">
        <title>Jarvis Activity</title>
        <style>
          :root {
            color-scheme: light dark;
            --background: #ffffff;
            --surface: #f8f8fa;
            --line: rgba(28, 31, 39, 0.12);
            --text: #35363b;
            --muted: #85868d;
            --say: #267b48;
            --see: #a66017;
            --hear: #176fae;
            --think: #6d6e75;
            --error: #c23e38;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --background: #1e1e20;
              --surface: #262628;
              --line: rgba(255, 255, 255, 0.12);
              --text: #e1e1e3;
              --muted: #929299;
              --say: #55b578;
              --see: #e4a54c;
              --hear: #62aee7;
              --think: #a0a0a7;
              --error: #ef716a;
            }
          }
          body { margin: 0; background: var(--background); color: var(--text);
                 font: 12px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text",
                       "Helvetica Neue", sans-serif; }
          header { position: sticky; top: 0; display: flex; align-items: center; gap: 8px;
                   padding: 9px 14px; background: var(--surface);
                   border-bottom: 1px solid var(--line); color: var(--muted);
                   font-size: 10px; font-weight: 700; letter-spacing: .045em;
                   text-transform: uppercase; z-index: 10; }
          header .count { flex: 1; font-weight: 500; letter-spacing: 0; text-transform: none; }
          header .readiness { padding: 2px 7px; border: 1px solid var(--line); border-radius: 999px;
                              font-weight: 600; letter-spacing: 0; text-transform: none; }
          header .evidence { padding: 2px 7px; border: 1px solid var(--line); border-radius: 999px;
                             color: var(--see); font-weight: 600; letter-spacing: 0;
                             text-transform: none; }
          header .evidence:empty { display: none; }
          header .readiness[data-state="active"] { color: var(--say); }
          header .readiness[data-state="microphone-only"],
          header .readiness[data-state="recovering"] { color: var(--see); }
          header .readiness[data-state="blocked"] { color: var(--error); }
          main { padding: 0 0 28px; }
          .row { display: grid; grid-template-columns: 66px minmax(0, 1fr); gap: 12px;
                 padding: 10px 14px; border-bottom: 1px solid var(--line);
                 white-space: pre-wrap; }
          .t { color: var(--muted); font-size: 10px; }
          .m { min-width: 0; }
          .say .m  { color: var(--say); }
          .see .m  { color: var(--see); }
          .hear .m { color: var(--hear); }
          .think .m{ color: var(--think); }
          .err .m  { color: var(--error); }
          .shot { display: block; margin-top: 7px; width: fit-content; }
          .shot img { display: block; max-height: 140px; max-width: 280px;
                      border: 1px solid var(--line); border-radius: 8px; cursor: zoom-in; }
          .lightbox { position: fixed; inset: 0; z-index: 1000; display: none;
                      align-items: center; justify-content: center; cursor: zoom-out;
                      background: rgba(10, 12, 16, 0.86); }
          .lightbox.open { display: flex; }
          .lightbox img { max-width: 92vw; max-height: 92vh; border: 1px solid var(--line);
                          border-radius: 8px; box-shadow: 0 8px 40px rgba(0, 0, 0, 0.6); }
        </style></head><body>
        <header>Jarvis — activity log <span class="count" id="count"></span>
          <span class="evidence" id="evidence"></span>
          <span class="readiness" id="readiness" data-state="stopped">Stopped</span>
        </header>
        <main id="log"></main>
        <div class="lightbox" id="lightbox"><img id="lightbox-img" alt="full-size screenshot"></div>
        <script>
          function appendRow(p){
            var log=document.getElementById('log');
            var near=(window.innerHeight+window.scrollY)>=(document.body.scrollHeight-60);
            if(Array.isArray(p.removedInsertionOrders)){
              var removed=new Set(p.removedInsertionOrders);
              Array.from(log.children).forEach(function(existing){
                if(removed.has(existing.dataset.insertionOrder)) existing.remove();
              });
            }
            var row=document.createElement('div'); row.className='row '+(p.cls||'');
            if(typeof p.insertionOrder==='string'){
              row.dataset.insertionOrder=p.insertionOrder;
            }
            var t=document.createElement('span'); t.className='t'; t.textContent=p.time||'';
            var m=document.createElement('span'); m.className='m'; m.textContent=p.message||'';
            if(p.img){
              var a=document.createElement('a'); a.className='shot'; a.href=p.img;
              var img=document.createElement('img'); img.src=p.img; img.alt='screenshot of the user\\'s screen';
              a.appendChild(img);
              a.addEventListener('click',function(e){e.preventDefault();openShot(p.img);});
              m.appendChild(a);
            }
            row.appendChild(t); row.appendChild(m);
            if(Number.isInteger(p.insertionIndex) && p.insertionIndex>=0 &&
               p.insertionIndex<log.children.length){
              log.insertBefore(row,log.children[p.insertionIndex]);
            }else{
              log.appendChild(row);
            }
            if(near) window.scrollTo(0,document.body.scrollHeight);
          }
          function openShot(src){ document.getElementById('lightbox-img').src=src;
            document.getElementById('lightbox').classList.add('open'); }
          function closeShot(){ var b=document.getElementById('lightbox');
            b.classList.remove('open'); document.getElementById('lightbox-img').removeAttribute('src'); }
          function clearRows(){ document.getElementById('log').innerHTML=''; }
          function setMeta(s){ document.getElementById('count').textContent=s; }
          function setReadiness(label,state){ var badge=document.getElementById('readiness');
            badge.textContent=label||''; badge.dataset.state=state||'stopped'; }
          function setEvidence(label,detail){ var badge=document.getElementById('evidence');
            badge.textContent=label||''; badge.title=detail||''; }
          document.addEventListener('keydown',function(e){ if(e.key==='Escape') closeShot(); });
          document.getElementById('lightbox').addEventListener('click',closeShot);
        </script>
        </body></html>
        """
    }
}
