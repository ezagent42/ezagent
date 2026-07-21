# Return: D3 kanban tab 恒显(applies_to? 翻转)

- **returned_at**: 2026-07-19 22:10 (+08)

## DoD 对账

| 条目 | 状态 |
|---|---|
| `board_view.ex` `applies_to?` 翻转恒 true(任何 session;junk fail-safe false) | ✔(单测改写 + erpc 运行节点实测) |
| 空态引导文案 | ✔(BoardView LiveView 空态 + world React 空 tab 两处,含「点分享链接领板」指引;s02 截图) |
| T2-2b `authorize_view` 契约不动(Allen 红线) | ✔(erpc-proof:cap 门仍如实判) |
| 回归:装了 kanban 的会话 tab 照旧 | ✔(s01) |

## e2e 证据

`docs/e2e/2026-07-19/d3-tab-always/`(erpc-proof.txt + s01/s02 + README)。

## 遗留

D3 option a 的**供给半件**(全体登录成员按 plugin 基线发 `kanban_render` cap)未落——现供给(`declared_view_actions`)只覆盖 installed views,未装 kanban 的会话成员仍被 cap 门挡。落点在 domain membership/installation(本 PR 纪律面外),待单独 handoff/Allen。
