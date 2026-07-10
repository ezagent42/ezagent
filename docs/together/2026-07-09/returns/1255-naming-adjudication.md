# Return — #1255 三命名裁定（sanctioned-pending-review → 转正）

> **Task:** 0709 plan §3 jjkysy ③ — 裁定 #1255 survey 留下的三个 "sanctioned-pending-review" 拼接命名
> **Branch:** `chore/1255-naming-adjudication`（org）· **Dev:** agent（jjkysy 席位）
> **returned_at:** 2026-07-09 · **deadline_status:** on_time

## 裁定结论（jjkysy 拍板：三个都维持拼接，sanction 转正，零改名）

| 模块 | 裁定 | 理由 |
|---|---|---|
| `Ezagent.AgentPassiveAttributes` | 维持拼接 | AgentFlavor* 已 sanction 胶合 cluster 的刻意镜像（moduledoc 明言 "exactly parallel"）；单改破坏 flavor/passive 对称，双改推翻已 sanction 决定 |
| `Ezagent.RuntimeIdentity` | 维持拼接 | `Ezagent.Runtime.*` 兄弟是 OS 子进程管线（line_buffer/os_process/orphan_reaper/pid_file），语义无关；`Runtime.Identity` 反而误导归属 |
| `Ezagent.EntityPresenter` | 维持拼接 | X-of-Y 角色后缀惯例（同 KindRegistry/MessageStore 家族）、渲染层引用面广、三者中改名收益最低；留注记：若未来出现 `Entity.Presenter.*` 子 cluster 再议 |

## DoD reconciliation
| # | DoD | status | proof |
|---|---|---|---|
| 1 | 三处 allowlist 注释落裁定结论（去 pending-review 字样，含日期+裁定人+一句理由） | met | `arch.scan.ex` @concatenated_namespace_allowlist 三处 Edit |
| 2 | 零代码/零改名（gate 语义不变） | met | diff 仅注释行 |
| 3 | gate 仍绿 | met | `concatenated_namespace_test` 7/0 |
| 4 | #1255 留裁定评论 | met | PR comment（见 merge request） |
| 5 | 机器返还闸：CI 绿 + rebased on main | pending CI | 基于 main 63877f425；PR full-suite 跑中 |

**Method friction:** 无。survey 注释本身写得足够裁定，未动代码。

## Merge request
独立小 PR，纯注释，与在飞 PR 零冲突面。
