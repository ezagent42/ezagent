#!/usr/bin/env python3
"""PR session-hours estimator — dev-together 的自动工时下界度量。

为什么存在:人类+agent 混合开发下,没有人能(也没有人会)人工估计每个修复
的复杂度或投入;PR lead-time 又混入 review 等待/并发空转,不能当工时。
本脚本用唯一不需要任何人配合的信号——commit 作者时间戳——给出
"活跃工程时长"的**下界**估计(git-hours 惯例)。

原理:squash-merge 会抹掉 main 上的分支历史,但 GitHub API
`pulls/{n}/commits` 保留原始 commit 的 author date。按作者聚类:
相邻间隔 ≤ SESSION_GAP_MIN 串成一个 session,session 时长 = 组内间隔和
+ 每 session 补 BOOTSTRAP_MIN(近似首 commit 前的未记录工作)。

用法(需 gh 已登录):
  uv run python pr_session_hours.py <owner/repo> "<窗口1>[,<窗口2>…]" [raw.jsonl]
  # 窗口是 GitHub search 的 merged: 限定式;>1000 个 PR 时自行拆窗
  # 每日 review:  uv run python pr_session_hours.py ezagent42/ezagent "2026-07-15"
  # 周度:         uv run python pr_session_hours.py ezagent42/ezagent ">=2026-07-08"
  # 效率审计 8 周: uv run python pr_session_hours.py ezagent42/ezagent \
  #                  "2026-05-20..2026-06-15,>2026-06-15" raw.jsonl

输出:JSON(stdout)——总活跃小时、按 160h 折算工程人月、per-author 明细。
raw.jsonl(可选第 3 参)落盘每条 (sha, author, date, pr) 供复查。

解读纪律(写进 review/efficiency-audit 时必须带上):
  - 这是**下界**:无 commit 的思考/review/调试时间不可见;
  - agent 密集 commit 段度量的是 agent 墙钟,不是人力;人/agent 按
    author 身份天然分列,汇报时分开呈现;
  - rebase 改写 author date 会合并/压缩 session;
  - 绝不把本数字当"真实工时"或用于个人绩效——它只用于聚合层面的
    效率与产能口径校准。
"""

import json
import subprocess
import sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime

SESSION_GAP_MIN = 120
BOOTSTRAP_MIN = 30


def gh(args):
    r = subprocess.run(["gh"] + args, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:3])}…: {r.stderr[:200]}")
    return r.stdout


def list_prs(repo, windows):
    prs, seen = [], set()
    for w in windows:
        out = gh([
            "pr", "list", "-R", repo, "--state", "merged",
            "--search", f"merged:{w}", "--limit", "1000",
            "--json", "number,mergedAt,author,title",
        ])
        batch = json.loads(out)
        if len(batch) == 1000:
            print(f"WARN: window '{w}' hit the 1000-PR cap — split it, results are truncated",
                  file=sys.stderr)
        for p in batch:
            if p["number"] not in seen:
                seen.add(p["number"])
                prs.append(p)
    return prs


def fetch_commits(repo, pr):
    out = gh([
        "api", f"repos/{repo}/pulls/{pr['number']}/commits", "--paginate",
        "--jq", "[.[] | {sha: .sha, name: .commit.author.name, "
                "email: .commit.author.email, date: .commit.author.date}]",
    ])
    rows = []
    for chunk in out.strip().splitlines():
        if chunk:
            rows.extend(json.loads(chunk))
    for r in rows:
        r["pr"] = pr["number"]
    return rows


def cluster(stamps):
    stamps.sort()
    sessions, hours, prev = 0, 0.0, None
    for ts in stamps:
        if prev is None or (ts - prev).total_seconds() / 60 > SESSION_GAP_MIN:
            sessions += 1
            hours += BOOTSTRAP_MIN / 60
        else:
            hours += (ts - prev).total_seconds() / 3600
        prev = ts
    return sessions, hours


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    repo, windows = sys.argv[1], sys.argv[2].split(",")
    raw_out = sys.argv[3] if len(sys.argv) > 3 else None

    prs = list_prs(repo, windows)
    print(f"PRs to scan: {len(prs)}", file=sys.stderr)

    all_rows, failed = [], []
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(fetch_commits, repo, p): p for p in prs}
        for i, fut in enumerate(as_completed(futs), 1):
            try:
                all_rows.extend(fut.result())
            except Exception as e:
                failed.append((futs[fut]["number"], str(e)[:80]))
            if i % 100 == 0:
                print(f"  fetched {i}/{len(prs)}", file=sys.stderr)

    if raw_out:
        with open(raw_out, "w") as f:
            for r in all_rows:
                f.write(json.dumps(r) + "\n")

    by_sha = {}
    for r in all_rows:
        by_sha.setdefault(r["sha"], r)

    per_author = defaultdict(list)
    for r in by_sha.values():
        ts = datetime.fromisoformat(r["date"].replace("Z", "+00:00"))
        per_author[(r["name"], r["email"])].append(ts)

    report, total_h = [], 0.0
    for (name, email), stamps in per_author.items():
        sessions, hours = cluster(stamps)
        total_h += hours
        report.append({
            "author": name, "email": email, "commits": len(stamps),
            "sessions": sessions, "active_hours": round(hours, 1),
        })
    report.sort(key=lambda r: -r["active_hours"])

    print(json.dumps({
        "repo": repo,
        "windows": windows,
        "prs_scanned": len(prs),
        "prs_failed": failed,
        "unique_commits": len(by_sha),
        "session_gap_min": SESSION_GAP_MIN,
        "bootstrap_min_per_session": BOOTSTRAP_MIN,
        "total_active_hours": round(total_h, 1),
        "engineer_months_at_160h": round(total_h / 160, 2),
        "per_author": report,
        "reading_discipline": "lower bound; agent rows = agent wall-time, not human labor; never use for individual performance",
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
