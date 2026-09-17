import Foundation

// @unchecked Sendable: every mutable field is read and written under `lock`.
public final class ActivityLog: @unchecked Sendable {
    public static let shared = ActivityLog()
    public static let filename = "jarvis-activity.jsonl"
    /// Fixed text only. Never carries transport, retry, timing, lifecycle, or raw error detail.
    public static let incompleteEvidenceNotice = "incomplete record"
    public static let incompleteEvidenceDetail =
        "Some of this session's activity could not be saved." 
    /// Runaway backstop only, sized so a multi-hour session still replays whole.
    public static let retainedEntryLimit = 10_000

    public struct Entry: Sendable, Equatable {
        public let time: String
        public let message: String
        /// Relative `shot-N.jpg` name on disk, or nil for a text line.
        public let imageFile: String?
        public let response: ActivityResponse?
        /// Both nil for old or mixed sessions that cannot be reordered safely.
        public let occurredAt: TimeInterval?
        public let insertionOrder: UInt64?
        public init(
            time: String,
            message: String,
            imageFile: String?,
            occurredAt: TimeInterval? = nil,
            insertionOrder: UInt64? = nil,
            response: ActivityResponse? = nil
        ) {
            self.time = time
            self.message = message
            self.imageFile = imageFile
            self.response = response
            self.occurredAt = occurredAt
            self.insertionOrder = insertionOrder
        }
    }

    public struct Snapshot: Sendable {
        public let shellHTML: String
        public let rows: [String]
        /// Rows in the snapshot, capped at `retainedEntryLimit`.
        public let shown: Int
        /// Everything recorded this session, including rows past the cap.
        public let total: Int
        public let evidenceIsComplete: Bool
    }

    private struct PersistedEntry: Codable {
        let t: String       // time, HH:mm:ss
        let response: ActivityResponse? // absent in legacy, unstructured rows
        let m: String       // message
        let s: String?      // shot filename, if any
        let k: ActivityEvent.Kind?  // stable event identity; nil only for backward-compatible old rows
        let o: TimeInterval? // event occurrence time (Unix seconds)
        let q: UInt64?      // stable insertion tie-breaker
        let r: TimeInterval? // record/completion time (Unix seconds), for chronology diagnosis
    }

    enum Admission {
        case row(AdmittedRow)
        /// The terminal marker was already recorded, so dropping later rows is intended.
        case sessionEnded
        /// The window rotated to another session before the worker drained this row. A real loss.
        case notCurrent
    }

    struct AdmittedRow {
        /// The `jarvis-activity.jsonl` line, without its trailing newline.
        let line: Data
        let script: String
    }

    // Held only across in-memory bookkeeping, never disk access.
    private let lock = NSLock()
    private var entries = ConversationChronology<Entry>()
    private var totalCount = 0    // survives the retained-entry cap
    private var shotSeq = 0
    private var sessionHasEnded = false
    private let df: DateFormatter
    private var dir: URL?         // nil ⇒ disabled (no observer pushes)
    /// The worker drains asynchronously, so a stopped session's rows and close can arrive after a
    /// new Start. Every entry point is scoped by this identity to keep them off the new window.
    private var sessionID: UUID?
    private var onAppend: ((String) -> Void)?
    /// Health is monotonic, so this only moves from true to false: one notice, never a flicker.
    private var evidenceIsComplete = true

    init() {
        df = DateFormatter()
        // Fixed-format formatter: pin locale and calendar so output ignores user settings (QA1480).
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "HH:mm:ss"
    }

    public func enable(directory: URL, session: UUID) {
        lock.withLock {
            dir = directory
            sessionID = session
            entries.removeAll(); totalCount = 0; shotSeq = 0; sessionHasEnded = false; onAppend = nil
            evidenceIsComplete = true
        }
    }

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

    func noteEvidence(isComplete: Bool, for session: UUID) {
        let observer = lock.withLock { () -> ((String) -> Void)? in
            guard sessionID == session, !isComplete, evidenceIsComplete else { return nil }
            evidenceIsComplete = false
            return onAppend
        }
        observer?(Self.evidenceScript(isComplete: false))
    }

    func isRecording(for session: UUID) -> Bool {
        lock.withLock { dir != nil && sessionID == session && !sessionHasEnded }
    }

    /// Nil once this projection has moved on to another session.
    func nextShotFilename(for session: UUID) -> String? {
        lock.withLock {
            guard sessionID == session else { return nil }
            shotSeq += 1
            return "shot-\(shotSeq).jpg"
        }
    }

    /// Once the end marker is admitted, later rows are refused even if a cancelled task races it.
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
                imageFile: shotFilename, response: event.response)
            let item = entries.append(baseEntry, occurredAt: date.timeIntervalSince1970)
            let entry = Entry(
                time: baseEntry.time,
                message: baseEntry.message,
                imageFile: baseEntry.imageFile,
                occurredAt: item.occurredAt,
                insertionOrder: item.insertionOrder, response: baseEntry.response)
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
            return .row(AdmittedRow(
                line: line,
                script: Self.rowScript(
                    time: entry.time,
                    message: entry.message,
                    imageBase64: rendered.imageBase64,
                    insertionIndex: chronologicalIndex,
                    insertionOrder: item.insertionOrder,
                    removedInsertionOrders: removedItems.map(\.insertionOrder),
                    response: entry.response)))
        }
    }

    /// The identity check guards against a session rotation between `admit` and `publish`.
    func publish(_ row: AdmittedRow, for session: UUID) {
        let observer = lock.withLock { sessionID == session ? onAppend : nil }
        observer?(row.script)
    }

    /// Registers the observer and snapshots under one lock, so no later row is missed or doubled.
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
                    insertionOrder: item.insertionOrder, response: e.response)
            }
            return Snapshot(
                shellHTML: Self.htmlShell(),
                rows: rows,
                shown: entries.count,
                total: totalCount,
                evidenceIsComplete: evidenceIsComplete)
        }
    }

    public func detach() { lock.withLock { onAppend = nil } }

    private static func persistedLine(
        _ entry: Entry,
        kind: ActivityEvent.Kind,
        recordedAt: TimeInterval
    ) -> Data? {
        try? JSONEncoder().encode(PersistedEntry(
            t: entry.time,
            response: entry.response,
            m: entry.message,
            s: entry.imageFile,
            k: kind,
            o: entry.occurredAt,
            q: entry.insertionOrder,
            r: recordedAt))
    }

    // MARK: - Pure rendering (testable without a WebView)

    /// No HTML escaping needed: the page sets text via `textContent` and the image via `img.src`.
    public static func rowScript(
        time: String,
        message: String,
        imageBase64: String?,
        insertionIndex: Int? = nil,
        insertionOrder: UInt64? = nil,
        removedInsertionOrders: [UInt64] = [],
        response: ActivityResponse? = nil
    ) -> String {
        struct Row: Encodable {
            let time: String
            let message: String
            let response: ActivityResponse?
            let cls: String
            let img: String?
            let insertionIndex: Int?
            /// Encode UInt64 identities as strings; JavaScript numbers cannot represent all of them.
            let insertionOrder: String?
            let removedInsertionOrders: [String]?
        }
        let row = Row(time: time, message: message, response: response, cls: cssClass(for: message),
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

    public static func evidenceScript(isComplete: Bool) -> String {
        let label = isComplete ? "" : incompleteEvidenceNotice
        let detail = isComplete ? "" : incompleteEvidenceDetail
        return "setEvidence(\(jsString(label)),\(jsString(detail)));"
    }

    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return json
    }

    /// Keyed on the leading marker, not a substring, so a tip saying "failed" isn't an error.
    static func cssClass(for message: String) -> String {
        let m = message.trimmingCharacters(in: .whitespaces)
        if m.hasPrefix("💬") { return "say" }
        if m.hasPrefix("👁") { return "see" }
        if m.hasPrefix("🗣") || m.hasPrefix("🤫 quiet") { return "hear" }
        if m.hasPrefix("🤫 stayed silent") || m.hasPrefix("💭") || m.hasPrefix("…") { return "think" }
        if m.hasPrefix("🧠") { return "think" }
        if m.hasPrefix("📎") { return "think" }
        if m.hasPrefix("⏹ session ended by error") { return "err" }
        if m.hasPrefix("⏹ session ended") { return "think" }
        if m.hasPrefix("⚠️") { return "think" }
        let low = m.lowercased()
        if low.contains("error") || low.contains("failed") || low.contains("denied") { return "err" }
        return ""
    }

    static func isHumanFacing(
        message: String,
        imageFile: String?,
        kind: ActivityEvent.Kind? = nil
    ) -> Bool {
        // Prefix matching hides diagnostic rows in persisted logs that predate event kinds.
        if kind != nil { return true }
        if imageFile != nil { return true }
        let m = message.trimmingCharacters(in: .whitespaces)
        return m.hasPrefix("🗣 heard") || m.hasPrefix("⌨️ hint shortcut")
            || m.hasPrefix("👁 looking at your screen") || m.hasPrefix("👁 couldn't view your screen")
            || m.hasPrefix("💬") || m.hasPrefix("🤫 stayed silent")
            || m.hasPrefix("⏹ session ended")
            // The retry notice's cause text varies, so this keys on its fixed suffix.
            || (m.hasPrefix("⚠️") && m.hasSuffix("listening continues"))
            || m.hasPrefix("⚠️ system audio stopped")
            || m.hasPrefix("⚠️ settings change wasn't applied")
            || m.hasPrefix("🧠 brain switch applied")
            || m.hasPrefix("🧠 brain change applied")
            || m.hasPrefix("⚠️ brain switch failed")
            || m.hasPrefix("⚠️ brain change failed")
    }

    /// Rows are injected at runtime, so the shell never embeds untrusted text.
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
          .response-section + .response-section { margin-top: 12px; padding-top: 10px;
                                                  border-top: 1px solid var(--line); }
          .response-section h3 { margin: 0 0 4px; color: var(--muted); font-size: 10px;
                                 font-weight: 600; text-transform: uppercase; letter-spacing: .04em; }
          .response-section p { margin: 0; }
          .response-section .code-language { color: var(--muted); font-size: 10px; }
          .response-section pre { margin: 6px 0 0; padding: 10px; overflow-x: auto;
                                  white-space: pre; background: var(--surface); color: var(--text);
                                  border-radius: 6px; font: 11px/1.5 ui-monospace, Menlo, monospace; }
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
          function responseSection(parent,label){
            var section=document.createElement('section'); section.className='response-section';
            var heading=document.createElement('h3'); heading.textContent=label;
            section.appendChild(heading); parent.appendChild(section); return section;
          }
          function responseText(parent,text,cls){
            var body=document.createElement('p'); body.textContent=text;
            if(cls) body.className=cls;
            parent.appendChild(body);
          }
          function renderResponse(parent,response){
            if(response.lines && response.lines.length){
              responseText(responseSection(parent,'Hint'),response.lines.join('\\n'));
            }
            if(response.detail && response.detail.trim()){
              responseText(responseSection(parent,'Detail'),response.detail);
            }
            /* Explanation and Code appear only in rows written before the detail box existed. */
            if(response.explanation && response.explanation.trim()){
              responseText(responseSection(parent,'Explanation'),response.explanation);
            }
            if(response.code && response.code.code && response.code.code.trim()){
              var section=responseSection(parent,'Code');
              if(response.code.language) responseText(section,response.code.language,'code-language');
              if(response.code.placement) responseText(section,response.code.placement);
              var pre=document.createElement('pre'), code=document.createElement('code');
              code.textContent=response.code.code; pre.appendChild(code); section.appendChild(pre);
            }
          }
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
            var m=document.createElement('div'); m.className='m';
            if(p.response) renderResponse(m,p.response); else m.textContent=p.message||'';
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
