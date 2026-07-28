> **Task:** share-A4-1 — 删 Mount 的 reconcile 重发 trap(cap-as-truth 实证)
> **Branch:** `feat/socialware-share-a4-provision`
> **PR:** https://github.com/ezagent42/ezagent/pull/1611
> **Dev:** jjkysy (agent)
> **returned_at:** 2026-07-28 17:40 +0800
> **deadline:** 2026-07-28 (Group A 推进)
> **deadline_status:** on_time

## 做了什么
A4「Mount→Provision/Share 重构」的第一片:**删掉 `MountRow` 账本的"照表重发钥匙"trap**(reconcile),经实证 cap-as-truth 成立。纯 infra、独立(不依赖 A2-1/A2-2、可与四件并行合)、纯 domain_session。

- 删 `Ezagent.Socialware.Mount.reconcile_session_mounts/1` + `reconcile_person_mounts/1` + 私有 `remint_row/2` + `remint_person_row/2`。
- 删 `behavior/session.ex` 的 `activate/2` 里 `reconcile_session_mounts` hook 调用(保留 `reconcile_after_load` 成员那条)。
- 更新 mount.ex moduledoc:重启存活 = cap-as-truth(grantee 自己的 durable store 冷读回),不再照表重发;MountRow 保留为记账/反查用途(backfill/unmount 取 actions),不再是重发来源。
- 删 `mount_reconcile_test.exs`(测的是删掉的函数)。
- 新增 `mount_cap_survives_respawn_test.exs`:**实证** mount cap 冷 terminate grantee 后仍在。

## 关键决策(xy 实证 —— 推翻旧注释)
旧 reconcile 注释自陈"session 重启时 grantee 的 cap slice 重建、钥匙**不会自动重发**,故照 MountRow 重 mint"。**实证推翻**:post-#195 cap 是持久的(mint→absorb→persist 到 `users.caps_json`/agent snapshot),slice 冷重建**从 durable store 重新读回**这把钥匙。`mount_cap_survives_respawn_test` 证:mount 后 `Kind.terminate(grantee)`(真冷终止,不是"撤钥匙模拟"),`list_caps_for` 冷读仍返回该 cap → reconcile 的重发是**冗余的第二真理源扫描**,可删。旧 reconcile 测试用"撤钥匙模拟重启丢失"来验,那个前提本身(重启会丢 cap)在 post-#195 不成立。

## DoD reconciliation
| # | DoD line | status | proof |
|---|----------|--------|-------|
| 1 | 实证 mount cap 冷重启存活(reconcile 冗余) | met | `mount_cap_survives_respawn_test` 1/0(terminate 后 cap 仍在) |
| 2 | 删 reconcile 两函数 + hook + remint 辅助,无残留调用 | met | grep 全仓仅剩注释;编译 0 error/warning |
| 3 | mount/unmount/provision 回归不破 | met | `mount_test` 全过(19/0 合计) |
| 4 | member_backfill 回归不破(仍用 MountRow) | met | `member_backfill_test` 全过(19/0 合计) |
| 5 | arch 闸不破 | met | cross_file 1/0 · doc_coverage 17/0 · 2-seg-session-URI 14/0 · format clean |
| 6 | full suite CI 绿 + Loop C | pending | push 后 CI run |

**Method friction:** 环境极慢——domain_session 测试要 `ensure_all_started(:ezagent_plugin_py/cc)`,但这俩插件 app 不在默认编译图,得显式 `cd apps/ezagent_plugin_py && mix compile`(+cc)才有 `.app`,否则 test_helper:24 崩;fresh worktree deps 含 heroicons git dep,沙箱无网络 fetch 失败→从姊妹 worktree `cp -rn deps/` 绕过。教训记 memory 供后续 A4 复用。

## 关于 A4 剩余(本 PR 不做,附设计结论供后续)
本 PR 只删 reconcile(最干净、经实证、无依赖的一片)。A4 剩余 + **一个 XY 澄清**:
- **backfill 改派生**:现 backfill 读 `MountRow.list_for_session`(session→boards)。**XY 结论(与用户对齐)**:session→board **不是** cap 给不了的轴、**不需要**单独真理源——"这个 session 有哪些 board" ≡ "现有成员能操作哪些 board",从成员各自 cap 推(`session_member_uris/1` 列成员 + 每成员 `list_caps_for` 按 behavior/`:operate` 过滤取 `cap.instance`)。用 **caps_toward(A2-1 forward)**,不是 grantees_of(A2-2 reverse,那是 A4-2 给 :members 用)。故 backfill 重写依赖 **A2-1** 合并。
- **Mount→Provision/Share 改名 + 删 MountRow 表**:改名碰 kanban 消费者(board_provision / kanban_share_controller / board_*_test),归后续(或 Group B 一起),本 Group-A 片不碰 kanban 文件。
- **unmount 取 actions 脱 MountRow**:改从 grantee 现有 cap 派生。

## 分支 + gate 状态
- Branch off `origin/main` @ `495c18cdf`,独立(不 stack 在 A2)。
- 本地全绿(见 DoD)。CI:push 后 run URL。

## Merge request
Group A 独立件,可与 A1/A2-1/A2-2/A3 并行合。A4 剩余(backfill 派生等 A2-1、改名归后续)。
