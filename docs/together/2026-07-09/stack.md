# 2026-07-09 stack — 合并顺序对账

本日 4 份 return + 2 个直接 PR 合并的 merge-order 对账。

| # | return / 来源 | PR | 状态 | merge / 去向 |
|---|---|---|---|---|
| 1 | pr-1276-complete-return | #1276 | merged | `2df027f58`（lead 补 4 道行锚 gate 后合入）；world 模板 UX + cc dev-channel 探针 + PTY 会话面 |
| 2 | world-pty-conversation-surface | — | folded → #1276 | 随 #1276 合入；PTY 会话面（标 out_of_scope） |
| 3 | world-session-create-failfast | — | folded → #1276 | cc dev-channel fail-fast 折入 #1276 |
| 4 | seed-loader-dedup | #1295 | merged | ShippedManifest 共享 loader；duplicate-fn cap 46→42 |
| 5 | （直接 PR，非 returns/） | #1277 | merged | zhaomato — hello v2 seed page + rebuild guide + domain fixes |
| 6 | （直接 PR，非 returns/） | #1204 | merged | ruihua — 官网飞轮 handoff + scenarios |
| — | Track C（create_session 根因） | #1294 | **in-flight → carry 07-10** | gaga 已产出，评审中 + 未 canary 实测 |

## 注记

- **合并入 main 的 GMT+9 07-09 PR**：#1266（skill P1-P3，前置合入）· #1295 · #1276 · #1277 · #1204（+ #1263 07-08 深夜 main-green 收尾，跨日归本工作日）。
- **#1277 / #1204 不在 `returns/` 台账**：走直接 PR review→merge，只扫 `returns/` 会漏记——已据 GitHub 合并列表并核更正（见 review §4）。
- **未落 main 的 stopgap**：world-session-create-failfast return 里的 `deadline_ms: 60000` 加长 stopgap **未进 main**。已核实：`workspace.ex` 仅有一个通用 pass-through helper，无 60000 硬值——正确地让位给 #1294 的结构性根因修复，不用加长 deadline 盖症状。
