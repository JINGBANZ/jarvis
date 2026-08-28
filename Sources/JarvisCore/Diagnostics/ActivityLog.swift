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
/// It is the terminal implementation of `ActivityEventRecording`: the coaching kernel names only
/// that port, so the concrete persistence type stays outside the kernel
/// (wiki/lean-coaching-core.md, Phase 2).
public final class ActivityLog: ActivityEventRecording, @unchecked Sendable {
    public static let shared = ActivityLog()
    public static let filename = "jarvis-activity.jsonl"
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

    /// In-memory replay cap for a late-attaching viewer. Sized for hours of coaching (an hour-long
    /// session logs a few thousand lines) — a cap this high exists only as a runaway backstop, so the
    /// viewer shows the WHOLE session, not just its tail. Entries are small (text + a filename; shot
    /// bytes stay on disk), so memory is not a concern.
    private let queue = DispatchQueue(label: "jarvis.activitylog")   // serializes state + disk writes
    private var entries = ConversationChronology<Entry>()
    private var totalCount = 0    // everything recorded this session (survives the retained-entry cap)
    private var shotSeq = 0       // monotonic id for saved screenshot files this session
    private var sessionHasEnded = false
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
            entries.removeAll(); totalCount = 0; shotSeq = 0; sessionHasEnded = false; onAppend = nil
            let url = directory.appendingPathComponent(Self.filename)
            FileManager.default.createFile(atPath: url.path, contents: Data(),
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    /// Turn the viewer back off (no further pushes or disk writes).
    public func disable() {
        queue.sync {
            dir = nil
            entries.removeAll()
            totalCount = 0
            shotSeq = 0
            sessionHasEnded = false
            onAppend = nil
        }
    }

    /// Append one human-facing coaching event: persist it, then push it to the observer. No-op when
    /// disabled. Call `jlog` instead for diagnostics.
    ///
    /// When a screen-view event carries a base64 JPEG, the `.jpg` is written **first** (owner-only)
    /// and then the `.jsonl` line referencing it — so a persisted reference always points at a file
    /// that exists.
    public func record(_ event: ActivityEvent, at date: Date) {
        let rendered = event.rendered
        let recordedAt = Date().timeIntervalSince1970
        queue.async { [self] in
            // Teardown can race a coaching task that is finishing cancellation. Once the typed end
            // marker reaches this serial queue, it is the final event for this session by definition.
            guard let dir, !sessionHasEnded else { return }
            let shotName = rendered.imageBase64.flatMap { saveShot($0, in: dir) }
            let occurredAt = date.timeIntervalSince1970
            let baseEntry = Entry(
                time: df.string(from: date),
                message: rendered.message,
                imageFile: shotName)
            let item = entries.append(baseEntry, occurredAt: occurredAt)
            let entry = Entry(
                time: baseEntry.time,
                message: baseEntry.message,
                imageFile: baseEntry.imageFile,
                occurredAt: item.occurredAt,
                insertionOrder: item.insertionOrder)
            appendJSONL(entry, kind: rendered.kind, recordedAt: recordedAt, in: dir)
            totalCount += 1
            if rendered.kind == .sessionEnded {
                sessionHasEnded = true
            }
            let removedItems = entries.keepMostRecentInsertions(Self.retainedEntryLimit)
            let chronologicalIndex = entries.chronologicalIndex(
                forInsertionOrder: item.insertionOrder)
            // Push with the live bytes in hand (no disk read on the hot path).
            onAppend?(Self.rowScript(time: entry.time, message: entry.message,
                                     imageBase64: rendered.imageBase64,
                                     insertionIndex: chronologicalIndex,
                                     insertionOrder: item.insertionOrder,
                                     removedInsertionOrders: removedItems.map(\.insertionOrder)))
        }
    }

    /// Atomically register the live observer and capture the current snapshot, so every subsequent
    /// entry arrives via `onAppend` exactly once — never double-rendered or missed. Snapshot rows
    /// re-read their screenshot bytes from disk (a rare, one-shot cost when the viewer opens).
    public func attach(_ onAppend: @escaping (String) -> Void) -> Snapshot {
        queue.sync {
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
    private func appendJSONL(
        _ entry: Entry,
        kind: ActivityEvent.Kind,
        recordedAt: TimeInterval,
        in dir: URL
    ) {
        let pe = PersistedEntry(
            t: entry.time,
            m: entry.message,
            s: entry.imageFile,
            k: kind,
            o: entry.occurredAt,
            q: entry.insertionOrder,
            r: recordedAt)
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
          header .readiness[data-state="ready"] { color: var(--say); }
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
          document.addEventListener('keydown',function(e){ if(e.key==='Escape') closeShot(); });
          document.getElementById('lightbox').addEventListener('click',closeShot);
        </script>
        </body></html>
        """
    }
}
