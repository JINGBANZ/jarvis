#!/usr/bin/env python3
"""Build a single self-contained HTML view of the Jarvis wiki.

Reads the markdown files in this directory and emits `jarvis-wiki.html`, a single
offline-capable file with a sidebar and client-side rendering (marked.js is inlined,
so no network is needed to open it). Re-run after editing any wiki page.

Usage: python3 build_html.py
"""
from pathlib import Path
import html
import json

WIKI = Path(__file__).parent
OUT = WIKI / "jarvis-wiki.html"
MARKED = Path("/tmp/marked.min.js")  # inlined for offline use; falls back to CDN if absent

# Sidebar order: (doc id, file path, display title, section)
PAGES = [
    ("status", "status.md", "Status — read first", "Start"),
    ("index", "index.md", "Index", "Start"),
    ("architecture", "architecture.md", "Architecture", "Design"),
    ("specification", "specification.md", "Specification", "Design"),
    ("sandbox", "sandbox.md", "Sandbox & Security", "Design"),
    ("landscape-survey", "landscape-survey.md", "Landscape Survey (tools tried)", "Research"),
    ("d-readme", "decisions/README.md", "Decision Log", "Decisions"),
    ("d0001", "decisions/0001-build-vs-buy.md", "0001 Build vs. Buy", "Decisions"),
    ("d0002", "decisions/0002-personal-tool-first.md", "0002 Personal Tool First", "Decisions"),
    ("d0003", "decisions/0003-native-swift-stack.md", "0003 Native Swift", "Decisions"),
    ("d0004", "decisions/0004-build-on-mac-not-vps.md", "0004 Build on Mac", "Decisions"),
    ("d0005", "decisions/0005-model-triggered-screen-capture.md", "0005 Model-Triggered Capture", "Decisions"),
    ("d0006", "decisions/0006-single-coach-mode.md", "0006 Single Coach Mode", "Decisions"),
]

docs = {}
for doc_id, rel, _title, _section in PAGES:
    docs[doc_id] = (WIKI / rel).read_text()

marked_js = MARKED.read_text() if MARKED.exists() else ""
marked_tag = (
    f"<script>{marked_js}</script>"
    if marked_js
    else '<script src="https://cdn.jsdelivr.net/npm/marked@12.0.0/marked.min.js"></script>'
)

# Build sidebar grouped by section
nav_html = []
last_section = None
for doc_id, _rel, title, section in PAGES:
    if section != last_section:
        nav_html.append(f'<div class="nav-section">{html.escape(section)}</div>')
        last_section = section
    nav_html.append(f'<a class="nav-link" data-doc="{doc_id}">{html.escape(title)}</a>')
nav_html = "\n".join(nav_html)

docs_json = json.dumps(docs)

HTML = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Jarvis Wiki</title>
{marked_tag}
<style>
  :root {{
    --bg:#0d1117; --panel:#161b22; --border:#30363d; --text:#e6edf3;
    --muted:#9da7b3; --accent:#58a6ff; --accent2:#3fb950; --code:#1f2630;
  }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;
         background:var(--bg); color:var(--text); }}
  .layout {{ display:flex; min-height:100vh; }}
  aside {{ width:300px; flex:0 0 300px; background:var(--panel); border-right:1px solid var(--border);
           position:sticky; top:0; height:100vh; overflow-y:auto; padding:20px 14px; }}
  aside h1 {{ font-size:18px; margin:4px 8px 4px; }}
  aside .tag {{ font-size:12px; color:var(--muted); margin:0 8px 18px; }}
  .nav-section {{ font-size:11px; letter-spacing:.08em; text-transform:uppercase; color:var(--muted);
                  margin:16px 8px 6px; }}
  .nav-link {{ display:block; padding:7px 10px; border-radius:7px; color:var(--text); cursor:pointer;
               text-decoration:none; font-size:14px; }}
  .nav-link:hover {{ background:#21262d; }}
  .nav-link.active {{ background:var(--accent); color:#0d1117; font-weight:600; }}
  main {{ flex:1; min-width:0; display:flex; justify-content:center; padding:42px 32px 120px; }}
  article {{ width:100%; max-width:860px; }}
  article h1 {{ font-size:30px; border-bottom:1px solid var(--border); padding-bottom:.3em; margin-top:0; }}
  article h2 {{ font-size:23px; border-bottom:1px solid var(--border); padding-bottom:.3em; margin-top:1.8em; }}
  article h3 {{ font-size:18px; margin-top:1.6em; }}
  a {{ color:var(--accent); }}
  code {{ background:var(--code); padding:.18em .4em; border-radius:5px; font-size:.88em;
          font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }}
  pre {{ background:var(--code); border:1px solid var(--border); border-radius:9px; padding:16px;
         overflow-x:auto; line-height:1.45; }}
  pre code {{ background:none; padding:0; font-size:13px; }}
  blockquote {{ border-left:4px solid var(--accent); margin:1em 0; padding:.4em 1em; color:var(--muted);
                background:#11161d; border-radius:0 8px 8px 0; }}
  table {{ border-collapse:collapse; width:100%; margin:1.2em 0; font-size:14px; }}
  th,td {{ border:1px solid var(--border); padding:8px 12px; text-align:left; vertical-align:top; }}
  th {{ background:#1c232c; }}
  tr:nth-child(even) td {{ background:#12171e; }}
  hr {{ border:none; border-top:1px solid var(--border); margin:2em 0; }}
  del {{ color:var(--muted); }}
  .crumb {{ color:var(--muted); font-size:13px; margin-bottom:8px; }}
</style>
</head>
<body>
<div class="layout">
  <aside>
    <h1>🤖 Jarvis Wiki</h1>
    <div class="tag">Design review build · generated from wiki/*.md</div>
    {nav_html}
  </aside>
  <main><article id="content"></article></main>
</div>
<script>
  const DOCS = {docs_json};
  const links = document.querySelectorAll('.nav-link');
  const content = document.getElementById('content');
  // map internal links like ./architecture.md or ./decisions/0001-*.md to doc ids
  const FILE_TO_ID = {{
    'status.md':'status','index.md':'index','architecture.md':'architecture',
    'specification.md':'specification','sandbox.md':'sandbox','landscape-survey.md':'landscape-survey',
    'decisions/README.md':'d-readme','README.md':'d-readme',
    'decisions/0001-build-vs-buy.md':'d0001','0001-build-vs-buy.md':'d0001',
    'decisions/0002-personal-tool-first.md':'d0002','0002-personal-tool-first.md':'d0002',
    'decisions/0003-native-swift-stack.md':'d0003','0003-native-swift-stack.md':'d0003',
    'decisions/0004-build-on-mac-not-vps.md':'d0004','0004-build-on-mac-not-vps.md':'d0004',
    'decisions/0005-model-triggered-screen-capture.md':'d0005','0005-model-triggered-screen-capture.md':'d0005',
    'decisions/0006-single-coach-mode.md':'d0006','0006-single-coach-mode.md':'d0006',
  }};
  function show(id) {{
    if (!DOCS[id]) id = 'status';
    content.innerHTML = marked.parse(DOCS[id]);
    // rewrite internal .md links to switch docs in-page
    content.querySelectorAll('a[href$=".md"], a[href*=".md#"]').forEach(a => {{
      let href = a.getAttribute('href').replace(/^\\.\\//,'').replace(/^\\.\\.\\//,'').split('#')[0];
      const target = FILE_TO_ID[href] || FILE_TO_ID[href.split('/').pop()];
      if (target) {{ a.addEventListener('click', e => {{ e.preventDefault(); select(target); }}); a.style.cursor='pointer'; }}
    }});
    links.forEach(l => l.classList.toggle('active', l.dataset.doc === id));
    window.scrollTo(0,0);
    location.hash = id;
  }}
  function select(id) {{ show(id); }}
  links.forEach(l => l.addEventListener('click', () => select(l.dataset.doc)));
  show((location.hash || '#status').slice(1));
</script>
</body>
</html>
"""

OUT.write_text(HTML)
print(f"Wrote {OUT} ({len(HTML):,} bytes), {len(docs)} pages, marked {'inlined' if marked_js else 'via CDN'}")
