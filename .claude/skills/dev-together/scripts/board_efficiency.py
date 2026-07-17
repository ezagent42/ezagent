#!/usr/bin/env python3
"""dev-together: auto git-hours efficiency + up/down delta for the daily board.

Runs the session-hours lower-bound (see pr_session_hours.py) for a day AND for
the day before, then prints a ready-to-splice `efficiency:` / `efficiency_source:`
YAML fragment where each stat carries a `delta` chip (↓red / ↑green) vs the
previous day. `plan` runs this each morning for the board's *yesterday* (the day
whose output just landed) and pastes the fragment into that day's board.yaml
before rendering — so the board always shows yesterday's efficiency with an
up/down indicator sitting next to each number, computed vs the day before.

Usage (needs `gh` logged in; run via `uv run python` — repo hook blocks bare python):
  uv run python scripts/board_efficiency.py <owner/repo> <YYYY-MM-DD>
  # <YYYY-MM-DD> = the board's yesterday (the measured day). Example:
  uv run python scripts/board_efficiency.py ezagent42/ezagent 2026-07-16

Output (stdout): a YAML fragment; all progress/logging goes to stderr so stdout
stays clean and pasteable. Takes ~1min (two single-day git-hours scans).

It reuses pr_session_hours.py's list_prs/fetch_commits/cluster when importable
(same scripts/ dir), else falls back to calling pr_session_hours.py as a
subprocess and parsing its JSON stdout. `datetime`/`timedelta` are fine here —
this is a plain CLI, not a workflow script.
"""

import json
import os
import subprocess
import sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

try:
    from pr_session_hours import list_prs, fetch_commits, cluster
    _HAVE_IMPORT = True
except Exception as _imp_err:  # pragma: no cover - fallback path
    print(f"board_efficiency: import of pr_session_hours failed ({_imp_err}); "
          f"using subprocess fallback", file=sys.stderr)
    _HAVE_IMPORT = False


def _compute_via_import(repo, day):
    """day = 'YYYY-MM-DD'; returns {prs, hours, eng_months} for merged:<day>."""
    prs = list_prs(repo, [day])
    all_rows = []
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(fetch_commits, repo, p): p for p in prs}
        for fut in as_completed(futs):
            try:
                all_rows.extend(fut.result())
            except Exception as err:
                print(f"  warn: commit fetch failed for a PR: {str(err)[:80]}",
                      file=sys.stderr)
    by_sha = {}
    for r in all_rows:
        by_sha.setdefault(r["sha"], r)
    per_author = defaultdict(list)
    for r in by_sha.values():
        ts = datetime.fromisoformat(r["date"].replace("Z", "+00:00"))
        per_author[(r["name"], r["email"])].append(ts)
    total_h = 0.0
    for stamps in per_author.values():
        _sessions, hours = cluster(stamps)
        total_h += hours
    return {"prs": len(prs), "hours": round(total_h, 1),
            "eng_months": round(total_h / 160, 2)}


def _compute_via_subprocess(repo, day):
    r = subprocess.run(
        ["uv", "run", "python", os.path.join(_HERE, "pr_session_hours.py"), repo, day],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise RuntimeError(f"pr_session_hours.py failed: {r.stderr[:300]}")
    data = json.loads(r.stdout)
    h = float(data["total_active_hours"])
    return {"prs": int(data["prs_scanned"]), "hours": round(h, 1),
            "eng_months": round(h / 160, 2)}


def compute(repo, day):
    print(f"board_efficiency: scanning merged:{day} …", file=sys.stderr)
    return _compute_via_import(repo, day) if _HAVE_IMPORT else _compute_via_subprocess(repo, day)


def _num(x):
    """Trim trailing zeros: 20.6 -> '20.6', 983.0 -> '983'."""
    return f"{x:g}"


def _delta(cur, prev, integer):
    """↓red-string / ↑green-string / ±0. Magnitude rounded (int for hours/PR,
    2dp for eng-months). The glyph carries the color; board2html reads it."""
    d = cur - prev
    if integer:
        mag = f"{round(abs(d)):g}"
    else:
        mag = f"{round(abs(d), 2):g}"
    if d < 0:
        return f"↓{mag}"
    if d > 0:
        return f"↑{mag}"
    return "±0"


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: board_efficiency.py <owner/repo> <YYYY-MM-DD>  "
                 "(date = the board's yesterday, the measured day)")
    repo, day = sys.argv[1], sys.argv[2]
    try:
        dt = datetime.strptime(day, "%Y-%m-%d")
    except ValueError:
        sys.exit(f"board_efficiency: bad date '{day}', expected YYYY-MM-DD")
    prev = (dt - timedelta(days=1)).strftime("%Y-%m-%d")
    mmdd = dt.strftime("%m-%d")

    cur = compute(repo, day)
    prv = compute(repo, prev)

    d_hours = _delta(cur["hours"], prv["hours"], integer=True)
    d_prs = _delta(cur["prs"], prv["prs"], integer=True)
    d_eng = _delta(cur["eng_months"], prv["eng_months"], integer=False)

    cur_hours = _num(cur["hours"])
    prv_hours = _num(prv["hours"])
    cur_eng = f"{cur['eng_months']:.2f}"
    prv_eng = f"{prv['eng_months']:.2f}"

    print(f"board_efficiency: {day} = {cur_hours}h / {cur['prs']} PR / {cur_eng} · "
          f"{prev} = {prv_hours}h / {prv['prs']} PR / {prv_eng}", file=sys.stderr)

    frag = (
        "efficiency:\n"
        f'  - {{value: "{cur_hours}h", delta: "{d_hours}", '
        f'label: "{mmdd} 活跃工时(git下界) · 昨 {prv_hours}h"}}\n'
        f'  - {{value: "{cur["prs"]}", delta: "{d_prs}", '
        f'label: "{mmdd} merged PR · 昨 {prv["prs"]}"}}\n'
        f'  - {{value: "{cur_eng}", delta: "{d_eng}", '
        f'label: "{mmdd} 折算人月(160h) · 昨 {prv_eng}"}}\n'
        f'efficiency_source: "{mmdd} 实测 pr_session_hours.py（git-hours 下界 · '
        "~1min 可复算）；'Allen Woods'作者=协调 agent 墙钟非人力；"
        '当日产出或次日才合入、此法略低估。"\n'
    )
    sys.stdout.write(frag)


if __name__ == "__main__":
    main()
