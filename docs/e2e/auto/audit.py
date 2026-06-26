#!/usr/bin/env python3
"""docs/e2e/auto/audit.py — scenario-12 dispatch 审计(CLI,非 agent-browser)

直查 PG 的 invocations/dlq 表,核对前面 UI 往返在 dispatch 层真发生了(granted 可追溯),
并报告 P22 DLQ-on-zero-match 现状。

  pip install pg8000 --break-system-packages   # 一次性
  POSTGRES_* 环境变量需设置(从运行中 server 的 env 取)
  python3.12 docs/e2e/auto/audit.py [window_minutes]

退出码 0=PASS / 1=FAIL / 2=环境未就绪(无 pg8000 / 连不上,runner 会 SKIP)。
"""
import os, sys

try:
    import pg8000.native as pg
except Exception:
    print("  ⏭️  SKIP 12 审计:无 pg8000(pip install pg8000 --break-system-packages)")
    sys.exit(2)

win_min = int(sys.argv[1]) if len(sys.argv) > 1 else 60

def env(k, d=None):
    v = os.environ.get(k, d)
    if v is None:
        print(f"  ⏭️  SKIP 12 审计:缺环境变量 {k}")
        sys.exit(2)
    return v

try:
    c = pg.Connection(
        user=env("POSTGRES_USER"), password=env("POSTGRES_PASSWORD"),
        host=env("POSTGRES_HOST", "127.0.0.1"), port=int(env("POSTGRES_PORT", "5432")),
        database=env("POSTGRES_DB"),
    )
except Exception as e:
    print(f"  ⏭️  SKIP 12 审计:连不上 PG ({e})")
    sys.exit(2)

# inserted_at 存 UTC(naive),now() 带本地 tz → 用 now() at time zone 'UTC' 比较,避免 TZ 错位
w = f"inserted_at > (now() at time zone 'UTC') - interval '{win_min} minutes'"
# 注:action 列是裸动词('receive'/'send'),完整动作在 target 的 query string
# (如 entity://system/agent/py_default?action=agent.receive)
total = c.run(f"select count(*) from invocations where {w}")[0][0]
recv = c.run(f"select count(*) from invocations where {w} and target like '%action=agent.receive%'")[0][0]
send = c.run(f"select count(*) from invocations where {w} and action='send'")[0][0]
ungranted = c.run(f"select count(*) from invocations where {w} and target like '%action=agent.receive%' and authz is distinct from 'granted'")[0][0]
py_recv = c.run(f"select count(*) from invocations where {w} and target like '%py_default%action=agent.receive%'")[0][0]
dlq = c.run("select count(*) from dlq")[0][0]

print(f"\n▶ 12 dispatch 审计 (CLI/PG, 近 {win_min}min)")
print(f"   invocations={total}  send={send}  receive={recv}  ungranted-receive={ungranted}  dlq表={dlq}")

fails = []
if total > 0:
    print(f"  ✅ PASS: dispatch 在 invocations 留痕({total} 行,近 {win_min}min)")
else:
    fails.append(f"近 {win_min}min 无 invocations(server 没记 audit?)")

if py_recv > 0:
    print(f"  ✅ PASS: py_default 有 agent.receive({py_recv})— UI 往返在 dispatch 层坐实")
else:
    fails.append("py_default 无 agent.receive(往返未在 dispatch 层留痕,或窗口太短)")

if ungranted == 0:
    print(f"  ✅ PASS: 所有 agent.receive 均 granted(无越权投递)")
else:
    fails.append(f"{ungranted} 条 agent.receive 非 granted")

note = "零匹配消息无 DLQ 兜底(GLOSSARY 待裁决:P22 设计 no-op 还是缺口)" if dlq == 0 else f"有 {dlq} 行 DLQ 记录"
print(f"  ℹ️  P22 DLQ-on-zero-match:dlq 表 {dlq} 行 — {note}")

if fails:
    print("\n══ audit 结果 ══ FAIL")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("\n══ audit 结果 ══ PASS")
sys.exit(0)
