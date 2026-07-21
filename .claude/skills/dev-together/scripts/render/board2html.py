#!/usr/bin/env python3
"""dev-together: deterministic board.yaml -> board.html renderer.

The board is a plan+review unified kanban: one board.yaml per day is the single
source of truth. `plan` writes it at start-of-day (cards with acceptance
checklists in their status columns); `review` updates it at end-of-day (move
cards, tick acceptance with evidence, fill 复盘). This script renders it — the
MODEL never hand-writes HTML; presentation lives only here.

Usage:  uv run --with pyyaml python board2html.py <board.yaml> [board.html]
        (default output = input with .yaml -> .html)

board.yaml schema — see scripts/render/board.example.yaml for a filled example.
"""
import sys, html, json, datetime, os, re

try:
    import yaml
except ImportError:
    sys.exit("board2html: pyyaml missing. Run via: uv run --with pyyaml python board2html.py <board.yaml>")

# ---- status column model ----
COLUMNS = [("planned", "计划", "c-plan"),
           ("wip", "进行中", "c-wip"),
           ("review", "待评审 / 验收", "c-rev"),
           ("done", "完成", "c-done")]
PR_STATE_PILL = {"merged": "pr-merged", "open": "pr-open", "draft": "pr-draft"}

def e(x):
    return html.escape("" if x is None else str(x))

def parse_date(s):
    """Parse a leading YYYY-MM-DD out of a string; return datetime.date or None.
    Tolerant of trailing text (e.g. '2026-07-27（刷新于 07-28）' -> 2026-07-27)."""
    if not s:
        return None
    try:
        return datetime.date.fromisoformat(str(s).strip()[:10])
    except ValueError:
        return None

def board_today(b):
    """The board's 'today' for delay computation — deterministic, NOT the wall
    clock, so a re-render is reproducible. Priority: explicit `as_of:` field →
    leading date of `date:` → system date (last-resort). `as_of` is the field
    `plan`/`review` set when the board is organized on a later day."""
    return (parse_date(b.get("as_of"))
            or parse_date(b.get("date"))
            or datetime.date.today())

def card_delay(card, today):
    """(delayed, overdue_days). A card is DELAYED when it is NOT done and its
    `est_done` is strictly before `today`. Cards without `est_done` (or when
    `today` is unresolvable) are never delayed — fully backward-compatible:
    a board authored before this field renders byte-identically."""
    if today is None or card.get("status") == "done":
        return (False, 0)
    ed = parse_date(card.get("est_done"))
    if ed and ed < today:
        return (True, (today - ed).days)
    return (False, 0)

def eff_delta_chip(delta):
    """Optional up/down delta chip rendered right next to an efficiency value.

    Reads the *sign glyph* the caller already chose (board_efficiency.py emits
    ↓/↑): starts with ↓/-/▼ → red (down), ↑/+/▲ → green (up), else neutral.
    All styling is inline so it always wins over `.eff b`/`.eff span` and adds
    no CSS surface — entries with no `delta` render byte-identically to before.
    """
    if delta is None or str(delta).strip() == "":
        return ""
    d = str(delta).strip()
    head = d[0]
    if head in "↓-▼":
        color = "#f87171"   # down = red
    elif head in "↑+▲":
        color = "#4ade80"   # up = green
    else:
        color = "#94a3b8"   # neutral
    return (f'<span style="color:{color};font-size:11px;font-weight:700;'
            f'margin-left:5px;vertical-align:1px">{e(d)}</span>')

def render_system_closures(closures):
    items = []
    for closure in closures or []:
        envelope = closure.get("resource_envelope", {}) or {}
        resource_text = " · ".join(
            f"{key}={value}" for key, value in envelope.items()
        )
        related = ", ".join(closure.get("related_cards", []) or [])
        items.append(
            '<div class="closure">'
            f'<b>{e(closure.get("id"))}</b>'
            f'<div><strong>X problem:</strong> {e(closure.get("x_problem"))}</div>'
            f'<div><strong>Invariant:</strong> {e(closure.get("plan_invariant"))}</div>'
            f'<div><strong>Cards:</strong> {e(related)}</div>'
            f'<div><strong>Durable proof:</strong> {e(closure.get("durable_proof"))}</div>'
            f'<div><strong>Integration evidence:</strong> {e(closure.get("integration_evidence"))}</div>'
            f'<div><strong>Resource envelope:</strong> {e(resource_text)}</div>'
            '</div>'
        )
    if not items:
        return ""
    return ('<section class="closures"><h2>Plan-level system closure · '
            '系统闭环</h2>' + "".join(items) + "</section>")

def render_method_delta(delta):
    if isinstance(delta, str):
        return '<div class="method-delta legacy">• ' + e(delta) + "</div>"
    labels = [
        ("Finding", "finding"),
        ("X problem", "x_problem"),
        ("Y problem", "y_problem"),
        ("X-level correction", "x_level_correction"),
        ("Y-level correction", "y_level_correction"),
        ("Recurrence-prevention proof", "recurrence_prevention_proof"),
        ("Owner", "owner"),
        ("Destination", "destination"),
    ]
    return '<div class="method-delta">' + "".join(
        f'<div><strong>{e(label)}:</strong> {e(delta.get(key))}</div>'
        for label, key in labels
    ) + "</div>"

CSS = """
  :root{--ink:#1a1a1a;--line:#e2e8f0;--soft:#f8fafc;--blue:#2563eb;--blue-d:#1e40af;--green:#059669;--amber:#d97706;--red:#dc2626}
  *{box-sizing:border-box}
  body{font:14px/1.55 -apple-system,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;color:var(--ink);margin:0;background:#eef2f7}
  .wrap{max-width:1460px;margin:0 auto;padding:18px}
  .hero{background:linear-gradient(135deg,#1e293b,#334155);color:#fff;border-radius:12px;padding:16px 20px;margin-bottom:14px}
  .hero .row{display:flex;flex-wrap:wrap;gap:20px;align-items:center}
  .hero h1{font-size:19px;margin:0 0 3px}
  .hero .north{font-size:12.5px;color:#cbd5e1;max-width:640px}
  .hero .north b{color:#fbbf24}
  .prog{flex:1;min-width:220px}
  .prog .lab{font-size:11px;color:#94a3b8;display:flex;justify-content:space-between;margin-bottom:4px}
  .bar{height:9px;background:#0f172a;border-radius:6px;overflow:hidden}
  .bar i{display:block;height:100%;background:linear-gradient(90deg,#22c55e,#16a34a)}
  .bar.b i{background:linear-gradient(90deg,#38bdf8,#2563eb)}
  .eff{display:flex;gap:0;background:#0f172a;border-radius:9px;overflow:hidden;flex-wrap:wrap}
  .eff div{padding:8px 13px;border-right:1px solid #1e293b;text-align:center}
  .eff div:last-child{border-right:0}
  .eff b{display:block;font-size:17px;color:#7dd3fc;line-height:1.1}
  .eff span{font-size:10px;color:#94a3b8}
  .hero .src{font-size:10.5px;color:#64748b;margin-top:8px}
  .deploy{display:inline-flex;border:1px solid var(--line);border-radius:8px;overflow:hidden;background:#fff;margin:0 10px 8px 0;vertical-align:top}
  .deploy div{padding:6px 12px;font-size:12px;border-right:1px solid #eef2f7}
  .deploy div:last-child{border-right:0}
  .deploy .s{display:block;font-size:10px;color:#94a3b8}
  .risk{background:#fef2f2;border:1px solid #fecaca;border-radius:8px;padding:9px 14px;margin:2px 0 12px;font-size:12.5px}
  .closures{background:#fff;border:1px solid var(--line);border-radius:9px;padding:10px 12px;margin:0 0 12px}
  .closures h2{font-size:15px;color:var(--blue-d);margin:0 0 8px}
  .closure{background:var(--soft);border-left:3px solid var(--blue);border-radius:0 6px 6px 0;padding:8px 10px;margin-top:7px;font-size:12px}
  .method-delta{border-bottom:1px solid #dbeafe;padding:5px 0}.method-delta:last-child{border-bottom:0}
  .board{display:grid;grid-template-columns:repeat(4,minmax(220px,1fr));gap:10px;overflow-x:auto}
  .colwrap{display:flex;flex-direction:column;min-width:0}
  .colhead{font-weight:700;font-size:12px;text-align:center;padding:7px 4px;border-radius:6px 6px 0 0;color:#fff}
  .colhead .cnt{background:rgba(255,255,255,.28);border-radius:8px;padding:0 6px;font-size:11px;margin-left:2px}
  .c-plan{background:#94a3b8}.c-wip{background:var(--blue)}.c-rev{background:var(--amber)}.c-done{background:var(--green)}
  .cell{display:flex;flex-direction:column;gap:7px;min-height:40px;padding:6px 2px}
  .owner{font-size:10px;color:#64748b;font-weight:600;margin-bottom:4px}
  .odot{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:4px;vertical-align:middle}
  .legend{margin:2px 0 12px;font-size:11.5px;color:#64748b}
  .legend .lg{margin-right:14px;white-space:nowrap}
  .recent{margin-top:8px;padding-top:8px;border-top:1px dashed #cbd5e1}
  .rday{font-size:10.5px;font-weight:700;color:#94a3b8;margin:4px 0 4px}
  .rchip{font-size:11px;color:#334155;background:#f6fefa;border:1px solid #d1fae5;border-left:3px solid var(--pc);border-radius:6px;padding:4px 8px;margin-bottom:4px}
  .rchip .odot{margin-right:5px}
  .card{background:#fff;border:1px solid var(--line);border-left:3px solid var(--pc);border-radius:7px;padding:8px 9px;cursor:pointer;transition:box-shadow .12s,transform .12s}
  .card:hover{box-shadow:0 3px 10px rgba(0,0,0,.10);transform:translateY(-1px)}
  .card.done{background:#f6fefa;border-left-color:var(--green)}
  .card.done .t{color:#065f46}
  .done-rib{display:inline-block;font-size:10px;font-weight:700;color:#fff;background:var(--green);border-radius:4px;padding:1px 6px;float:right}
  .late-rib{display:inline-block;font-size:10px;font-weight:700;color:#fff;background:var(--red);border-radius:4px;padding:1px 6px;float:right}
  .card.late{background:#fff8f8}
  .sched{font-size:10.5px;color:#64748b;margin:1px 0 5px;display:flex;flex-wrap:wrap;gap:5px;align-items:center}
  .sched .cal{filter:grayscale(.2)}
  .sched.late{color:#b91c1c;font-weight:600}
  .decomp{font-size:10px;color:#b91c1c;background:#fef2f2;border:1px dashed #fecaca;border-radius:6px;padding:3px 7px;margin:0 0 6px;line-height:1.45}
  .card .t{font-weight:600;font-size:12.5px;margin-bottom:3px}
  .card .g{font-size:10.5px;color:#64748b;margin-bottom:6px}
  .accm{font-size:11px;color:#475569;margin-bottom:6px}
  .accm .d{color:var(--green)}.accm .o{color:#94a3b8}
  .meta{display:flex;flex-wrap:wrap;gap:4px;align-items:center}
  .pill{display:inline-block;padding:1px 7px;border-radius:10px;font-size:10.5px;font-weight:600}
  .pr-merged{background:#dcfce7;color:#166534}.pr-open{background:#fef9c3;color:#854d0e}.pr-draft{background:#e0e7ff;color:#3730a3}
  .dep{background:#fef3c7;color:#92400e}.carry{background:#f1f5f9;color:#475569}.more{background:#eff6ff;color:#1d4ed8}.blocked{background:#fee2e2;color:#991b1b}
  .detail{display:none}
  .review{margin-top:20px}
  .review h2{font-size:17px;color:var(--blue-d);border-left:4px solid var(--blue);padding-left:10px;margin:18px 0 10px}
  .grid2{display:grid;grid-template-columns:1fr 1fr;gap:12px}
  .inc{background:#fef2f2;border:1px solid #fecaca;border-radius:8px;padding:10px 13px;font-size:12.5px}
  .good{background:#f0fdf4;border:1px solid #bbf7d0;border-radius:8px;padding:10px 13px;font-size:12.5px}
  .review table{border-collapse:collapse;width:100%;font-size:12.5px;margin-top:6px}
  .review th,.review td{border:1px solid #d1d5db;padding:6px 9px;text-align:left}
  .review th{background:#eff6ff}
  .review tr:nth-child(even){background:#f9fafb}
  .modal{display:none;position:fixed;inset:0;background:rgba(15,23,42,.55);z-index:50;align-items:center;justify-content:center;padding:20px}
  .modal.on{display:flex}
  .sheet{background:#fff;border-radius:12px;max-width:560px;width:100%;max-height:86vh;overflow:auto;padding:20px 22px;box-shadow:0 20px 60px rgba(0,0,0,.3)}
  .sheet h3{margin:0 0 4px;font-size:16px}.sheet .who{font-size:12px;color:#64748b;margin-bottom:12px}
  .sheet .sec{font-size:11px;font-weight:700;color:var(--blue-d);text-transform:uppercase;letter-spacing:.04em;margin:14px 0 5px}
  .sheet ul.acc{list-style:none;margin:0;padding:0;font-size:13px}
  .sheet ul.acc li{margin:4px 0;padding-left:20px;position:relative}
  .sheet ul.acc li.done::before{content:"\\2611";position:absolute;left:0;color:var(--green)}
  .sheet ul.acc li.todo::before{content:"\\2610";position:absolute;left:0;color:#94a3b8}
  .sheet ul.acc li .ev{display:block;font-size:11px;color:var(--green)}
  .sheet .rv{background:var(--soft);border-left:3px solid #94a3b8;padding:8px 12px;border-radius:0 6px 6px 0;font-size:12.5px;color:#475569}
  .sheet .prompt{background:#0f172a;color:#e2e8f0;border-radius:8px;padding:10px 12px;font-size:11.5px;font-family:ui-monospace,Menlo,monospace;white-space:pre-wrap;margin-top:6px}
  .btn{background:var(--green);color:#fff;border:0;border-radius:7px;padding:7px 14px;font-size:12.5px;font-weight:600;cursor:pointer;margin-top:8px}
  .x{float:right;cursor:pointer;color:#94a3b8;font-size:20px;line-height:1;border:0;background:0}
  .foot{margin-top:16px;padding-top:10px;border-top:1px solid var(--line);font-size:11.5px;color:#94a3b8}
  @media(max-width:900px){.wrap{padding:10px}.grid2{grid-template-columns:1fr}.hero .row{gap:12px}.board{gap:6px}}
"""

JS = """
  var M=document.getElementById('modal');
  function openM(d){
    document.getElementById('m-title').textContent=d.dataset.title;
    document.getElementById('m-who').textContent=d.dataset.who;
    var acc=JSON.parse(d.dataset.acc||'[]'), ul=document.getElementById('m-acc'); ul.innerHTML='';
    acc.forEach(function(a){var li=document.createElement('li');li.className=a[0];li.textContent=a[1];if(a[2]){var ev=document.createElement('span');ev.className='ev';ev.textContent=a[2];li.appendChild(ev);}ul.appendChild(li);});
    document.getElementById('m-rv').textContent=d.dataset.review||'\\u2014';
    var pw=document.getElementById('m-pw');
    if(d.dataset.prompt){pw.innerHTML='<div class="sec">\\u5f00\\u5de5 prompt</div><div class="prompt" id="m-prompt"></div><button class="btn" onclick="cp()">\\u590d\\u5236 prompt</button>';document.getElementById('m-prompt').textContent=d.dataset.prompt;}
    else pw.innerHTML='';
    M.classList.add('on');
  }
  function closeM(){M.classList.remove('on');}
  function cp(){navigator.clipboard.writeText(document.getElementById('m-prompt').textContent);event.target.textContent='\\u5df2\\u590d\\u5236 \\u2713';}
  document.querySelectorAll('.card').forEach(function(c){c.onclick=function(){var d=c.querySelector('.detail');if(d)openM(d);};});
  M.onclick=function(ev){if(ev.target===M)closeM();};
  document.addEventListener('keydown',function(ev){if(ev.key==='Escape')closeM();});
"""

# ---- cross-day task files (docs/together/tasks/<task-id>.md) ----
# A card is a THIN projection of its task file: `task: <id>` references the
# flat, cross-day record. The task file's "## Handoff prompt" section feeds the
# card's 开工-prompt modal (so a done card's prompt stays viewable). Handoffs
# are written ONCE at task creation; boards never regenerate them.
BOARD_DIR = "."


def task_prompt(card):
    tid = card.get("task")
    if not tid:
        return ""
    path = os.path.join(BOARD_DIR, "..", "tasks", f"{tid}.md")
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8") as f:
        txt = f.read()
    m = re.search(r"##\s*Handoff prompt[^\n]*\n(.*?)(?=\n## |\Z)", txt, re.S)
    return (m.group(1) if m else txt).strip()


def check_board(b, src):
    """HARD GATE (2026-07-29, lead-mandated): rendering REFUSES unless
    (1) EVERY card — today's AND done_prev's — carries `task: <id>` whose flat
        task file exists with a non-empty `## Handoff prompt` section, and
    (2) every NOT-done card of the PREVIOUS board (latest dated dir with a
        board.yaml before this one) is accounted for today: carried (matched by
        a shared `#NNNN` PR token or normalized-title fragment) or explicitly
        listed under top-level `carryover_resolved:` with a reason.
    Sending a board.html therefore PROVES both checks ran (an unchecked board
    cannot render). Bypass only with --no-check + a reason in the commit."""
    errors = []
    all_cards = (b.get("cards") or []) + (b.get("done_prev") or [])
    for c in all_cards:
        tid, title = c.get("task"), c.get("title", "?")
        if not tid:
            errors.append(f"card '{title}' has no task: id")
            continue
        path = os.path.join(BOARD_DIR, "..", "tasks", f"{tid}.md")
        if not os.path.exists(path):
            errors.append(f"card '{title}': task file missing (tasks/{tid}.md)")
        elif not task_prompt(c):
            errors.append(f"card '{title}': tasks/{tid}.md has an empty '## Handoff prompt'")
    together, this_dir = os.path.dirname(BOARD_DIR), os.path.basename(BOARD_DIR)
    prevs = sorted(
        d for d in os.listdir(together)
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", d) and d < this_dir
        and os.path.exists(os.path.join(together, d, "board.yaml"))
    )
    if prevs:
        prev_dir = prevs[-1]
        with open(os.path.join(together, prev_dir, "board.yaml"), encoding="utf-8") as f:
            pb = yaml.safe_load(f)
        raw_res = b.get("carryover_resolved") or []
        resolved = set(raw_res.keys()) if isinstance(raw_res, dict) else set(raw_res)
        with open(src, encoding="utf-8") as f:
            today_text = f.read()
        today_squash = re.sub(r"[\s★#（）()·—-]+", "", today_text)
        for pc in (pb.get("cards") or []):
            if pc.get("status") == "done":
                continue
            ptitle = pc.get("title", "")
            prs = set(re.findall(r"#\d{3,5}", yaml.safe_dump(pc, allow_unicode=True)))
            title_key = re.sub(r"[\s★#（）()·—-]+", "", ptitle)[:12]
            if (ptitle in resolved
                    or (title_key and title_key in today_squash)
                    or any(p in today_text for p in prs)):
                continue
            errors.append(
                f"prev board({prev_dir}) not-done card unaccounted: '{ptitle}' — "
                "carry it, or list it under carryover_resolved: with a reason")
    if errors:
        sys.exit("board2html: BOARD CHECK FAILED —\n  " + "\n  ".join(errors))


def render_card(card, pcolor, pname, today=None):
    color = pcolor.get(card.get("owner"), "#2563eb")
    delayed, overdue = card_delay(card, today)
    owner_tag = (f'<div class="owner"><span class="odot" style="background:{color}"></span>'
                 f'{e(pname.get(card.get("owner"), card.get("owner","")))}</div>')
    acc = card.get("acceptance", []) or []
    done_n = sum(1 for a in acc if a.get("done"))
    total_n = len(acc)
    is_done = card.get("status") == "done"
    # acceptance summary line
    if total_n == 0:
        accm = ''
    elif is_done or done_n == total_n and total_n:
        accm = f'<div class="accm"><span class="d">☑</span> 已验收 · {done_n}/{total_n}</div>'
    else:
        mark = '<span class="d">☑</span>' if done_n else '<span class="o">☐</span>'
        accm = f'<div class="accm">{mark} {done_n}/{total_n} 验收</div>'
    # meta pills
    pills = []
    pr = card.get("pr")
    if pr:
        cls = PR_STATE_PILL.get(pr.get("state", "open"), "pr-open")
        label = f'#{pr["num"]} {pr.get("state","")}'.strip()
        pills.append(f'<span class="pill {cls}">{e(label)}</span>')
    if card.get("branch"):
        pills.append(f'<span class="pill pr-draft">{e(card["branch"])}</span>')
    for d in (card.get("deps") or []):
        pills.append(f'<span class="pill dep">{e(d)}</span>')
    if card.get("carryover"):
        pills.append('<span class="pill carry">结转昨日</span>')
    if card.get("status") == "blocked":
        pills.append('<span class="pill blocked">阻塞</span>')
    if card.get("task"):
        pills.append(f'<span class="pill dep">task:{e(card["task"])}</span>')
    pills.append('<span class="pill more">详情</span>')
    # detail data
    acc_json = json.dumps([[("done" if a.get("done") else "todo"), a.get("text",""), a.get("evidence","")] for a in acc], ensure_ascii=False)
    if is_done:
        rib = '<span class="done-rib">DONE</span>'
    elif delayed:
        rib = f'<span class="late-rib">延期 {overdue}d</span>'
    else:
        rib = ''
    goal = f'<div class="g">{e(card.get("goal"))}</div>' if card.get("goal") else ''
    extra_note = f' · <span style="color:var(--red)">{e(card["flag"])}</span>' if card.get("flag") else ''
    if extra_note and accm:
        accm = accm[:-6] + extra_note + '</div>'
    # schedule chip (started → est_done) + delay/decomposition surfacing.
    # Absent both fields → renders nothing (byte-identical to a pre-field board).
    started, est_done = card.get("started"), card.get("est_done")
    sched = ''
    if started or est_done:
        scls = "sched late" if delayed else "sched"
        sched = (f'<div class="{scls}"><span class="cal">🗓</span>'
                 f'{e(started) if started else "?"} → {e(est_done) if est_done else "?"}</div>')
    decomp = ('<div class="decomp">延期 → 建议按依赖拆成日粒度子模块 '
              '(B1/B2/B3…), 每块 started/est_done 顺延一天</div>') if delayed else ''
    cls = "card done" if is_done else ("card late" if delayed else "card")
    return (
        f'<div class="{cls}" style="--pc:{color}">{rib}{owner_tag}<div class="t">{e(card.get("title"))}</div>{goal}'
        f'{accm}{sched}{decomp}<div class="meta">{"".join(pills)}</div>'
        f'<div class="detail" data-title="{e(card.get("title"))}" data-who="{e(card.get("who",""))}" '
        f"data-acc='{html.escape(acc_json, quote=True)}' "
        f'data-review="{e(card.get("review_note",""))}" data-prompt="{e(card.get("prompt") or task_prompt(card))}"></div></div>'
    )

def main():
    if len(sys.argv) < 2:
        sys.exit("usage: board2html.py <board.yaml> [board.html]")
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else (src[:-5] + ".html" if src.endswith(".yaml") else src + ".html")
    # cross-day task files resolve relative to the board's dated dir (../tasks/)
    global BOARD_DIR
    BOARD_DIR = os.path.dirname(os.path.abspath(src))
    with open(src, encoding="utf-8") as f:
        b = yaml.safe_load(f)
    if "--no-check" not in sys.argv:
        check_board(b, src)

    today = board_today(b)  # deterministic 'today' for delay flags (as_of > date)
    people = b.get("people", []) or []
    cards = b.get("cards", []) or []
    pcolor = {p["id"]: p.get("color", "#2563eb") for p in people}
    pname = {p["id"]: p.get("name", p["id"]) for p in people}
    for c in cards:
        c.setdefault("who", f'{c.get("owner","")}')

    # hero
    prog_html = ""
    for i, pr in enumerate(b.get("progress", []) or []):
        val = pr.get("value", f'{pr.get("pct","")}%')
        bcls = "bar b" if i else "bar"
        prog_html += (f'<div class="lab"{" style=\"margin-top:6px\"" if i else ""}><span>{e(pr.get("label"))}</span><span>{e(val)}</span></div>'
                      f'<div class="{bcls}"><i style="width:{int(pr.get("pct",0))}%"></i></div>')
    eff_html = "".join(f'<div><b>{e(t.get("value"))}{eff_delta_chip(t.get("delta"))}</b><span>{e(t.get("label"))}</span></div>' for t in (b.get("efficiency", []) or []))
    deploy_html = "".join(f'<div><span class="s">{e(d.get("env"))}</span>{e(d.get("state"))}</div>' for d in (b.get("deploy", []) or []))
    risks_html = "<br>".join(e(r) for r in (b.get("risks", []) or []))
    closures_html = render_system_closures(b.get("system_closures"))

    # This is a DISPLAY page published each morning: 计划/进行中/待评审 = TODAY's plan;
    # 完成 = YESTERDAY's done cards (the same full cards); review = YESTERDAY's review.
    prev_date = b.get("prev_date", "")
    done_prev = b.get("done_prev", []) or []
    for c in done_prev:
        c["status"] = "done"
        c.setdefault("who", c.get("owner", ""))
    order = {p["id"]: i for i, p in enumerate(people)}
    cols = []
    for status, label, cls in COLUMNS:
        if status == "done":
            col_cards = list(done_prev)
            if prev_date:
                label = f'{label} · 昨日 {prev_date}'
        else:
            col_cards = [c for c in cards if c.get("status") == status
                         or (status == "wip" and c.get("status") == "blocked")]
        col_cards = sorted(col_cards, key=lambda c: order.get(c.get("owner"), 99))
        inner = "".join(render_card(c, pcolor, pname, today) for c in col_cards)
        cols.append(f'<div class="colwrap"><div class="colhead {cls}">{label} '
                    f'<span class="cnt">{len(col_cards)}</span></div><div class="cell">{inner}</div></div>')
    board_html = "\n    ".join(cols)
    legend = " ".join(f'<span class="lg"><span class="odot" style="background:{p.get("color","#2563eb")}">'
                      f'</span>{e(p.get("name"))}</span>' for p in people)

    # review / 复盘
    rv = b.get("review", {}) or {}
    md = "".join(render_method_delta(x) for x in (rv.get("method_deltas", []) or []))
    inc = "<br>".join("• " + e(x) for x in (rv.get("incidents", []) or []))
    rows = ""
    for d in (rv.get("delivery", []) or []):
        rows += (f'<tr><td>{e(d.get("owner"))}</td><td>{e(d.get("delivered"))}</td>'
                 f'<td>{e(d.get("acceptance_result"))}</td><td>{e(d.get("carryover"))}</td></tr>')
    nextday = "<br>".join("• " + e(x) for x in (rv.get("next_day", []) or []))
    review_html = ""
    if rv:
        rv_date = f'（{e(prev_date)}）' if prev_date else ''
        review_html = f"""
  <div class="review">
    <h2>昨日复盘{rv_date} · 卡片验收结果 + 方法/事故</h2>
    <div class="grid2">
      <div class="good"><b>方法沉淀</b><br>{md or '—'}</div>
      <div class="inc"><b>风险/事故</b><br>{inc or '—'}</div>
    </div>
    <table><tr><th>人</th><th>交付</th><th>验收结果</th><th>结转今日</th></tr>{rows}</table>
    <h3 style="font-size:14px;color:#374151;margin-top:14px">今日建议</h3>
    <div style="font-size:12.5px;color:#475569">{nextday or '—'}</div>
  </div>"""

    title = f'dev-together 看板 · {e(b.get("date",""))}'
    doc = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>{CSS}</style>
</head>
<body>
<div class="wrap">
  <div class="hero">
    <div class="row">
      <div style="flex:2;min-width:280px">
        <h1>dev-together · {e(b.get("date",""))}</h1>
        <div class="north"><b>北极星：</b>{e(b.get("north_star",""))}</div>
      </div>
      <div class="prog">{prog_html}</div>
    </div>
    <div class="row" style="margin-top:12px"><div class="eff">{eff_html}</div></div>
    <div class="src">总效能来源：{e(b.get("efficiency_source",""))}</div>
  </div>
  {closures_html}
  <div><div class="deploy">{deploy_html}</div></div>
  <div class="risk"><b>风险：</b>{risks_html or '—'}</div>
  <div class="legend">人：{legend}　·　卡片 = 一任务；☐/☑ = 验收（plan 写 · review 勾）；停在非「完成」列 = 明日结转</div>
  <div class="board">
    {board_html}
  </div>{review_html}
  <div class="foot">一块 <b>plan+review 合一</b> 的活看板：顶部全局大局（目标·进度·总效能）常驻；卡片可点开看完整验收/复盘/prompt；底部复盘汇总。<b>确定性渲染</b>：board.yaml → board2html.py，样式只住模板。</div>
</div>
<div class="modal" id="modal">
  <div class="sheet">
    <button class="x" onclick="closeM()">×</button>
    <h3 id="m-title"></h3><div class="who" id="m-who"></div>
    <div class="sec">验收标准 / 结果</div><ul class="acc" id="m-acc"></ul>
    <div class="sec">复盘 / 状态</div><div class="rv" id="m-rv"></div>
    <div id="m-pw"></div>
  </div>
</div>
<script>{JS}</script>
</body>
</html>
"""
    with open(out, "w", encoding="utf-8") as f:
        f.write(doc)
    print(f"board2html: wrote {out}")

if __name__ == "__main__":
    main()
